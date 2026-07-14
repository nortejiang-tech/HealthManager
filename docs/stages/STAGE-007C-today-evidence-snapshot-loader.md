# STAGE-007C：Today 可信证据快照与 Loader

> 状态：PASS（实现 commit `7df218f`；STAGE-007B 基线 `7b8825f`）
>
> 执行者：Coder；主架构师独立验收

## 1. 唯一目标

建立一个不依赖 SwiftUI、可用 in-memory GRDB 验证的 `TodayEvidenceLoader`，在一次只读数据库快照中返回“某个本地日”的睡眠/活动日聚合、带明确时间依据的餐次与用药日志、可信营养与热量缺口、数据质量告警及当日来源覆盖，为 STAGE-007D 的 Today 时间证据线提供唯一 payload。

本阶段不创建 TodayView、不改 Tab、不移动任何入口、不写展示文案。它只建立数据 seam；STAGE-007D 必须消费该 seam，不能在 View 中重新拼 SQL。

## 2. 产品与证据边界

已接受的方案 1 是“按时间展开的健康证据线”，但原型里有当前数据不能证明的精确睡眠起止、活动时刻和单一来源。本阶段必须把这些边界编码进类型：

- 餐次 `eaten_at` 是记录的进食时刻；用药日志有 `action_at` 时才有动作时刻，缺少 `action_at` 时 `scheduled_at` 只可作为日期归属和排序 fallback，不能展示为实际服药/跳过/延后时刻。两者进入统一 `timelineEntries`，但必须保留各自 time basis。
- `activity_metrics_daily` 只有按 sample `start_at` 归属到 date bucket 的日聚合与 `computed_at`；`computed_at` 是计算时间，不是活动发生时间，不得冒充时间线时刻。
- `sleep_seconds` 继续只表示“请求日开始的 Asleep 样本时长日聚合”，不等于“昨夜睡眠”。不生成睡眠起止、效率、来源或跨午夜推断，不回退到前一日或更早日期的“最近一次睡眠”；STAGE-007D 也不得把它标成“昨夜”。
- 当日 source coverage 只证明哪些来源在该日提供过 raw sample；它不能证明某个日聚合字段最终选择了哪个 dominant source。`sources_json` 仍是保留字段，不据此编造归因。
- 有真实用药日志才生成用药事件；没有日志不自动生成“漏服”。没有餐次不自动生成“早餐/午餐/晚餐待记录”，因为产品没有餐次计划或必须完成的用餐目标。
- 读取失败必须 throw 给调用方；不得返回与成功空查询相同的 `.empty`，STAGE-007D 才能区分 loading / failed / 成功无记录。

## 3. 深模块接口

新增 `Core/Today/TodayEvidenceLoader.swift`，所有类型保持 `Equatable, Sendable`。允许等价的内部拆分，但对外 payload 至少包含：

```swift
struct TodayEvidenceSnapshot: Equatable, Sendable {
    let dayStart: Date
    let dayEndExclusive: Date
    let dayKey: String
    let dailyAggregate: TodayDailyAggregateEvidence
    let timelineEntries: [TodayTimelineEvidenceEntry]
    let nutrition: MealNutritionEvidenceWindow
    let energyBalance: EnergyBalanceEvidence
    let dataQuality: TodayDataQualityEvidence
    let sourceCoverage: [TodaySourceCoverageEvidence]
}

struct TodayEvidenceLoader: Sendable {
    let database: DatabaseManager

    func load(
        forLocalDay day: Date,
        calendar: Calendar = .current
    ) async throws -> TodayEvidenceSnapshot
}
```

`load` 必须先以传入 `Calendar.startOfDay` 标准化，再用 `Calendar.date(byAdding: .day, value: 1, ...)` 得到真实 next-start；所有 epoch 查询使用 `[start, endExclusive)`。`dayKey` 必须使用传入 Calendar 的时区，不能依赖固定 UTC 或共享 `.current` formatter。

整个 payload 在一次 `DatabaseManager.asyncRead` 中建立，保证调用方只看到同一数据库读快照。Loader 内部隐藏 SQL、optional 映射、校验、JSON 解析、分组与稳定排序；不增加 protocol/repository/adapter。

## 4. 日聚合证据

`TodayDailyAggregateEvidence` 至少包含：

- `wasComputed: Bool`：当天 `activity_metrics_daily` 是否有行；不能由任一数值是否存在反推；
- `computedAt: Date?`：合法 epoch 对应的计算时间，只用于新鲜度；
- `asleepSeconds: Int?`；
- `steps: Int?`；
- `activeEnergyKcal: Double?`；
- `basalEnergyKcal: Double?`；
- `distanceM: Double?`；
- `exerciseMinutes: Double?`。

字段只有在有限、非负时才存在；合法 0 保留。负数、NaN、Infinity 变为 nil，但 `wasComputed` 仍保持真实行状态。不得读取 `sleep_efficiency` 或把更早日期的非空 sleep 回填为今日。

`energyBalance` 必须使用 STAGE-007B 已验收的 `EnergyBalanceEvidence`，其 active/basal 来自同一日聚合，intake 来自同一日 `MealNutritionEvidenceQuery`。不复制 active/basal/intake 的 fallback 计算。

## 5. 有时间依据的记录

`TodayTimelineEvidenceEntry` 是带 associated value 的枚举，只允许两类：

- `.meal(TodayMealEvidence)`；
- `.medication(TodayMedicationEvidence)`。

每条记录必须有稳定 ID 与 `timelineAt: Date`；餐次的依据是 `.eatenTime`，用药的依据是 `.actionTime` 或 `.scheduledFallback`。数组先按 `timelineAt` 升序；时间相同再按固定 kind 次序与数据库 ID 排序，保证测试和 SwiftUI identity 稳定。kind tie-break 只用于同秒确定性，不代表健康优先级。STAGE-007D 必须依据 time basis 决定文案，不能把 scheduled fallback 画成实际动作发生时间。

### 5.1 餐次

`TodayMealEvidence` 至少包含：持久化 meal ID、餐次类型、`eatenAt`、单餐保守 `MealNutritionTotals`、分项数量、去重且稳定排序的 provenance kinds、是否有任一分项被用户修订。

- 单餐 totals 必须调用 `MealNutritionProjection.project` 处理 parent `meal_records` 的四个字段；不复制 `isFinite && >= 0` 规则。
- 当日整体 `nutrition` 必须调用 `MealNutritionEvidenceQuery.load`，不得另写 `SUM`。
- provenance 只来自真实 `meal_items`。旧餐次没有分项时，来源是 unavailable/空集合，不能默认写“手工录入”。
- provenance 使用 Today 自己的 value enum 映射 `manual / aiEstimate / nutritionDatabase / nutritionLabel`，不把 GRDB record 暴露到 View payload。
- 本阶段不加载照片、不生成 item 展示文本、不重算 parent totals、不修改 MealStore。

### 5.2 用药

`TodayMedicationEvidence` 至少包含：日志 ID、可选 plan ID/plan name、`scheduledAt`、可选 `actionAt`、`timelineAt`、time basis、动作 `taken / skipped / deferred` 和保守 dosage。

- 日期归属与现有总结合同一致：`timelineAt = actionAt ?? scheduledAt`；只选择 timelineAt 落在半开本地日窗口内的日志。`actionAt` 非空时 basis 为 `.actionTime`；否则 basis 为 `.scheduledFallback`，只证明计划时间与日志状态，不证明动作在该时刻发生。
- plan name 通过 LEFT JOIN 读取；日志没有 plan 时保持 nil，不写“未知计划”到 Core。
- dosage 只能读取 `medication_logs.dosage_mg`，只有有限非负时存在，合法 0 保留。即使关联 plan 有 dosage，只要日志 dosage 为 nil 就必须保持 nil；计划剂量不能回填成实际动作剂量。
- 不解析计划生成“今日应服”事件，不修改通知调度或用药写入。

## 6. 数据质量与来源覆盖

`TodayDataQualityEvidence` 至少包含：

- `wasReconciled` 与合法 `computedAt`；
- completeness/freshness/conflict 三项 optional score；只接受 `[0, 1]` 内有限值；
- `missingMetricKeys: [String]?`：合法 JSON 数组解析、去空白、稳定去重；空数组是“已对账且无缺项”，nil 是没有记录、NULL 或 JSON 无法证明；
- 当日未确认 alerts，映射 ID、metric、severity、可选 message、createdAt；只读取 `acknowledged = 0` 且 `date = dayKey` 的记录，稳定排序。

Loader 不自行运行 `DailyReconciler`、不新增告警、不把 absent quality row 写成 100% 或“正常”。

`TodaySourceCoverageEvidence` 从当日非删除 `health_samples_raw` 按 `source_origin + source_name` 汇总，至少包含 Today 自己的 origin enum、可选 source name、样本数与最近 ingest 时间。“当日”严格按 sample 的 `start_at >= dayStart AND start_at < dayEndExclusive` 定义并命中 `idx_raw_start`；`MAX(ingested_at)` 只作为这些当日样本中的最近摄取时间，不参与日期归属。查询稳定排序；未知/非法 origin 映射为 `.unknown`。它是“当日覆盖”，不是特定 sleep/activity 字段归因。

餐次与用药本身的 provenance 已在各自事件中表达，不为了让 footer 好看而把它们伪装成 HealthKit raw source。

## 7. 自动化证据

新增 `Tests/TodayEvidenceLoaderTests.swift`，至少覆盖：

1. 成功空日：`timelineEntries` 空、nutrition 为 noMeals、energy deficit nil、aggregate 未计算、quality 未对账、alerts/source coverage 为空；不生成缺餐或漏服事件。
2. 本地日边界：起始 00:00 与最后一秒纳入、次日 00:00 排除；至少用一个跨 DST 的 Calendar，证明没有固定 `+86400`。
3. 统一记录排序：meal 与 medication 混合按 timelineAt 升序；同秒 tie-break 与 ID 稳定；餐次 basis 为 eatenTime，用药分别覆盖 actionTime 与 scheduledFallback。
4. 餐次 parent 营养包含合法 0、nil、负数与可往返的非有限值时，单餐 totals 与整日 nutrition 都遵守共享保守投影；不出现 0 fallback。
5. 餐次分项 provenance：多来源稳定去重、item count 与 user-edited 正确；无分项旧餐次保持 unavailable，不默认 manual。
6. 用药 `actionAt` 优先、nil 时只以 scheduledAt 归属/排序；taken/skipped/deferred、无 plan、非法 dosage 与窗口排除正确；plan 有 dosage 而 log dosage 为 nil 时仍保持 nil。
7. aggregate 行缺失和“行存在但字段未知”可区分；合法 0 保留，负数/NaN/Infinity 变 nil；前一日有 sleep、请求日无 sleep 时不得回填，并证明 payload 语义是请求日 start_at bucket 而非“昨夜”。
8. active 500 + basal 1500 + 完整 intake 1100 得到 deficit 900；无餐次、不完整 intake 或非法能量不计算 deficit。
9. quality row 缺失、合法空 missing 数组、合法缺项数组与 malformed JSON 四种状态不混淆；score 越界/非有限变 nil。
10. alerts 只含当日未确认记录；其他日期和已确认记录排除，severity/message 不丢失。
11. source coverage 只按 `start_at` 统计当日非删除 raw rows，按 origin/name 汇总并稳定排序；fixture 必须同时证明“start_at 当日但 ingested_at 次日”仍纳入、“start_at 日外但 ingested_at 当日”仍排除；不得把覆盖结果断言成某个聚合字段的来源。
12. 破坏必要读取表后调用 loader 会 throw，不返回成功空快照。

测试使用 `DatabaseManager.makeInMemoryForTesting()` 和真实迁移表，不 mock GRDB，不发网络、不访问 HealthKit。

## 8. 允许与禁止范围

允许：

- 新增 `Core/Today/TodayEvidenceLoader.swift`
- 新增 `Tests/TodayEvidenceLoaderTests.swift`
- 运行 `xcodegen generate` 生成本机被忽略的 `HealthManager.xcodeproj`

禁止：

- 修改 schema/migration、现有 record/Store/Aggregator/Reconciler/HealthKit/同步/通知/LLM
- 修改 Dashboard、Diet、Medication、Summary 或任何现有 View
- 创建 TodayView、Tab、导航、路由、卡片、文案、颜色、图标或预览
- 创建缺餐、漏服、健康评分、自动目标、建议、诊断或因果关系
- 把 nil/非法值改成 0，把读取错误改成空快照，或用 `computed_at` 冒充发生时间
- commit、tag、push 或修改 docs

若严格实现需要越界，停止并报告，不自行扩大范围。

## 9. 验收门

- 新增测试真实 red 后 green；不能把未捕获的理论失败写成 red 证据。
- `TodayEvidenceLoaderTests` 及 STAGE-007B 的营养/能量定向测试通过。
- 主架构师独立检查 diff、跑全量 unit/UI/build，并做双轴代码审查。
- 静态检查 Loader 只读、使用半开本地日窗口、没有独立 nutrition SUM、没有固定 `+86400`、没有 source/时间/缺餐推断。
- `git diff --check` 通过，候选代码仅含两个白名单新文件；生成的 xcodeproj 保持 ignored。
- 本阶段 Simulator 只证明 Loader 编译和真实 GRDB 行为，不证明 Today 页面；视觉与导航必须保持 NOT STARTED，进入 STAGE-007D。

## 10. 正式结果

- 状态：PASS
- 验收日期：2026-07-14
- 验收 commit：`7df218f23fda728e9d886168e0e6b953fe6dff4b`
- 执行说明：低成本 Coder 只留下未完成且存在合同矛盾的测试草稿，未交付 Loader 或 green 证据；主架构师按升级约定接管，重建可验收测试合同后完成实现。Coder 产出的原始失败包保留为过程记录，但不作为正式 red 依据
- 正式 red：修正后的 12 类合同测试在生产类型不存在时真实编译失败，exit 65、有效 xcresult、0 tests，失败仅为 `TodayEvidenceLoader` 及相关 value types 不存在；结果包 `/tmp/healthmanager-stage007c-architect-red-20260714-attempt01.xcresult`
- 首次 green：`TodayEvidenceLoaderTests` 12/12、0 failed、0 skipped；结果包 `/tmp/healthmanager-stage007c-architect-unit-20260714-attempt01.xcresult`
- 审查返工证据：非法/NULL origin 归一后重复分组用例先得到 4 行而预期 2 行，结果包 `/tmp/healthmanager-stage007c-review-red-20260714-attempt01.xcresult`；修复后 1/1，结果包 `/tmp/healthmanager-stage007c-review-green-20260714-attempt01.xcresult`。nil/空白 source name 全序与合并用例随后先得到 4 行而预期 3 行，结果包 `/tmp/healthmanager-stage007c-review-red-20260714-attempt02.xcresult`；修复后 1/1，结果包 `/tmp/healthmanager-stage007c-review-green-20260714-attempt02.xcresult`
- 定向回归：最终候选上的 `TodayEvidenceLoaderTests`、`DashboardNutritionEvidenceTests`、`MealNutritionProjectionTests`、`DailyAggregatorEnergyTests`、`DailyAggregatorSleepTests` 共 46/46、0 failed、0 skipped；结果包 `/tmp/healthmanager-stage007c-architect-targeted-20260714-attempt02.xcresult`
- 全量回归：`HealthManagerTests` 230/230、0 failed、0 skipped，结果包 `/tmp/healthmanager-stage007c-architect-full-unit-20260714-attempt01.xcresult`；`HealthManagerUITests` 6/6、0 failed、0 skipped，结果包 `/tmp/healthmanager-stage007c-architect-full-ui-20260714-attempt01.xcresult`。UI 运行期间出现既有 LLDB version snapshot 工具提示，但最终 xcresult 为 PASS
- 独立构建：iPhone 17 / iOS 26.5 Simulator build succeeded，0 error、0 warning、0 analyzer warning；结果包 `/tmp/healthmanager-stage007c-architect-build-20260714-attempt01.xcresult`
- 审查与静态门禁：规格/证据边界轴 PASS，深模块/代码质量轴 PASS；`git diff --check` 通过；Loader 只有一次 `asyncRead` 且无写入，半开窗口、`idx_raw_start`、共享 nutrition projection/query 与 energy evidence 均有静态和测试证据；未发现独立 calories SUM、固定 86400、sleep efficiency/source 或缺餐/漏服推断；生成的 Xcode project 继续被 ignore
- 残余风险：本阶段只证明数据 seam 与真实迁移 GRDB 行为；Today 页面、导航、视觉对照、真机行为均未在本阶段实现或宣称，按计划进入 STAGE-007D
