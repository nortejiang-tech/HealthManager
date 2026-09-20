# Apple Health 同步与冷启动评估 — 2026-09-20

状态：诊断与重构方案已完成；修复实现及真机冷启动端到端计时 **PENDING**。

用户症状：① 每次冷启动，前几秒没有数据；② App 可正常打开，但新数据不更新，手动同步后才更新。两者分别涉及首次本地读取与增量同步调度，不能合并成一个“HealthKit 很慢”的结论。

## 基线与验证边界

- Git HEAD：`1479db9e8aec80db1c557130315bcd0cb9e74949`，main。工作区原有 HealthBridge 等未提交改动全部保留；本轮只新增本报告目录。
- 真机安装版本经 devicectl 读取：0.8.1（16）。版本号与工作区一致不等同于所有源文件二进制对应关系已证明。
- 从已连接手机只读复制 App SQLite 主文件与 WAL 至 `/tmp/healthmanager-sync-audit-20260920.N3V3Ua/`；手机文件修改时间在复制前后未变，本地 `PRAGMA quick_check` 为 `ok`。这是诊断副本，不作为正式备份；没有停止/重装/重启手机 App。
- 主数据库约 1.94 GB；原始样本 3,597,222 条，其中有效样本 3,547,557 条；28 类 anchor 均存在，最近更新为 2026-09-20 01:23:44–45（上海时间）。不能声称“每次启动都全量导入”。
- 查询性能来自 Mac 上的真机数据库副本，不能外推为 iPhone 冷启动耗时。任务记录秒级精度，且长墙钟间隔可能包含挂起、锁屏或重启恢复，不是 CPU/查询执行时间。
- 已完整阅读工程方法论；本次提供诊断和 Proposed 方案，没有开始生产重构，不生成 Accepted ADR。

## 1. 冷启动首屏：本地展示被不必要的大表查询挡住

调用链：`HealthManagerApp.init` → `AppEnvironment` 同步初始化/数据库开启与迁移/恢复 → `RootView.task` 异步查询授权状态 → `DashboardView.task` → `DashboardLoader.loadSnapshot` → 一次性设置 snapshot/结束 loading。

`UI/Dashboard/DashboardData.swift:210–216` 在任何卡片读取之前执行：

```sql
SELECT COUNT(*) FROM health_samples_raw WHERE is_deleted = 0;
SELECT MAX(ingested_at) FROM health_samples_raw;
```

`MAX` 没有 `is_deleted = 0` 条件，因此不能使用 v6 的部分索引 `idx_raw_ingested_active`。查询计划为 `SEARCH health_samples_raw`，没有可用索引，只能遍历原始表寻找最大值。索引不是丢失，查询条件与索引条件不匹配。

| 查询 | Mac 诊断副本上三次耗时 | 执行计划/意义 |
|---|---|---|
| 当前 MAX(ingested_at) | 222.780 / 216.730 / 210.109 ms | 无匹配索引的大表遍历 |
| 有效样本 COUNT | 26.870 / 31.923 / 31.424 ms | 扫描有效样本部分索引，仍随样本规模增长 |
| 带 is_deleted=0 的 MAX（对照） | 0.017 / 0.003 / 0.002 ms | 使用覆盖索引；语义变为最后有效样本入库时间 |
| 当日活动卡片读取 | 0.017 / 0.004 / 0.002 ms | 日汇总表主键查找 |
| 7 天活动曲线读取 | 0.014 / 0.004 / 0.004 ms | 日汇总表日期索引 |

全仓搜索 `rawSampleCount` / `lastIngest` 确认，DashboardSnapshot 的这两个字段在当前趋势 UI 没有展示用途；数据质量详情自己独立查询。首屏为未展示的元信息扫描数百万行。

`DashboardView.swift:151–172` 只有整个快照读取完成后才更新卡片；没有跨冷启动的已验证显示快照。授权状态初始 `.unknown`，RootView 会等系统授权状态查询后才进入 MainTabView。AppEnvironment 在 MainActor 上同步开启数据库/迁移/恢复；HealthBridge 初始化还会读取 Keychain、解析文件夹 bookmark、写入来源身份。这些前置步骤的真机耗时尚未分段测量，不能说 MAX 查询解释了全部“好几秒”。

此外 bootstrap 每次还查询有效 raw 总数判断是否需要补聚合（`AppEnvironment.swift:119` 附近），与首屏重复统计。当前 projectionVersion 已更新时仍先做这次统计。

**判定：**可直接确认且可消除的首屏热路径负担；实际首帧延迟各阶段占比 PENDING。首屏代码没有 await 完整 HealthKit 同步，所以单纯加快 HealthKit 查询不能完整解决首屏问题。

## 2. 自动同步：busy 时丢触发，并提前确认 observer

`Core/Sync/SyncEngine.swift:128–141` 中 `guard !isBusy else { return }` 没有 pending 标记、类型集合或结束后补跑。`HealthKitObserver.swift:58–60` 无条件在该方法返回后调用 completionHandler。

确定性时序：

1. 当前同步已读完某个类型的旧数据，但仍在查询其他类型/聚合/写回。
2. Apple Health 为刚查过的类型写入新数据并发来通知。
3. 第二个 runIncremental 因 busy 返回；observer 随即确认。
4. 第一轮结束，没有自动补跑，新数据要等后续事件/重新前台/手动同步。

本轮抽取现有 `runIncremental` 方法原文（未修改方法体）和实际 SyncStateMachine，使用受控 coordinator 复现该时序。连续三次均得到：

```text
passes=1, sourceVersion=1, importedVersion=0, observerAcknowledged=true, isBusy=false
FAIL: observer event acknowledged but new data not imported; no follow-up pass scheduled
```

这是生产方法的调度层复现，HealthKit、数据库、聚合为测试替身，不是用户手机上某次事件的完整重放。复现失败表示现状存在缺陷；本轮没有修复，预期保持红。

**判定：**已复现的调度缺陷，与“手动一下就更新”高度吻合；不能断言用户每次漏更新都由此造成。

## 3. 锁屏失败没有被建模成等待解锁

真机 `sync_jobs` 中，自 2026-09-12 08:00 上海时间起至副本采集时：

- 23 次失败为 `HealthKit 查询失败：Protected health data is inaccessible`。
- 其中 BG incremental 为 19 次失败、5 次成功；失败记录墙钟 8–27 秒，平均约 24.5 秒。
- 另有 15 次中断后启动恢复为 failed。部分发生在已有文档记录的 9 月 19 日 HealthBridge 内存问题期间，不能把它们都归因于 HealthKit。
- observer 成功 130 次，其中 115 次的拉取任务信封耗时 ≤3 秒；130 次中位数为 0 秒（整数秒分辨率，不能理解成零成本）。健康数据正常可读时，拉取往往很快。

`IncrementalSyncCoordinator.swift:151–188` 只对授权类错误停止重试，其余错误统一同类型最多 3 次，间隔实际为 0.5 秒、1 秒；然后继续下一类型。没有 protected-data 状态、解锁通知重试或跨任务待处理记录。

HealthKit 查询包装没有 deadline，也没有用取消处理停止底层 HKQuery。BGTask expiration 仅取消 Swift Task；`try? Task.sleep` 会吞取消错误，循环也不检查取消。旧任务可能在挂起/恢复后继续占有 busy，使前台触发再被丢弃。手机中已有长墙钟任务支持调查这条路径，但精确运行过程仍需真机 trace。

**判定：**不可访问错误已由真机记录证实；当前恢复机制不足由代码证实。Apple 锁屏加密是系统边界，App 应延后重试，不能靠连续短重试解决。

## 4. 启动与授权的触发竞态

`HealthManagerApp.swift:49–52` 在 scene active 时只接受 `.granted/.partiallyGranted`。冷启动授权初值 `.unknown`，由 `RootView.task` 异步刷新；如果 active 先发生，本次同步会跳过。随后 `onAuthorizationChange()` 只启动 observer，没有显式补发前台同步。

Observer 的创建又依赖 SwiftUI RootView task/onChange，而不是独立的启动服务。Apple 对后台交付明确建议在 App 启动阶段创建 observer，保证系统交付前已经就绪。当前实现未提供独立于页面生命周期的完成保证。

**判定：**代码中存在该竞态窗口；实际冷启动事件先后顺序和 observer 是否补救需要真机生命周期 trace，不标作已复现的全部原因。

## 5. 增量拉取后的固定工作量

当前完整流程为：28 类串行 anchored query → 每类持久化 anchor → 不论新增/删除是否为零，重算最近 7 天 → 串行读取步数、基础能量系统统计 → 补写未同步饮食 → 更新进度/释放 busy → HealthBridge 导出。

- Observer 明知哪个类型变化，却没有传给协调器；每次都遍历全部 28 类。
- 7 天聚合每一天都会执行多条原始表查询与日汇总写入。无变化也写表；HealthBridge 开启时相关 UPDATE 还会产生导出变更。
- 固定 7 天同时有正确性局限：导入或删除更早日期的数据时，原始表更新不代表对应历史日汇总更新。应按新增/删除样本实际涉及的日期重算，并处理跨日睡眠及 workout 重叠依赖。
- 饮食写回发生在本轮读取之后，还可能触发新的 observer；busy 丢事件会使回读延迟到下一轮。
- nil/损坏 anchor 使用 predicate=nil、NoLimit，会一次返回全部历史；数据规模已接近 10 年。当前 28 个 anchor 都在，不能把这个边界当成日常冷启动主因，但需要分页防止初始化/恢复时失控。

## 6. 新增 HealthBridge 对前台负载的放大

当前 App 每次 active 都立即发起 export，HK 同步后和 background 也会发起。`BridgeSource.publish` 每次枚举全部 outbox，并对每一行 `SELECT *`，先把 payload 读入，再判断回执/是否已确认。

真机副本中 418 个 outbox 批次，411 已确认、7 未确认，payload 合计 217,869,109 bytes（207.78 MiB）。复放其只读 SQLite 部分会读取全部 418 个 payload；Mac 上约 27.7 ms，未包含 iCloud 文件协调、418 次回执检查、确认写入和手机资源竞争。不能把这个数当成完整导出耗时。

这条链路已采用 detached utility Task，因此不是“整段直接跑在主线程”；但文件 I/O、SQLite writer 队列、同步 job 的主线程同步写入会相互竞争。首次快照还有长事务边界。本轮不改 outbox/回执合同。

**判定：**不必要的重复 I/O 已确认；对当前首屏秒级延迟贡献仍待分段测量。应从首次展示路径移开，并按待发送批次读取 payload。

## 7. 状态与度量会掩盖真实完成

- `IncrementalSyncCoordinator.run` 在日聚合、系统统计和饮食写回前已关闭 job；sync_jobs 耗时不是用户等待的全流程耗时。
- SyncEngine 在聚合前已把 phase 切到 completed；UI 对 lastResult 另有失败判定，不能简单声称 UI 总是假报成功，但状态模型确实与实际工作阶段不一致。
- `rebuildDailyProjections` 用 `try?` 吞聚合错误；两类系统统计也各自捕获错误后继续，仍会增加 aggregationTick。
- BG handler 只要 runIncremental 返回且未取消，就给系统 `success: true`，没有判断本轮是否失败/被 busy 跳过。
- Manual pass2 成功后仍使用 pass1.firstError；pass2 新增为零也不清理该类型旧错误，可能出现数据已恢复但仍显示失败。这与此次“无明显失败提示、数据不刷新”不是同一个主问题。

## 建议的分阶段重构（Proposed）

### P0-A：首屏读取瘦身与启动分段计时

先移除趋势页不使用的全表元信息查询；若其他页面需要新鲜度，单独加载，明确区分最后有效样本入库、最后同步检查与最后成功完成时间。首屏直接读已有日汇总，不等 HealthKit/饮食写回/HealthBridge。合并首轮重复加载，数据库有变化才重新读取；减少隐藏卡片读取。是否增加持久化展示快照，依据优化后计时决定，并遵循本地数据保护/版本失效规则。

记录 App init、DB open/migrate/recovery、权限状态查询、首个本地快照、首次卡片展示五段。保留恢复成功后才允许同步的现有安全门；展示准备和自动同步准备独立建模，不能为快启动绕过恢复。

验收：真机已存数据冷启动多轮，分别报告首帧和首批有效卡片时间；建议首批有效卡片 p95 ≤1 秒作为初始目标（待基线校准），HealthKit 故意延迟时依旧可显示旧数据及其日期。目标不是本轮实测成果。

### P0-B：可靠的单任务调度器

所有前台、授权就绪、observer、解锁、BG、手动请求统一进入调度器。busy 时合并“待处理类型/刷新原因/事件代次”，当前任务完成后执行必要后续轮次；正确区分已经包含在本轮内的请求与本轮读取后到达的请求，避免无限补跑。

建立可持久化 pending 状态，查询完成后将样本、删除、anchor 与待投影日期在同一受控事务中提交；发生中断时不丢待处理工作。Observer 完成回调与其覆盖事件的处理/可恢复交接边界配套，确保每个回调恰好一次。protected-data 暂不可读转为 waiting-for-unlock，解锁或再次前台时补跑。超时/取消停止底层 HKQuery，释放 busy；BG 系统结果来自真实 outcome。

验收：忙碌期间新增/删除、授权晚于 active、锁屏→解锁、过期取消→再次前台、进程被杀后恢复，均无需手动按钮补救。需依赖注入后在真实协调器上测试，并补真机验证。

### P1：工作量随变化量增长

Observer 只标记相关类型；前台按新鲜度和 pending 做补查，首次/长时间未查时保留全部类型覆盖。重算 dirty dates，包含删除旧样本、跨午夜睡眠、能量计算关联。零变化跳过聚合。查询分页、每页原子提交 anchor；先保证恢复正确性，再根据计时试验 2–4 路有限并发，不能默认 28 路齐发。

拆分读取健康数据、饮食写回、日投影、HealthBridge 导出，用户可见数据就绪不被不相关导出拖延。手动普通刷新复用调度器；引导外部 App 推送的两阶段流程保留为独立排查操作。

验收：零变化无日汇总改写；某天某类型变化只刷新依赖日期；历史更正不漏刷新；分页被打断后可续跑、不重读全部历史、不重复样本。

### P2：HealthBridge 维护与状态统一

从前台首次数据展示路径移开维护工作。枚举 manifest/确认状态时不读大 payload；只为待发送项读取 payload；已确认回执校验与保留期清理由低优先级有界任务处理。必须保留校验、回执、重放、快照一致性及回滚合同，不能简单删除已确认批次。

统一阶段化结果（待解锁/正在读取/本地数据已更新/部分失败/后续导出中），分别记录查询、入库、投影、展示和导出耗时；增量 job 计数区分实际插入、去重和删除。

## 执行顺序与边界

优先实施 P0-A 与 P0-B：分别对应用户两个直接痛点。P1 才是完整效率重构，P2 单独处理跨系统合同。现有 AnchoredQuery + SQLite 日汇总的基本技术方向可保留，不需要推倒重写数据库或重导入历史。

本次未调用 EVO Coder：用户请求诊断/评估，未进入生产实现；诊断探针由 Planner 编写在临时目录。后续普通窄阶段按既定 Coder 信任门路由；跨任务恢复、原子提交、HealthBridge outbox/回执边界由 Planner 负责风险审查，不能直接作为普通低风险 Coder 任务。

## 官方依据

- [Apple：HealthKit 用户隐私与锁屏加密](https://developer.apple.com/documentation/healthkit/protecting-user-privacy)：锁屏时 HealthKit 数据可能无法读取；读权限被拒绝可能表现为无数据，因此不能从空结果认定授权。
- [Apple：HealthKit 后台交付](https://developer.apple.com/documentation/healthkit/hkhealthstore/enablebackgrounddelivery(for:frequency:withcompletion:))：启动阶段注册 observer、处理完成回调、后台交付需真机验证。
- [Apple：Observer completion handler](https://developer.apple.com/documentation/healthkit/hkobserverquerycompletionhandler)：回调表达已处理交付；未完成可能触发退避。
- [Apple：BGTask earliestBeginDate](https://developer.apple.com/documentation/backgroundtasks/bgtaskrequest/earliestbegindate)：它是最早执行时间，不是每小时准时执行保证。
- [Apple：Anchored Query](https://developer.apple.com/documentation/healthkit/hkanchoredobjectquery)：anchor 与分页是增量读取基础，nil anchor/无限 limit 会返回全部匹配数据。

## 复现与证据

`evidence/` 保留去健康样本内容的查询计划、计时、任务聚合、源码哈希和调度探针。原始手机数据库只在临时本地目录，没有进入项目、上传或展示健康值。

调度探针：`python3 evidence/make_probe.py` 后按脚本里的临时路径编译/执行；`BusyDropProbe.swift` 为本轮冻结的原文方法，可直接用 `swiftc -parse-as-library evidence/BusyDropProbe.swift -o /tmp/hm-busy-drop-probe` 编译，执行应 exit 1 复现现状。它不是未来完整 iOS 回归测试的替代品。

本次未对 App 做代码修复，未部署；没有回滚动作需要执行。最终真机冷启动性能归因、改善幅度和无人值守后台成功率仍为 PENDING。
