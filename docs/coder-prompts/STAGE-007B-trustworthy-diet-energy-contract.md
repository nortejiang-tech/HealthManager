# 给 Coder 的提示词：STAGE-007B 可信饮食与热量缺口数据合同

## 任务开始

你是实现 Coder。只执行 HealthManager `STAGE-007B`，直接修改工作区；不要改写提示词，不要实现 Today 页面、导航或相邻阶段，不要读取任何 memory 文件。完整阅读：

- `docs/stages/STAGE-007B-trustworthy-diet-energy-contract.md`
- `docs/adr/ADR-001-normalized-meal-item-snapshots.md`
- `Core/Database/MealNutritionProjection.swift`
- `Core/Summary/SummaryGenerator.swift`
- `UI/Summary/SummaryView.swift`
- `UI/Diet/DietView.swift`
- `UI/Dashboard/DashboardData.swift`
- `UI/Dashboard/Cards/DietCard.swift`
- `UI/Dashboard/Cards/DeficitCard.swift`
- `UI/Dashboard/Detail/MetricDetailView.swift`
- `UI/Dashboard/Detail/ActivityDetailView.swift`
- `Tests/MealNutritionProjectionTests.swift`
- `Tests/SummaryGeneratorTests.swift`
- `Tests/DailyAggregatorEnergyTests.swift`

先确认：

1. 分支是 `codex/health-planning-20260713`。
2. `git merge-base --is-ancestor 676c211 HEAD` 成功。
3. 工作区起始干净。

任一不成立立即停止并报告，不修复基线。

唯一目标：以一个 Core 深模块统一持久化餐次的保守营养证据，使 Diet、Dashboard、ActivityDetail 和 deterministic daily/weekly summary 对 NULL、非有限值、合法 0 得出同一结论；只有 calories、active、basal 等所需事实完整时才汇总或计算。

实现顺序：

1. 新增 `Core/Database/MealNutritionEvidence.swift`，以一个小接口接收包含首尾的本地日窗口，隐藏 Calendar next-start、半开 epoch 查询、raw optional 映射、本地日分组、排序、finite 校验和 `MealNutritionProjection` 调用；同时放置 Dashboard/ActivityDetail 共用的 `EnergyBalanceEvidence`。不要增加 protocol/repository/adapter/ViewModel。
2. 扩展 `MealNutritionProjectionTests` 和新增 `DashboardNutritionEvidenceTests`，覆盖任务书 §7 的真实 in-memory GRDB 合同；不要声称未执行的 red。
3. 让 Dashboard 今日、逐餐、日序列、缺口序列和 breakdown 只消费共享 evidence；适配 DietCard、DeficitCard、MetricDetailView 的 optional 与事实文案。
4. 让 `ActivityDetailView` / `ActivityDetailSummary` 复用相同 evidence 与完整 energy 合同，不保留独立 SUM/补 0 逻辑。
5. 让 `DietView` 今日 totals 复用相同 evidence；无餐次或不完整字段显示“—”和事实提示，合法 0 仍显示 0。
6. 让 `SummaryGenerator` 日报/周报复用相同 evidence；不完整字段只输出状态文本，不输出虚假数值/numeric finding。为新 summary 写入 nutrition-evidence contract marker；提供“读取当前合同或本地重建”与“联网前无条件重建”的小路径。
7. 让 `SummaryView` 展示旧 summary 前经由当前合同校验/重建；AI 刷新失败时也重新读取本地记录，确保旧 LLM 评注已从画面失效。不要启用或调用真实 LLM。
8. 保持完整数据路径的现有结果，例如 active 500 + basal 1500 − intake 1100 = deficit 900。

必须满足：

- 一个 `DietCaloriesEvidence`（或等价小枚举）统一表达 noMeals / incomplete / complete(Double)；只有有限非负输入和有限总和才 complete，合法 0 是 complete(0)。旧版 `meal_records` 没有非负 CHECK，必须用真实 DB 负值测试。
- 一个窗口 evidence 值同时给出 mealCount、保守 totals、calories evidence 和按本地日期升序的 day evidence。
- 读取入口形如 `load(db:fromLocalDay:throughLocalDay:calendar:)`，内部以 Calendar 标准化起始日并计算结束日的 next-start，再用 `eaten_at >= ? AND eaten_at < ?` 限定现有索引范围。消费者不得直接传现有 inclusive `end-1`，不得固定 `+86400`，不得全局改变其他健康指标沿用的 inclusive range。
- `MealNutritionProjection` 要求输入 `>= 0 && isFinite` 且最终求和结果 finite；某营养字段不完整不污染其他字段。
- `MealNutritionProjection` 提供一个共享单值合法化函数；Dashboard/Diet 逐餐显示调用它，UI 不复制合法性规则。
- 任一餐次 calories 为 NULL/负数/非有限或求和溢出，则对应窗口/日期 calorie total、趋势点、intake 和 deficit 均未知；单餐 nil/非法值不改成 0。
- 一个共享 `EnergyBalanceEvidence`（或等价值类型）供 Dashboard 与 ActivityDetail 使用：active/basal 各自必须为有限非负值且和 finite，intake 必须 complete，最终 deficit 必须 finite；deficit 可以是负数。
- active 或 basal 任一缺失时 burned/deficit 按任务书语义为 nil；无餐次不是摄入 0。
- `loadDietSeries` 的不完整日是 nil gap；`deficitSeries` 只含 active+basal+完整 intake 的交集。
- snapshot `[DatedDouble]` 窗口内有不完整 calorie 日时必须抑制 TrendChip，不能压缩后继续比较。
- `loadDeficitBreakdown` 能区分 noMeals/incomplete；deficit 为 optional，不用 `(x ?? 0)` 产生结论。
- `DietView`、`ActivityDetailView.refresh`、日报、周报均调用共享读取接口，不复制 SQL/完整性判定。
- 日报/周报保留真实 mealCount；只有完整字段才有数值文本/numeric finding。
- 新 summary findings 带当前 contract marker。旧 summary 缺 marker 时，在 SummaryView 展示前本地重建并清空旧 LLM 字段。
- `augmentDailyWithLLM` / `augmentWeeklyWithLLM` 必须在 `LLMClient.complete` 前无条件重建 deterministic summary，使用当次保守文本并先清空旧 LLM 字段；测试只调用本地准备/校验路径，不发网络请求。
- 所有生产 Swift 不再用 `SUM(COALESCE(calories_kcal, 0))`、`COALESCE(SUM(calories_kcal), 0)` 或独立 `SUM(calories_kcal)` 汇总持久化摄入。

允许修改：

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
- `HealthManager.xcodeproj/project.pbxproj`（仅 xcodegen 必要结果）

禁止修改其他代码、schema/migration、MealStore、餐食编辑/复用/证据 UI、HealthKit、同步、DailyAggregator 算法、来源规则、数据质量定义、LLM prompt/provider/network implementation、docs。不要 commit、tag、push。

运行：

    xcodegen generate
    xcodebuild -project HealthManager.xcodeproj -scheme HealthManager -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -resultBundlePath /tmp/healthmanager-stage007b-coder-unit-v2-20260714.xcresult -only-testing:HealthManagerTests/DashboardNutritionEvidenceTests -only-testing:HealthManagerTests/MealNutritionProjectionTests -only-testing:HealthManagerTests/SummaryGeneratorTests -only-testing:HealthManagerTests/DailyAggregatorEnergyTests test -quiet
    xcodebuild -project HealthManager.xcodeproj -scheme HealthManager -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -resultBundlePath /tmp/healthmanager-stage007b-coder-build-v2-20260714.xcresult build -quiet
    rg -n 'SUM\s*\(\s*(COALESCE\s*\()?\s*calories_kcal|COALESCE\s*\(\s*SUM\s*\(\s*calories_kcal' Core UI --glob '*.swift'
    git diff --check
    git status --short

`rg` 预期无持久化摄入聚合命中；若只有注释命中，报告具体位置。任一测试或 build 失败立即停止，保留原始结果，不连续猜修或扩大 helper。不要运行全量测试，由主架构师负责。

最终只报告：候选状态、改动文件、共享模块接口、各消费者数据合同、定向测试/build 结果、静态 NULL 边界、未验证项、git status。

## 任务结束
