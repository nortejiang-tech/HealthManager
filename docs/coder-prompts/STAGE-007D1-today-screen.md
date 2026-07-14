# 给 Coder 的提示词：STAGE-007D1 Today 证据首屏

你是实现 Coder。只执行 HealthManager `STAGE-007D1`，直接修改共享工作区；不要实现五栏接线或 More，不要读取任何 memory 文件。

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
- HEAD `a76d9580b2466843bd283e0ba10c8823439a6ce4`
- `git status --short` 只有以下两份 untracked docs，且不得修改：
  - `docs/stages/STAGE-007D-today-timeline-and-five-tab-navigation.md`
  - `docs/coder-prompts/STAGE-007D1-today-screen.md`
- `HealthManager.xcodeproj` 被 ignore

任一不符立即停止，只报告实际状态；不得 reset、checkout、clean、stash、删除或覆盖现有改动。

## 1. 必须完整阅读

1. `docs/stages/STAGE-007D-today-timeline-and-five-tab-navigation.md`
2. `docs/stages/STAGE-007A-today-information-architecture-selection.md`
3. `docs/stages/STAGE-007C-today-evidence-snapshot-loader.md`
4. `Core/Today/TodayEvidenceLoader.swift`
5. `Core/Database/MealNutritionEvidence.swift`
6. `UI/Dashboard/Cards/CardTheme.swift`
7. `UI/Dashboard/Cards/DashboardCard.swift`
8. `UI/Dashboard/Cards/HeroHeader.swift`
9. `UI/Diet/DietView.swift` 的根状态/导航/refresh 部分
10. `UI/Medication/MedicationView.swift` 的根状态/导航/refresh 部分
11. `App/AppEnvironment.swift`
12. `UITests/SmokeTests.swift`

视觉参考资产：

```text
/Users/nortepro/.codex/generated_images/019f5b92-8926-7d51-af2d-50fac3a30f9f/exec-fb6ed132-cfec-404c-9f9b-9808108439f4.png
```

先用不超过 15 条要点复述：Today 唯一数据入口、3 个 load case（loading / loaded / failed）与 4 个 render scenario（loaded 非空 / loaded 空日 / loading / failed）、日汇总与有时刻记录的边界、scheduled fallback 文案、来源边界、跨 Tab 回调和三个允许文件。随后直接实施，不等待确认。

## 2. 唯一目标与文件边界

只允许新增：

```text
UI/Today/TodayEvidencePresentation.swift
UI/Today/TodayView.swift
Tests/TodayEvidencePresentationTests.swift
```

本步建立完整可编译、可 preview、可单测的 Today 页面，但不修改 `App/RootView.swift`，因此不接入现有 Tab。页面必须消费 `TodayEvidenceLoader`；跨饮食/用药/趋势只暴露一个明确的 `TodayDestination` value enum 与回调，D2 再接线。

不得修改任何已有 tracked 文件、两份 docs、schema、Core Loader、现有 View 或 UITests。不得新增 ViewModel/protocol/repository/router/依赖。

## 3. 测试先行

先只新增 `Tests/TodayEvidencePresentationTests.swift`，覆盖任务书第 8.1 节前八类 unit 证据；第九类越界词由第 6 节 shell 静态扫描验证，不写读取源码路径的脆弱 unit。测试应直接调用纯值 `TodayEvidencePresentation` 的 API；不使用截图断言、不连 DB/HealthKit/网络。

下面路径开始时必须不存在；存在则停止，不删除、不复用：

```bash
test ! -e /tmp/healthmanager-stage007d1-coder-red-20260714-attempt01.xcresult
test ! -e /tmp/healthmanager-stage007d1-coder-unit-20260714-attempt01.xcresult
test ! -e /tmp/healthmanager-stage007d1-coder-build-20260714-attempt01.xcresult
xcodegen generate
xcodebuild \
  -project HealthManager.xcodeproj \
  -scheme HealthManager \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -resultBundlePath /tmp/healthmanager-stage007d1-coder-red-20260714-attempt01.xcresult \
  -only-testing:HealthManagerTests/TodayEvidencePresentationTests \
  test -quiet
```

缺少展示类型导致编译失败可作为 red，但必须保存 exit code 与有效 xcresult。若测试本身有语法/fixture 错误，先修正测试并改用 `...red...attempt02.xcresult` 重新取得干净 red；不得把错误测试当合同证据。

取得 red 后再新增两个生产文件，不得先写实现后补测试。

## 4. 实现硬约束

### 4.1 `TodayEvidencePresentation`

- 纯值/静态展示 seam，只处理日期、24 小时时间、单位、meal/action/origin/provenance label 与 unknown 文案；不得查 DB、修改 snapshot 或重新计算 nutrition/energy/date window。
- Calendar/Locale 可显式传入以便测试；不得共享可变 DateFormatter，不得硬编码 2026-07-14。
- sleep 必须覆盖 nil、0、小时分钟；任何 API 都不得输出“昨夜”或推断起止。
- energy 只消费 `EnergyBalanceEvidence` 已给出的 burned/intake/deficit；noMeals/incomplete/burn 缺失必须有不同事实文案。
- medication timing API 必须让 `.actionTime` 返回实际 `HH:mm`，`.scheduledFallback` 返回“计划 HH:mm”并提供“动作时刻未记录”；不得从 plan dosage 推断 log dosage。
- meal 空 provenance 返回“来源未记录”，不默认 manual；source coverage 使用 Today origin label，并保留“原始样本覆盖”措辞。

### 4.2 `TodayView`

- `@EnvironmentObject AppEnvironment/SyncEngine`；本地 state 是互斥 loading/loaded/failed value，不新增引用 ViewModel。
- 唯一读取：`TodayEvidenceLoader(database: environment.database).load(forLocalDay: Date(), calendar: .current)`；`.task`、`.refreshable`，响应 `localDataTick`、`aggregationTick`、`lastResult`；取消不显示失败。
- 所有触发必须调用同一个 reload seam。新请求取消旧请求或递增 generation；任何 completion 写 state 前检查 `Task.isCancelled == false` 且 generation 仍是最新，禁止旧快照后到覆盖新状态。首次 load 才切全屏 loading；已有 snapshot 的刷新期间保留 content；取消保持原状态且不报错。不得让三个 `onChange` 各自启动无守卫的 fire-and-forget Task。
- 自己拥有 `NavigationStack`。质量 pill：alerts > 0 到 `AlertsView`，否则到 `DataQualityDetailView`；来源 footer 到 `SourcesView`。
- 日汇总只含睡眠/活动/能量，不给它们伪造时间；点击通过 `TodayDestination.trends` 回调。
- 时间线只遍历真实 `timelineEntries`，`ForEach` 使用 entry.id。meal 回调 `.diet`；medication 回调 `.medication`。
- scheduled fallback 在视觉和 accessibility label 中都明确“计划时间 / 动作时刻未记录”。
- 空时间线只写“今天还没有餐食或用药记录”，提供真实“记录餐食 / 查看用药”入口，不写缺餐/漏服。
- 来源 footer 只使用 `sourceCoverage`，不把 meal provenance 混入 raw coverage。
- loading、failed、loaded-empty 明确不同；failed 有 `today-load-error` 与 `today-retry`。
- 按任务书拆小组件；使用 `ScrollView + VStack`、现有 `CardTheme`、系统背景和 SF Symbols；不 `AnyView`，不自绘 icon，不固定卡片高度。
- 完整添加任务书列出的 accessibility identifiers，点击目标至少 44pt，长文案可换行。
- `today-summary-*`、`today-timeline`、`today-source-coverage` 只存在于 loaded content；loading/error 不得复用这些 identifiers，D2 smoke 会用它们证明真实 EnvironmentObject → Loader → loaded 转换。
- `#Preview` 只挂不含 EnvironmentObject、loader task 或 DB 读取的纯值 `TodayScreenContent`（或等价 content seam），至少 loaded、成功空日、loading、failed、accessibility 大字号五个状态；loaded fixture 同时包含 actionTime 与 scheduledFallback 用药行，fallback 的可见文案和 accessibility label 都明确“计划时间 / 动作时刻未记录”。fixtures 仅为明确展示数据，不连接 DB/网络/HealthKit，也不进入 AppEnvironment。Coder 只需证明声明可编译；主架构师随后负责实际 render/截图与 accessibility tree 核对，不能由 build 代替。

参考图里“昨夜”、精确 sleep/activity 时刻、午餐待记录、食品数据库、单一 aggregate source 都是禁止项，不得为了贴图而实现。

## 5. Green 验证

```bash
xcodegen generate
xcodebuild \
  -project HealthManager.xcodeproj \
  -scheme HealthManager \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -resultBundlePath /tmp/healthmanager-stage007d1-coder-unit-20260714-attempt01.xcresult \
  -only-testing:HealthManagerTests/TodayEvidencePresentationTests \
  -only-testing:HealthManagerTests/TodayEvidenceLoaderTests \
  test -quiet

xcodebuild \
  -project HealthManager.xcodeproj \
  -scheme HealthManager \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -resultBundlePath /tmp/healthmanager-stage007d1-coder-build-20260714-attempt01.xcresult \
  build -quiet

xcrun xcresulttool get test-results summary \
  --path /tmp/healthmanager-stage007d1-coder-unit-20260714-attempt01.xcresult
xcrun xcresulttool get build-results \
  --path /tmp/healthmanager-stage007d1-coder-build-20260714-attempt01.xcresult
```

不要声称 preview 已实际渲染；本命令只证明 preview 源码参与 Debug 编译。主架构师会在 D1 验收时使用 preview render 工具逐个导出 loaded/empty/loading/failed/大字号截图。

若 green 或 build 非零，只允许一次针对明确原因的窄修，使用对应 `attempt02` 新路径并保留 attempt01；attempt02 仍失败就停止。

## 6. 静态与范围检查

只对三个候选执行 intent-to-add：

```bash
git add -N \
  UI/Today/TodayEvidencePresentation.swift \
  UI/Today/TodayView.swift \
  Tests/TodayEvidencePresentationTests.swift
git diff --check -- \
  UI/Today/TodayEvidencePresentation.swift \
  UI/Today/TodayView.swift \
  Tests/TodayEvidencePresentationTests.swift
git status --short
git diff --stat -- \
  UI/Today/TodayEvidencePresentation.swift \
  UI/Today/TodayView.swift \
  Tests/TodayEvidencePresentationTests.swift
rg -n 'Row\.fetch|SELECT |INSERT |UPDATE |DELETE |asyncRead|asyncWrite|\.write\s*\{' UI/Today
rg -n '昨夜|午餐.*待记录|漏服|食物数据库|健康评分|86400|86_400' UI/Today Tests/TodayEvidencePresentationTests.swift
rg -n 'AnyView|ForEach\([^\n]*indices|id:\s*\\\.offset' UI/Today
```

合理命中必须逐项解释；不得通过改名规避。

## 7. 最终输出

按顺序报告：

1. precheck 原样输出；
2. 15 条内合同复述；
3. 实际修改文件；
4. red 命令、exit code、失败原因与 xcresult 有效性；
5. green test 总数/失败/跳过和 build error/warning；
6. unit 用例到前八类合同的映射，以及第九类静态扫描结果；
7. preview 状态、accessibility identifiers 与关键交互；
8. 静态检查、`git diff --check`、未执行项与残余风险。

不要修改 docs，不要 commit/tag/push，不要宣布 D1 或 STAGE PASS。
