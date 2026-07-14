# 给 Coder 的提示词：STAGE-007B 可信饮食与热量缺口数据合同

## 任务开始

只执行 HealthManager `STAGE-007B`。不要实现 Today 页面、导航或相邻阶段，不读取记忆库。完整阅读：

- `docs/stages/STAGE-007B-trustworthy-diet-energy-contract.md`
- `docs/adr/ADR-001-normalized-meal-item-snapshots.md`
- `Core/Database/MealNutritionProjection.swift`
- `UI/Dashboard/DashboardData.swift`
- `UI/Dashboard/Cards/DietCard.swift`
- `UI/Dashboard/Cards/DeficitCard.swift`
- `UI/Dashboard/Detail/MetricDetailView.swift`
- `Tests/MealNutritionProjectionTests.swift`
- `Tests/DailyAggregatorEnergyTests.swift`

先确认：

1. 分支是 `codex/health-planning-20260713`。
2. `git merge-base --is-ancestor ff67ca1 HEAD` 成功。
3. 工作区起始干净。

任一不成立立即停止并报告，不修复基线。

唯一目标：让 dashboard 饮食与热量缺口严格保留 NULL/未知；只有 calories、active、basal 等所需事实完整时才汇总或计算，合法 0 仍是已知值。

实现顺序：

1. 新增 `Tests/DashboardNutritionEvidenceTests.swift`，用 in-memory GRDB 覆盖任务书 §6 的 10 类证据。不要声称未真实执行的 red。
2. 在 `DashboardData.swift` 复用 `MealNutritionProjection`，将今日 totals、单餐 kcal、日饮食序列、缺口序列和 breakdown 改成保守 optional 合同。
3. 用一个共享的小值类型/enum 表达无餐次、不完整、完整数值；今日 snapshot、日序列判断和 breakdown 不得各造一套状态。近 7 日卡片可增加一个明确的不完整标记来抑制 TrendChip。
4. 最小适配 `DietCard`、`DeficitCard` 与 deficit/diet detail 文案；显示事实，不增加建议或等级。
5. 保持完整数据路径的现有结果，例如 active 500 + basal 1500 − intake 1100 = deficit 900。

必须满足：

- 任一餐次 calorie 为 NULL，则当日 calorie total、饮食趋势点、intake 和 deficit 都未知；其他完整宏量字段可继续保留自己的总值。
- 单餐 NULL 仍是 nil；合法 0 仍显示/计算为 0。
- active 或 basal 任一缺失时 deficit 为 nil；无餐次不是摄入 0。
- `loadDietSeries` 的不完整日是 nil gap；`deficitSeries` 只含 active+basal+完整 intake 的交集。
- snapshot 的 `[DatedDouble]` 无法存 nil gap，因此窗口内有不完整 calorie 日时必须抑制 TrendChip 并显示事实提示，不能压缩后继续比较。
- `loadDeficitBreakdown` 保留共享 intake evidence，能区分无餐次与不完整餐次；deficit 为 optional，不用 `(x ?? 0)` 产生结论。
- 今日、序列与 breakdown 对完整性的定义一致：每个餐次值非 nil 且 finite。索引限定日期范围后读取 raw optional 并复用 `MealNutritionProjection` 或单一 helper；不允许 snapshot 与 SQL 各用不同规则。
- SQL 不用 `SUM(COALESCE(calories_kcal, 0))` 或同等方式吞掉未知。

允许修改：

- `UI/Dashboard/DashboardData.swift`
- `UI/Dashboard/Cards/DietCard.swift`
- `UI/Dashboard/Cards/DeficitCard.swift`
- `UI/Dashboard/Detail/MetricDetailView.swift`
- 新增 `Tests/DashboardNutritionEvidenceTests.swift`
- xcodegen 必要生成结果

禁止修改其他代码、schema/migration、`MealNutritionProjection`、MealStore、编辑/复用/证据 UI、HealthKit、同步、聚合算法、来源规则、docs。不要 commit、tag、push。

运行：

    xcodegen generate
    xcodebuild -project HealthManager.xcodeproj -scheme HealthManager -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -resultBundlePath /tmp/healthmanager-stage007b-coder-unit-20260714.xcresult -only-testing:HealthManagerTests/DashboardNutritionEvidenceTests -only-testing:HealthManagerTests/DailyAggregatorEnergyTests test -quiet
    xcodebuild -project HealthManager.xcodeproj -scheme HealthManager -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -resultBundlePath /tmp/healthmanager-stage007b-coder-build-20260714.xcresult build -quiet
    git diff --check
    git status --short

任一测试或 build 失败立即停止，保留原始结果，不连续猜修或扩大 helper。不要运行全量测试，由主架构师负责。

最终只报告：候选状态、改动文件、数据合同、定向测试/build 结果、静态 NULL 边界、未验证项、git status。

## 任务结束
