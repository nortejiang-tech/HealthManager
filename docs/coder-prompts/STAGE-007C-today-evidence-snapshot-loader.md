# 给 Coder 的提示词：STAGE-007C Today 可信证据快照与 Loader

> 归档状态：已执行。低成本 Coder 未完成实现，主架构师按升级约定接管并于 `7df218f` 验收；本提示词保留为任务交接记录，不得在当前 HEAD 重放其中固定起点或 attempt 路径。

你是实现 Coder。只执行 HealthManager `STAGE-007C`，直接修改共享工作区；不要改写提示词，不要实现 Today 页面或导航，不要读取任何 memory 文件。

## 0. 固定起点与停止条件

工作目录：

```text
/Users/nortepro/HealthManager
```

先执行并原样报告：

```bash
git status --short
git branch --show-current
git rev-parse HEAD
git check-ignore -v HealthManager.xcodeproj/project.pbxproj
```

预期：

- 分支 `codex/health-planning-20260713`
- HEAD `7b8825fa1f8a12e32be436d39b10cc45a7b74900`
- `git status --short` 只有本阶段两份 untracked docs，且不得修改它们；除此之外干净
- `HealthManager.xcodeproj` 被 `.gitignore` 忽略

任一不符立即停止，只报告实际状态；不得 reset、checkout、clean、stash、删除或覆盖现有改动。

## 1. 必须完整阅读

1. `docs/stages/STAGE-007C-today-evidence-snapshot-loader.md`
2. `docs/stages/STAGE-007A-today-information-architecture-selection.md`
3. `docs/stages/STAGE-007B-trustworthy-diet-energy-contract.md`
4. `Core/Database/MealNutritionEvidence.swift`
5. `Core/Database/MealNutritionProjection.swift`
6. `Core/Database/DatabaseManager.swift`
7. `Core/Database/Models/ActivityMetricsDaily.swift`
8. `Core/Database/Models/MealRecord.swift`
9. `Core/Database/Models/MealItemRecord.swift`
10. `Core/Database/Models/MedicationLog.swift`
11. `Core/Database/Models/MedicationPlan.swift`
12. `Core/Database/Models/DataQualityDaily.swift`
13. `Core/Database/Models/MissingDataAlert.swift`
14. `Core/Sync/SourceAttribution.swift`
15. `Tests/DashboardNutritionEvidenceTests.swift`
16. `Tests/DailyAggregatorSleepTests.swift`

先用不超过 15 条要点复述你将实现的数据接口、不变量、失败语义与文件边界。随后直接实施，不等待确认。

## 2. 唯一目标

新增一个纯数据 `TodayEvidenceLoader`：在一次 `DatabaseManager.asyncRead` 中，按调用方传入 Calendar 的单个本地日，返回日聚合、带明确 time basis 的餐次/用药时间线记录、共享 nutrition/energy evidence、数据质量告警和当日 source coverage。它是 STAGE-007D 唯一允许消费的 Today payload。

严格实现任务书第 3～6 节的类型与语义。所有输出 value type 必须 `Equatable, Sendable`；可以在同一个新文件内使用 Today 专属小枚举隔离 GRDB record，不新增 protocol/repository/adapter。

## 3. 测试先行

只允许新增：

```text
Core/Today/TodayEvidenceLoader.swift
Tests/TodayEvidenceLoaderTests.swift
```

先只新增 `TodayEvidenceLoaderTests.swift`，覆盖任务书第 7 节 12 类证据；执行 `xcodegen generate` 后运行定向测试，保留真实失败结果。下面三个 attempt-01 路径在开始时都必须不存在；任一路径已存在就停止并报告，不删除、不复用：

```bash
test ! -e /tmp/healthmanager-stage007c-coder-red-20260714-attempt01.xcresult
test ! -e /tmp/healthmanager-stage007c-coder-unit-20260714-attempt01.xcresult
test ! -e /tmp/healthmanager-stage007c-coder-build-20260714-attempt01.xcresult
xcodegen generate
xcodebuild \
  -project HealthManager.xcodeproj \
  -scheme HealthManager \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -resultBundlePath /tmp/healthmanager-stage007c-coder-red-20260714-attempt01.xcresult \
  -only-testing:HealthManagerTests/TodayEvidenceLoaderTests \
  test -quiet
```

缺少生产类型导致的编译失败可以作为 red，但必须保存命令、exit code 与 xcresult；若 xcodebuild 未生成有效结果包，明确写出，不能宣称已捕获 red。捕获 red 后不得删除或削弱已写的合同断言；只允许为实际接口编译对齐做不减覆盖的测试修正，并在最终输出逐项列出。

然后新增 Loader 实现。不得先写实现再补测试。

## 4. 实现硬约束

- `load(forLocalDay:calendar:)` 用 `startOfDay` 与 Calendar next-start；全部日期查询是 `[start, endExclusive)`，禁止固定 `+86400`、UTC 日 key 或 inclusive `end-1`。
- 一次 `asyncRead` 内完成全部读取；失败直接 throw，不 catch 成空快照，不写库。
- 当日整体 nutrition 只调用 `MealNutritionEvidenceQuery.load`；单餐 parent totals 只调用 `MealNutritionProjection.project`；energy 只调用 `EnergyBalanceEvidence`。
- 日 aggregate 行是否存在由 `wasComputed` 表达；字段只接受有限非负值并保留合法 0。sleep 只读请求日的 start_at bucket，不查询“最近非空值”，不读 efficiency/source，也不得称为“昨夜”。
- timeline entries 只含真实 meal/medication log，按 timelineAt 稳定排序并保留 `.eatenTime / .actionTime / .scheduledFallback` 依据；scheduled fallback 不能冒充实际动作时刻。不生成应吃餐次、应服药、建议或优先级。
- meal provenance 只来自真实 meal_items；无分项保持 unavailable，不默认 manual。
- medication 日期用 `timelineAt = actionAt ?? scheduledAt`，并区分 actionTime/scheduledFallback；plan LEFT JOIN 只取名称，dosage 只取 log 字段，绝不从 plan 回填，非法即 nil。
- quality 缺行、空数组、malformed JSON 必须可区分；score 只接受 `[0,1]` 有限值；alerts 只含当日未确认。
- source coverage 只按 `start_at >= dayStart AND start_at < dayEndExclusive` 证明当日 raw coverage并命中 `idx_raw_start`；`MAX(ingested_at)` 只表示纳入样本的最近摄取时间。删除样本排除，非法 origin 变 unknown，不为 activity/sleep 指定来源。
- Core 只返回事实 value，不写 SwiftUI 展示文案；alert 原始 message 可原样保留。

## 5. Green 验证

实现后执行：

```bash
xcodegen generate
xcodebuild \
  -project HealthManager.xcodeproj \
  -scheme HealthManager \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -resultBundlePath /tmp/healthmanager-stage007c-coder-unit-20260714-attempt01.xcresult \
  -only-testing:HealthManagerTests/TodayEvidenceLoaderTests \
  -only-testing:HealthManagerTests/DashboardNutritionEvidenceTests \
  -only-testing:HealthManagerTests/MealNutritionProjectionTests \
  -only-testing:HealthManagerTests/DailyAggregatorEnergyTests \
  -only-testing:HealthManagerTests/DailyAggregatorSleepTests \
  test -quiet

xcodebuild \
  -project HealthManager.xcodeproj \
  -scheme HealthManager \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -resultBundlePath /tmp/healthmanager-stage007c-coder-build-20260714-attempt01.xcresult \
  build -quiet

xcrun xcresulttool get test-results summary \
  --path /tmp/healthmanager-stage007c-coder-unit-20260714-attempt01.xcresult \
  --format json
xcrun xcresulttool get build-results summary \
  --path /tmp/healthmanager-stage007c-coder-build-20260714-attempt01.xcresult \
  --format json
git add -N Core/Today/TodayEvidenceLoader.swift Tests/TodayEvidenceLoaderTests.swift
git diff --check -- Core/Today/TodayEvidenceLoader.swift Tests/TodayEvidenceLoaderTests.swift
git status --short
git diff --stat -- Core/Today/TodayEvidenceLoader.swift Tests/TodayEvidenceLoaderTests.swift
```

若 attempt-01 green 或 build 非零，只允许一次针对明确编译/断言原因的窄修；不得删除、跳过、重命名规避或放宽 red 阶段合同测试。第二次必须改用对应的 `...-attempt02.xcresult`，保留 attempt-01。attempt-02 仍非零时立即停止，不继续试错。若 unit attempt-01 已失败，不运行 build；先按上述一次窄修重跑 unit。

静态检查：

```bash
rg -n 'SUM\s*\([^)]*calories_kcal|COALESCE\s*\([^)]*calories_kcal|86_?400|86400|sleep_efficiency|sources_json' Core/Today Tests/TodayEvidenceLoaderTests.swift
rg -n 'insert|update|delete|asyncWrite|write\s*\{' Core/Today/TodayEvidenceLoader.swift
```

对合理的单词命中逐项解释；不要通过改名掩盖违规。

## 6. 绝对禁止

- 除两个白名单新文件外修改任何 tracked 文件；两份 untracked STAGE docs 只读；只授权对两个候选文件执行 `git add -N` 以便差异检查，不得实际 stage 内容；`HealthManager.xcodeproj` 生成后仍必须 ignored
- schema/migration、Store、Aggregator、Reconciler、HealthKit、同步、通知、LLM 或已有 View 改动
- TodayView、Tab、导航、卡片、预览、颜色、图标或文案
- 网络请求、真实 HealthKit、真机、LLM 调用、外部数据源
- 默认值 0、成功空快照吞错、精确睡眠/活动时刻、单一 aggregate 来源、缺餐/漏服推断
- commit、tag、push

## 7. 最终输出

按顺序报告：

1. precheck 四条命令真实输出；
2. 实际修改文件；
3. red 命令、exit code、失败原因、xcresult 是否有效；
4. green 定向总数/失败/跳过与 result bundle；
5. build 状态、error/warning 数与 result bundle；
6. 12 类验收证据逐项对应到测试名；
7. 静态检查与 `git diff --check`；
8. 未执行项和残余风险。

不要宣布 STAGE PASS；主架构师独立验收后决定。
