# 实现合同：关键不变量与接口

条款 ID 是 STAGE 和测试的索引。接口片段表达必须满足的语义，非可直接粘贴编译的实现；前置阶段验收时记录最终签名。受控外部依赖允许协议/闭包，禁止另建通用任务平台。

## C01：本地展示与准备状态

准备状态至少分开表达：`localReadReady`（数据库/schema 可读取）、`syncRecoveryReady`（旧任务恢复完成）、`authorizationRequestSettled`（本次授权状态检查已返回）、`protectedDataHint`（系统提示，实际结果以 HKQuery 为准）。不使用一个 `isReady` 覆盖全部。

- 只有 `syncRecoveryReady` 后允许 HK 读取、导入、回补、饮食写回和投影工作；现有 BG 注册失败/恢复失败的 fail-closed 行为保持。
- 展示既有数据不需要等待 HKQuery。曾完成过授权请求的安装可在 `.unknown` 检查期间进入本地页面；不能把 hasRequested 当作读授权已获准。
- rawSampleCount/lastIngest 从首屏模型移除，不提供伪造 0/nil 的占位业务事实；质量详情保持自己的读取。
- 刷新失败保留上次成功快照；快照更新时间、样本日期和同步检查时间各自独立。
- `snapshotAvailable` 是主线程已接收展示数据；`firstContentVisible` 是实际 UI 首批有效卡片可见。两者分别验收，不能只测 Task 返回就宣称首屏达标。

## C02：请求、代次与合并

建议值类型位于 `Core/Sync/SyncDemand.swift`：

```swift
struct SyncDemand: Sendable, Equatable {
    let types: Set<String>       // 调用端从 Catalog 解析，不能空集合表示 all
    let reason: SyncReason
    let intentID: UUID           // 一次前台/手动等逻辑意图的去重 ID
}
struct SyncClaim: Sendable, Equatable {
    let token: UUID
    let capturedGeneration: [String: Int64]
}
```

`requested_generation` 单调递增；`completed_generation <= requested_generation`。同一 lifecycle intentID 的重复请求幂等，不自增；每个真实 observer delivery 是新事件。静态计数不可跨线程非原子修改，Int64 溢出显式失败，不用环绕运算。

请求入库发生在任何“已接收/可恢复交接”结果之前。第 g 代查询中收到 g+1：只能完成 g，g+1 必须留待后续。对本轮尚未开始查询的类型，claim 时可以合并到最新代次。使用清楚的 claim 边界，不能在 drain 后把全部 requested_generation 无条件设为 completed。

**受控例子：**runner 已开始 A，依次收到 A/B/A/A；之后最多一个待处理类型集合 `{A,B}`（不是四个 full pass）；A 的 claimed generation 之后有更新，必须再 drain A。事件数量没有要求等于执行轮次数。

## C03：唯一执行通道与有界 drain

`SyncSchedulingState` 是纯值 reducer；实际 `SyncRunner` 用一个 actor 拥有唯一 active token 和一个 worker handle。只有 worker 创建点设置 running，finally 通过 token 匹配释放。所有旧入口必须转发/获取同一通道，尤其 backfill/manual，不保留第二套 isBusy 通道。

伪流程：

```text
submit(request):
  持久合并 demand；注册此调用的 waiter
  若 ready 且无 worker，启动唯一 worker
worker:
  while 预算允许:
    选取 ready 且到 retryAt 的 pending 类型，按公平轮转 claim
    执行一页/一个有限 slice；原子提交成功页
    类型确认 drain 后只完成其 capturedGeneration
    对成功页的 dirty 日期执行有界投影
    yield 到下一个类型；繁忙类型不能无限霸占
  token 匹配释放 worker
  若仍有 ready pending：前台 yield 后续跑；后台持久保留待下次许可触发
  若 deferred：等待解锁/授权/退避时间，不能无休止立即重启
```

“等待外部 App 的 manual session”不是 worker owner，不占 busy。前台、BG、observer 是执行机会的来源，不是独立 writer。BG expiration 只能终止其拥有的 slice/budget lease；不能错误取消后来由前台接管的 worker。共享请求取消只取消该 waiter，不能丢弃 durable demand。

初始常量：pageSize=1000、queryTimeout=8s、foregroundSlice=8s/8页、backgroundSlice=5s/4页、query并发=1。单次query的实际deadline取queryTimeout与当前slice剩余预算的较小值；没有足够预算时先yield，不让8秒query穿过5秒后台slice。系统提前 expiration 优先于所有自设预算；参数只是初始试验值，改值不绕过正确性测试。

## C04：追加 schema 与恢复

候选新迁移为 `v14_sync_work_queue`；落地时重新核对现有最大版本，若已被别的任务使用，由 Planner 重新编号。所有旧迁移正文不改。建议表：

```sql
CREATE TABLE sync_type_work (
  hk_type TEXT PRIMARY KEY,
  requested_generation INTEGER NOT NULL DEFAULT 0,
  completed_generation INTEGER NOT NULL DEFAULT 0,
  reason_mask INTEGER NOT NULL DEFAULT 0,
  deferred_reason TEXT,
  retry_at REAL,
  last_checked_at REAL,
  last_error_code TEXT,
  CHECK (requested_generation >= 0),
  CHECK (completed_generation >= 0 AND completed_generation <= requested_generation)
);
CREATE TABLE sync_projection_work (
  local_date TEXT NOT NULL,
  time_zone TEXT NOT NULL,
  projection_version INTEGER NOT NULL,
  generation INTEGER NOT NULL,
  PRIMARY KEY(local_date, time_zone, projection_version)
);
```

intentID 去重在一个前台 session 内由生命周期服务持有；无需把无限 intent 历史入库。跨进程重新前台允许再次全类型检查，代次自然合并。持久表不存 callback、Swift Task 或 HK 对象。

重启：旧 sync_jobs 仍由既有 SyncJobRecovery 关闭；type pending 和 dirty dates 保留，内存 running token 不恢复。只在恢复成功后开放 worker。没有新 HK 样本但有 dirty 日期时，也要恢复投影。只有所有对应工作完成才清除 pending。

新迁移可以在版本化配置中记录最后投影时区/算法版本；不能用 UserDefaults 已更新来冒充 DB 投影成功。时区/算法变化时按原始样本已覆盖日期有界重新排队；完成后推进版本标记，失败保留待办。不能只刷新最近 7 天或无界一次重算十年。

## C05：HealthKit 页提交、删除与 anchor

`HealthKitQueryExecutor` 返回 added/deleted/newAnchor。`SyncWorkStore.commit(page:claim:...)` 在**一个 GRDB write 事务**完成：

1. 校验 sampleType 与映射结果；收集 added 影响区间；取待删除 UUID 的现有行日期/类型/区间。
2. 按既有 UUID/有效读数去重规则插入，保留来源；使用真实 `db.changesCount` 得到实际新插入数，不用输入数组 count。
3. 对已存在且未删除行标记删除；未知 tombstone 计入诊断但不能杜撰日期。
4. 按 C06 加入 dirty 日期并推进对应 generation；同一页只有真实变更才标脏。
5. 安全归档并保存返回 anchor（与原类型/predicate合同一致）。
6. commit 成功后才返回页已持久结果。

任一步抛错整页 rollback；旧 anchor 保留，重试页幂等。failure injection 至少覆盖 after insert / after delete / before anchor / after anchor before commit。`INSERT OR IGNORE` 不能掩盖 mapper 对 catalog 类型的结构错误；映射失败时保留 anchor 并报具体阶段。

分页始终保持原 sample type/predicate 语义。连续有 added/deleted 就继续；只有 added/deleted 同时为空才确认本次 drain。不要只看 added 数量；不要拿 anchor 当整数、时间戳或比较大小。重复非进展页需诊断并有预算上限，不能忙循环。

nil anchor 的合法首次初始化按页处理全部匹配历史，不在隐式情况下缩为 30 天。解码损坏/系统明确 invalid anchor → `repairRequired`，保留原始数据/anchor 证据，停止该类型自动无限重置；修复策略由 Planner 单独审查，不能直接 DELETE anchor + 无界全量重拉。其他健康类型仍可继续。

删除发生在过去 7 天之外必须排队对应历史日。未知删除在 anchor 已有充分历史覆盖时可视为无本地对应行；没有完整覆盖的类型不能宣称已完成历史全量删除对账。

## C06：日期依赖、投影与内容发布

新增日期依赖 helper 优先放在该阶段已获准的 ProjectionWorker.swift 内部；如确需共享文件，先重新绑定白名单。helper 接受确定的 Calendar/timezone，测试注入 `Asia/Shanghai` 和 `America/Los_Angeles`；日区间使用 Calendar next start，不用固定86400秒，不把查询范围随意改为 UTC。

保持当前已发布聚合口径：

| 变化 | 必需重算集合 | 口径约束 |
|---|---|---|
| 体重/体脂/心率等瞬时值 | 样本 startAt 所属日，删除取旧行 | 来源与平均/最新取值规则保持 |
| 步数/基础能量/距离等累计值 | 当前算法归属的 start-day；可保守扩到跨日覆盖日 | 不改变来源优先级；相应系统统计按受影响日查 |
| sleepAnalysis | 旧/新 start-day，跨午夜可保守扩到覆盖日 | 继续现有 start-day 桶；不改为 wake-day、不引入效率推断 |
| workout | workout start-day及保守覆盖日 | 继续既有补充运动能量算法 |
| activeEnergy 样本 | 自身归属日 + 与变更区间重叠的已有 workout start-day | 包含原算法查询的端点重叠，避免跨日 workout 漏刷新 |
| 营养 HK 样本 | 自身历史归属日的后续同步/证据刷新 | 餐食主体和摄入完整性仍由 MealNutritionEvidenceQuery 决定，不把HK摄入直接叠加本地餐食 |
| 软删除 | 同样规则，以删除前本地行确定 | 删除后再查询旧日期会丢信息，因此先读旧行 |

`DailyAggregator.rebuild(dates:calendar:)` 新接口只改变调度范围，`rebuild(daysBack:)` 可作为兼容 wrapper。不得为性能重写累计来源、活动能量或营养证据算法。

投影读取对应 generation 的快照；计算后仅当 dirty generation/时区/版本仍相符才提交行并清理那一代待办。若出现新变更，保留/重新读取，不用旧结果清掉新 dirty。不能拿住 writer 事务等待 HKQuery。

系统步数/基础能量统计错误显式返回。允许已有 raw 日汇总作为当前既有 fallback，但必须保留其来源/状态，不能称为系统统计已成功。空统计或读权限不透明时不推断0、不覆盖成“已确认零”。`try?` 不得吞掉必需投影失败。

无 raw 变化且无 dirty 工作：不调用日聚合，不写投影表，不增加 aggregationTick。真实投影内容变化后 bump 一次；只是 computedAt 变化不要产生对下游的无意义数据变更。输出字段等价比较可在事务中完成，不用字符串 JSON 全表比较。

## C07：系统回调、取消和错误

### HealthKit Query 生命周期

每个 query 有独立 token、deadline 和一次性 continuation 状态。callback、timeout、Task cancellation 通过同一同步保护完成状态，只有一个胜出。非成功路径调用 store.stop(query)，取消 deadline，resume throwing；late callback 无效。取消先于 query 注册时，之后也不得再 execute。取消与 execute 之间必须有已定义的互斥/串行执行顺序，不能靠一个未同步 Bool。

错误分类依据 HealthKit error domain/code，递归解包装错误；使用 SDK 的 `HKError.Code` 枚举核对，不硬编码猜测 code。`errorDatabaseInaccessible`/受保护数据等候选具体枚举由 S04 核对本机 SDK 后冻结，不匹配就保留 unknown，不按英文错误消息 contains 判断。

- protected-data unavailable：持久 deferred，等待 unlock/foreground；不每类型三次短重试。
- authorization-related：记录受影响类型，等待用户权限请求/设置返回等后续检查；不把空结果归此类。
- cancellation/expiration：保留 demand，不算同步成功，无立即循环重试。
- transient：有限退避，保留 nextRetry；一次失败不拖住全部其他类型。
- malformed mapping / invalid anchor / persistence：明确阶段和 repair/failure，不推进相应 anchor。

### Observer 与 BGTask

Observer 的 completion closure 留在当前进程的 delivery owner，不存 DB。成功处理或将未完成工作可靠交接到 durable pending 后，结束该 delivery 一次；UI 结果在后者必须是 deferred，不能标记“数据已同步”。这是一种 App 恢复设计，不是声称 Apple 的 completion 证明数据已导入。

若 pending 持久化本身失败，不能无条件 finally 确认成功处理；保留失败/利用系统重交付，并在下一次前台全量检查兜底。Apple 对未响应存在退避上限，因此这条路径应出现可见诊断，不能无限依赖系统重试。任一 delivery 禁止重复 completion，也禁止弱引用丢失后悄悄视为同步成功。

BGTask completion 使用其请求 outcome：applied/noChanges 且必需工作完成→true；deferred/failed/cancelled 或未完成→false。expiration 与正常完成用一次性 gate 竞争，最多调用一次 setTaskCompleted。系统 deadline 先到时不等待 query 自然返回。

## C08：结果、Job 和显示语义

建议返回值 `SyncRunOutcome` 至少包含：runID/jobID、requested/completed/deferred/failedTypes、actualInserted/actualDeleted/ignored、changedDates、queryFinishedAt、projectionFinishedAt、errorStage、hasPendingWork。缺少阶段时间用 nil，不用当前时间伪造。

外观状态：idle、preparing、reading、projecting、waitingForUnlock、waitingForAuthorizationCheck、partial、completed、failed；可以保留现有 Phase 作为兼容映射，但 completed 只能在该次请求所有必需工作完成之后。

sync_jobs 继续使用原已有 state 字符串；不要把新 UI state 随意写进旧 Codable enum。一次 deferred 有界尝试可记录 failed + 明确 error_code，但保留持久待办；UI 显示等待解锁而非权限全被拒绝。独立维护任务状态不混入数据可见同步总耗时。

Manual pass2 类型成功（零新增也算）覆盖 pass1 同类型错误，最终是否成功由最终类型结果计算。不要继续使用 `pass1.firstError ?? pass2.firstError`。不同类型未恢复错误保留，不能全清。

## C09：HealthBridge 与写回隔离

首屏加载结束信号才释放前台维护；如果首次本地读取失败，信号也必须结束，不能让维护永久等待。后台启动不存在首屏时按后台机会的预算执行，不等待 SwiftUI。

export 先读 sequence/manifest/acknowledged_at 等 metadata；读 payload 只发生在实际需要发布或协议要求重放的批次。已确认批次回执验证和保留期清理独立有界扫描，按持久/可恢复 cursor 轮转，防止总从第一页开始饿死后续。新增 cursor 如需schema，重新进入 Planner migration 阶段，普通 Coder 不加表。

保持签名/sha256验证、同字节幂等重放、7天保留期、receipts与source无损。不能跳过校验、提前标 acknowledged、清空 outbox 或删除未确认 payload。仍未确认的7批不等同于仍未发布7批；发布与接收确认状态分别判定。

饮食写回保留稳定 syncID/删除成功后再替换。不能为了同步变快禁用用户已打开的功能；后台维护结果独立显示并可重试。

## C10：备份恢复与投影证据保全

现有备份不含 raw、sync_jobs 和 anchor，新 pending/dirty/control 表也不导入导出为用户内容。备份中的日汇总可以在本地没有 raw 时独立存在，不能恢复后立即被空聚合覆盖。

SyncWorkStore 另需一个单行 `sync_runtime_state` 保存 `restore_in_progress`、投影时区/版本、必要恢复标记；同一追加迁移创建，具体字段由 S05 冻结。S10B 将备份流程纳入 runner 的暂停/排空边界：开始导入前停接新执行机会、取消并等现有 writer 通道释放，持久写入 restore marker 后进入既有导入；成功才清 marker，失败/进程中断后保留 marker，由恢复流程显式继续。pending 保留，不能靠删 pending 解除暂停。原有 HealthBridge 恢复暂停也保持。

新投影不得把“当前没有 raw”自动解释为“恢复的日汇总为零”。actual deletion 有删除前行证据时可清理相应派生字段；仅版本/时区重建且无原始覆盖证据时，保留已恢复汇总并标记投影待补。部分类型 raw 尚未完成初始化时，不能全行置空其他恢复字段。此处优先保守保留并标记 pending；若需要新的字段级覆盖元数据，必须重新拆 Planner schema阶段，不让普通 Coder随意补默认值。

官方补充核验：[`HKError.Code.errorDatabaseInaccessible`](https://developer.apple.com/documentation/healthkit/hkerror/code/errordatabaseinaccessible) 明确对应受保护且锁定的 HealthKit 数据；[`HKObserverQueryCompletionHandler`](https://developer.apple.com/documentation/healthkit/hkobserverquerycompletionhandler) 说明处理完成回调及未响应退避。C07 的 deferred ledger 是本 App 的恢复设计，不能改写系统 API 含义。
