# STAGE-007B：可信饮食与热量缺口数据合同

> 状态：READY（STAGE-007A 已选择方案 1；软件实现基线 `ff67ca1`）
>
> 执行者：Coder；主架构师独立验收

## 1. 唯一目标

建立一条全局一致的“持久化餐次 → 保守营养证据”接口，修正现有页面和总结把未知营养静默当成 0、或用不完整组成继续计算热量缺口的问题，为后续 Today 证据时间线提供可信 payload。

本阶段不实现 Today 页面或导航。只修正现有饮食主页面、Dashboard 饮食/缺口、活动详情、确定性日报/周报及其 LLM 输入的 unknown/complete 语义。

## 2. 已确认的问题

当前共有七条会制造错误确定性的路径：

1. `DashboardLoader` 今日餐次读取用 `row[...] ?? 0` 累加 calories/protein/fat/carbs；任一餐次为 NULL 时，汇总看起来仍是完整数字。
2. `DietCardData.MealRow.kcal` 非 optional，单餐未知热量被显示成 0。
3. Dashboard 日饮食序列与缺口序列使用 `SUM(COALESCE(calories_kcal, 0))`；不完整日被画成完整数据点。
4. Dashboard 缺口用缺失组成的 0 替代值计算；缺少 active、basal 或完整摄入时仍可能显示 `burned - intake`。
5. `ActivityDetailView` 独立执行 `SUM(COALESCE(calories_kcal, 0))`，`ActivityDetailSummary` 也用缺失 active/basal/intake 的 0 计算。
6. `DietView` 用四个 `COALESCE(SUM(...), 0)` 和非 optional totals；饮食主页面会与 Dashboard 对同一天给出相互矛盾的结论。
7. `SummaryGenerator` 日报和周报将不完整餐次汇总成确定摄入；日报文本还可能继续作为 LLM 输入，放大错误确定性。

这与 ADR-001 “未知值继续是未知值”、工作流验收协议“不得把 nil 静默变成 0”及本产品对活动能量/热量缺口可信度的优先级冲突。若只修 Dashboard，STAGE-009 不能宣称可信摄入合同 PASS。

## 3. 深模块与核心类型合同

在 `Core/Database` 建立一个深模块，seam 位于持久化餐次与所有读取消费者之间。接口只接受 GRDB `Database`、包含首尾的本地日窗口（`fromLocalDay...throughLocalDay`）和必要的 Calendar，并返回一个窗口证据值；本地日标准化、由 Calendar 计算“结束日的次日零点”、半开 epoch SQL `[start, endExclusive)`、raw optional 映射、逐日分组、排序、finite 校验和保守投影都隐藏在 implementation 内。

建议新增 `MealNutritionEvidence.swift`，接口至少返回以下等价信息；允许在不削弱语义的前提下调整命名：

- `DietCaloriesEvidence: Equatable, Sendable`：
  - `noMeals`：时间窗内没有餐次；
  - `incomplete`：存在餐次，但至少一个 calories 为 nil、负数、非有限，或合法输入求和后溢出为非有限；
  - `complete(Double)`：全部餐次 calories 均为有限非负值且总和有限；合法 0 属于完整。
- `MealNutritionDayEvidence: Equatable, Sendable`：本地日期、餐次数、现有 `MealNutritionTotals` 与 calories evidence。
- `MealNutritionEvidenceWindow: Equatable, Sendable`：窗口餐次数、整个窗口的保守 totals、窗口 calories evidence、按本地日期升序的 day evidence。
- 单一读取入口，例如 `MealNutritionEvidenceQuery.load(db:fromLocalDay:throughLocalDay:calendar:)`；今日、序列、周总结都调用它，不在消费者复制 SQL、epoch 边界或完整性规则。

`MealNutritionProjection` 继续是四个营养字段的唯一保守求和实现：

- 无餐次时 totals 为 nil；
- 有餐次时，每一字段只有在全部餐次该字段非 nil、输入为有限非负值且最终总和 finite 时才有总值；旧版 `meal_records` 没有非负 CHECK，因此不能假设持久化值已经合法；
- 某字段不完整只影响该字段，不污染其他完整字段；
- 合法 0 是已知值，不得被改回 nil。
- 单值合法化也由该模块提供一个共享小函数；Dashboard 与 Diet 的逐餐展示调用它把 nil/负数/非有限值转为未知，不在 UI 复制 `>= 0 && isFinite`。

不引入 ViewModel、protocol、repository、adapter 或新服务。GRDB 已有 in-memory 测试替身，因此该 seam 是模块内部 seam，不增加假想抽象。

## 4. Dashboard、活动详情与序列合同

- `DietCardData` 使用窗口证据中的 `MealNutritionTotals?`；`MealRow.kcal` 改为 `Double?`，逐餐保留未知。
- 新增或复用一个共享 `EnergyBalanceEvidence: Equatable, Sendable`（允许等价命名），供 Dashboard 与 ActivityDetail 同时计算：active、basal 必须各自为有限非负值，两者和必须 finite；intake 必须为 complete 且有限非负；最终 deficit 必须 finite。deficit 可以为负数（热量盈余），但不能是 NaN/Infinity。
- `DeficitCardData` 保存该 shared energy evidence；`todayBurned` 只有合法 active+basal 都存在且和 finite 时才有值，`todayDeficit` 只有合法 active+basal+完整 intake 三项齐备且派生结果 finite 时才有值。
- 无餐次不是摄入 0；active、basal、intake 任一缺失都不得以 0 替代。已知 0 继续是已知值。
- snapshot 的 `DietCardData.last7Days` 仍是不可选 `DatedDouble`，因此只保存完整记录日，并增加明确的近 7 日不完整标记。窗口内出现有餐次但 calories 不完整的日期时，`DietCard` 必须抑制 TrendChip，不能压缩缺日后比较首尾值。
- `loadDietSeries` 把有餐次但 calories 不完整的日期保留为 nil gap；完整 0 日保留 0 点。
- `deficitSeries` 只为合法 active、合法 basal 与完整 intake 同日齐备且 burned/deficit 均 finite 的日期生成点；消耗-only、摄入-only、非法能量、无餐次或不完整摄入都不生成缺口。
- `loadDeficitBreakdown` 保留 shared intake evidence，能区分无餐次与不完整；deficit 为 optional，仅三项齐备时存在。
- `ActivityDetailView.refresh` 调用同一读取接口；`ActivityDetailSummary` 不保留第二套 `intake ?? 0` / `(active ?? 0) + (basal ?? 0)` 计算。
- 所有餐次查询由共享模块用 `eaten_at >= ? AND eaten_at < ?` 命中现有索引，再在 Swift 按传入 Calendar 的本地日期分组；消费者不得把现有 inclusive `end-1` 直接传入，不得用固定 `+86400` 推算次日，也不得全局改动 SummaryGenerator 供其他健康指标使用的 inclusive range。共享模块必须用 `Calendar.date(byAdding:.day, value:1, ...)` 得到真实 next-start。
- 保持本地日边界、日期排序、现有 schema 与 migration 不变。

## 5. 饮食主页面与现有详情文案

`DietView`：

- 今日 totals 直接来自共享窗口证据，不执行独立 SUM。
- 无餐次时四项显示“—”，并说明“今日尚无餐次记录”或同等事实；不得显示四个 0。
- 有餐次时 P/F/C/calories 各自显示保守总值或“—”；合法 0 显示 0。
- 近期逐餐行也使用共享单值合法化；旧数据中的负数/非有限营养值显示“—”，不得作为合法摄入展示。
- 任一字段不完整时显示事实性提示，例如“部分餐次营养信息未完整记录”；不新增建议、等级或目标。

`DietCard`：

- 无餐次继续显示“今天还没记录”。
- 有餐次但总热量未知时主值为“—”，并说明存在未填写热量的餐次。
- 单餐未知显示“—”，合法 0 显示 0；只有总热量完整时才绘制按餐 ProgressView。
- 近 7 日存在不完整 calorie 记录时不显示 TrendChip 的涨跌结论，改为事实性不完整提示。

`DeficitCard`、缺口详情与 `ActivityDetailView`：

- 缺口未知时按事实说明缺少 active、basal、饮食记录或完整饮食热量；不固定只写“待 basal 数据补充”。
- 已知组成仍可分别显示；总消耗只在 active+basal 齐备时显示，总缺口只在三项齐备时显示，否则为“—”。
- footnote 明确“只在当日所需字段完整时纳入图表/计算”。
- 不新增颜色等级、目标、建议或诊断。

## 6. 日报、周报与 LLM 输入合同

- `SummaryGenerator` 日报、周报都调用共享窗口证据，不直接 `SUM(calories_kcal)`。
- 无餐次时可以不生成饮食行；有餐次时始终保留真实餐次数。
- calories 或 protein 完整时才输出对应数值和 numeric finding；不完整字段输出“热量记录不完整”/“蛋白质记录不完整”或同等事实，不输出 0，不写入虚假的 numeric finding。
- 周报只要窗口内任一餐次 calories 不完整，就不得输出整周确定摄入；完整且总和为 0 的窗口仍输出 0。
- 新生成的日报/周报在既有 findings JSON 中写入明确的 nutrition-evidence contract version；不新增 schema 或 migration。
- `SummaryView` 读取已持久化总结时，必须通过 `SummaryGenerator` 的“读取当前合同或本地重建”路径。缺少当前 contract marker 的旧总结在展示前本地重建；旧 `llm_text` / model / timestamp 同时失效，不允许旧错误文本继续显示。
- `augmentDailyWithLLM` / `augmentWeeklyWithLLM` 在调用 `LLMClient.complete` 前必须无条件本地重建对应 deterministic summary，并直接使用这次返回的保守文本；重建先清空旧 LLM 评注。若网络随后失败，`SummaryView` 也要刷新本地状态，不能继续在屏幕上保留旧评注。
- 本阶段不修改 LLM prompt、provider 或网络请求实现，也不在测试中发起真实 LLM 请求。

## 7. 自动化证据

新增 `Tests/DashboardNutritionEvidenceTests.swift`，并扩展 `MealNutritionProjectionTests`、`SummaryGeneratorTests`。至少覆盖：

1. 深模块空窗口：totals nil、evidence 为 noMeals、days 为空。
2. 完整多餐：窗口与逐日汇总正确；合法 0 保持 complete(0)。
3. 任一 calories 为 nil：窗口与对应日 calories evidence 均 incomplete，已知单餐值不被改成 0；逐餐共享合法化保留合法 0，并把 nil/负数/非有限值变为未知。
4. 四个营养字段分别保守汇总：某字段任一 NULL 只使该字段 nil。
5. 负数、非有限输入或合法值求和溢出：用真实 in-memory GRDB 写入旧表可接受的负 calories/P/F/C，并覆盖数据库可往返的非有限形态；对应字段在今日、逐日、序列、breakdown 与总结中都按不完整处理。
6. 半开时间窗与本地日分组：起始日 00:00 与结束日 23:59:59 被纳入，结束日次日 00:00 被排除；逐日按日期升序，查询仅限请求窗口。至少一项测试使用会跨 DST 的 Calendar，证明实现没有固定 `+86400`。
7. snapshot 无餐次：即使 active+basal 齐备也不计算 deficit。
8. snapshot 完整路径：active 500 + basal 1500 − intake 1100 = deficit 900；合法 0 保持已知。
9. active 或 basal 任一缺失、负数、非有限，或 active+basal / burned-intake 溢出：不生成 burned/deficit 中相应结论；合法 deficit 负数继续保留。
10. snapshot 近 7 日：完整日保留数值；不完整 calorie 日设置趋势抑制标记。
11. 饮食周/月/年序列：完整日有点，不完整日为 nil gap，完整 0 日为 0 点。
12. 缺口序列与 breakdown：只在三项齐备时有 deficit，并区分 noMeals/incomplete。
13. `ActivityDetailSummary` 与 refresh 使用共享 evidence；无餐次、不完整或缺 active/basal 均不计算 deficit。
14. 日报：不完整 calories/protein 只输出事实状态，不出现对应 0 数值或 numeric finding；完整 0 仍可输出 0；日报窗口纳入当日最后一秒、排除次日零点。
15. 周报：任一不完整餐次抑制整周确定摄入；完整窗口保持现有数值结果；纳入第 7 日最后一秒、排除第 8 日零点。
16. 旧日报/周报：预置缺少 contract marker 且含虚假 0 与旧 `llm_text` 的记录；“读取当前合同”路径在展示前本地重建、写入 marker 并清空旧 LLM 字段。
17. AI 准备路径：不发网络请求，证明 augmentation 使用的 base text 来自当次保守重建，且即使后续网络失败也已使旧 LLM 评注失效。

现有 `DailyAggregatorEnergyTests` 必须继续通过，特别是完整 1,100 kcal 摄入下的 900 kcal 缺口。

## 8. 允许与禁止范围

允许：

- 新增 `Core/Database/MealNutritionEvidence.swift`
- `Core/Database/MealNutritionProjection.swift`
- `Core/Summary/SummaryGenerator.swift`
- `UI/Summary/SummaryView.swift`
- `UI/Diet/DietView.swift`
- `UI/Dashboard/DashboardData.swift`
- `UI/Dashboard/Cards/DietCard.swift`
- `UI/Dashboard/Cards/DeficitCard.swift`
- `UI/Dashboard/Detail/MetricDetailView.swift`
- `UI/Dashboard/Detail/ActivityDetailView.swift`
- 新增 `Tests/DashboardNutritionEvidenceTests.swift`
- `Tests/MealNutritionProjectionTests.swift`
- `Tests/SummaryGeneratorTests.swift`
- xcodegen 必要生成结果

禁止：

- 修改 schema、migration、`MealStore`、餐食编辑/复用/证据 UI 或 HealthKit 写入
- 修改 DailyAggregator 能量算法、来源优先级、同步、对账阈值或数据质量定义
- 实现 TodayView、时间线、Tab、更多页或 STAGE-007C/D
- 新增默认目标、自动建议、热量等级、诊断、食品库、OCR、条码或 AI 动作
- 修改 LLM prompt/provider/network implementation，或在测试中发起真实 LLM 网络请求
- 用 0、空字符串或隐藏行伪装未知
- 修改 docs、commit、tag、push

若所需修复必须越界，停止并报告，不自行扩大范围。

## 9. 验收门

- 新测试、`MealNutritionProjectionTests`、`SummaryGeneratorTests` 与 `DailyAggregatorEnergyTests` 定向通过。
- 主架构师独立跑全量 unit、全量 UI 和 build。
- 静态检查所有生产 Swift 不再用 `SUM(COALESCE(calories_kcal, 0))`、`COALESCE(SUM(calories_kcal), 0)` 或独立 `SUM(calories_kcal)` 生成持久化摄入事实。
- 静态检查 UI/summary 消费者不复制 raw meal 完整性判定，且 LLM augmentation 只消费保守 deterministic summary。
- 静态检查消费者不传 inclusive `end-1` 或固定 `+86400` 给餐次证据查询；旧 summary 展示与 augmentation 均经过当前合同校验/重建。
- `git diff --check` 通过，diff 只含白名单文件和 xcodegen 必要结果。
- Simulator 证明 optional 合同、页面编译与既有交互未回归；它不证明用户是否完整记录真实饮食，该事实继续由 UI 明示。

## 10. 正式结果

- 状态：PENDING
- 验收日期：—
- 验收 commit：—
- 证据：—
- 残余风险：—
