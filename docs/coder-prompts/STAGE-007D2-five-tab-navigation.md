# 给 Coder 的提示词：STAGE-007D2 五栏导航与 More

你是实现 Coder。只执行 HealthManager STAGE-007D2，直接修改共享工作区；不要改 Today D1、业务算法、数据库或文档，不要读取任何 memory 文件。

## 0. 固定起点与停止条件

工作目录：/Users/nortepro/HealthManager

先执行并原样报告：

    git status --short --untracked-files=all
    git branch --show-current
    git rev-parse HEAD
    git check-ignore -v HealthManager.xcodeproj/project.pbxproj

预期：

- 分支：codex/health-planning-20260713
- HEAD：a76d9580b2466843bd283e0ba10c8823439a6ce4
- 以下文件是主架构师已经验收或拥有的 untracked 文件，必须保留且不得修改：
  - Tests/TodayEvidencePresentationTests.swift
  - UI/Today/TodayEvidencePresentation.swift
  - UI/Today/TodayView.swift
  - docs/stages/STAGE-007D-today-timeline-and-five-tab-navigation.md
  - docs/coder-prompts/STAGE-007D1-today-screen.md
  - docs/coder-prompts/STAGE-007D2-five-tab-navigation.md
- HealthManager.xcodeproj 被 ignore。

任一不符立即停止，只报告实际状态；不得 reset、checkout、clean、stash、删除或覆盖现有改动。

## 1. 只读材料

完整阅读：

1. docs/stages/STAGE-007D-today-timeline-and-five-tab-navigation.md
2. UI/Today/TodayView.swift
3. App/RootView.swift
4. UI/SyncCenter/SyncCenterView.swift
5. UITests/SmokeTests.swift
6. UI/Sources/SourcesView.swift
7. UI/Dashboard/DashboardView.swift
8. UI/Summary/SummaryView.swift
9. UI/Workouts/WorkoutsView.swift
10. UI/Settings/SettingsView.swift

不要广泛扫描仓库；遇到具体符号再用 rg 定位。

## 2. 唯一允许修改的文件

    App/RootView.swift
    UI/More/MoreView.swift
    UI/SyncCenter/SyncCenterView.swift
    UITests/SmokeTests.swift

禁止修改其他文件，包括 D1 三文件和所有 docs。禁止 commit、tag、push。

## 3. 必须先得到真实 red

先只修改 UITests/SmokeTests.swift，把下面第 6 节的真实验收写入 smoke；此时不要创建 More、不要改 Root/SyncCenter。

生成项目并运行：

    xcodegen generate
    xcodebuild test \
      -project HealthManager.xcodeproj \
      -scheme HealthManager \
      -destination 'platform=iOS Simulator,id=6364DCEB-82DF-448C-91D9-2C19FD844AA8' \
      -only-testing:HealthManagerUITests/SmokeTests/test_tabsAndCommonFlows_rendered \
      -resultBundlePath /tmp/healthmanager-stage007d2-coder-red-20260714-attempt01.xcresult

合格 red 必须是旧 Root 仍显示“仪表盘 / 来源 / 同步中心”、缺少 Today/More 所导致的 UI 断言失败；测试文件自身不能有编译错误。若测试代码写错，先修测试并换一个全新 attempt 路径重跑，直到得到产品行为 red。保留并报告 xcresult 路径和失败断言。

没有合格 red，不得写生产实现。

## 4. 五栏接线

在 App/RootView.swift：

- 新增稳定 MainTab: Hashable，仅含 today、diet、medication、trends、more。
- MainTabView 用 @State selection 与 TabView(selection:)。
- 五栏顺序、标签、SF Symbol、根内容必须严格为：

| tag | 标签 | systemImage | 根内容 |
|---|---|---|---|
| today | 今日 | calendar | TodayView |
| diet | 饮食 | fork.knife | DietView |
| medication | 用药 | pills | MedicationView |
| trends | 趋势 | chart.bar.fill | DashboardView |
| more | 更多 | ellipsis | MoreView |

- TodayView.onSelectDestination 映射：
  - diet → 选中 diet
  - medication → 选中 medication
  - trends → 选中 trends
- 不新增 router、共享 NavigationPath、ViewModel 或自绘 tab bar。
- 不删除 DashboardView；它只是从旧“仪表盘”改挂到“趋势”。

## 5. More 与 SyncCenter

新增 UI/More/MoreView.swift：

- 自己拥有 NavigationStack + List；
- navigationTitle 为“更多”；
- 使用现有 CardTheme 或系统语义色与 SF Symbols，不创建图片、SVG 或 emoji；
- 不复制目标页内容，只用 NavigationLink；
- 至少完整提供：

| Section | 入口 | destination |
|---|---|---|
| 数据与同步 | 数据来源 | SourcesView() |
| 数据与同步 | 同步中心 | SyncCenterView() |
| 数据与同步 | 数据质量 | DataQualityDetailView() |
| 数据与同步 | 告警 | AlertsView() |
| 分析与记录 | 日报 / 周报 | SummaryView() |
| 分析与记录 | 运动记录 | WorkoutsView() |
| 应用 | 设置 | SettingsView() |

加入稳定 identifier：

- List/root：more-screen
- 数据来源 link：more-sources
- 同步中心 link：more-sync-center
- 数据质量 link：more-data-quality
- 告警 link：more-alerts
- 日报/周报 link：more-summary
- 运动记录 link：more-workouts
- 设置 link：more-settings

在 UI/SyncCenter/SyncCenterView.swift：

- 只移除最外层自带的 NavigationStack，让 List 成为 body 根内容，以便嵌入 More；
- 保留原有所有 section、任务、refresh、alert、标题与设置 toolbar；
- 不改同步行为、数据库读取或文案语义。

## 6. 必须通过的真实 UI smoke

更新 SmokeTests.test_tabsAndCommonFlows_rendered，不要新增 seed、SQLite 旁路、网络或 test-only 产品入口：

1. 用 -HM_DEBUG_BYPASS_ONBOARDING 启动。
2. 先等 today-screen。
3. 再分别等待 loaded-only identifier：
   - today-summary-sleep
   - today-timeline
   - today-source-coverage
4. loaded 后断言 today-load-error 不存在；若不存在任何 today-timeline-* 行，则必须断言“今天还没有餐食或用药记录”存在。
5. 保存 Today screenshot attachment。
6. 断言五个 tab 标签“今日 / 饮食 / 用药 / 趋势 / 更多”全部存在；旧一级 tab“仪表盘 / 来源 / 同步中心”不存在。
7. “饮食” tab 与原添加餐次/取消 smoke 继续通过。
8. “用药” tab 与原添加用药计划/取消 smoke 继续通过。
9. “趋势” tab 可进入现有 DashboardView，导航标题“摘要”存在。
10. “更多” tab 显示 more-screen，保存 More screenshot。
11. 从 More 依次进入并返回：
    - more-sources → 导航标题“数据来源”
    - more-sync-center → 导航标题“同步中心”
    - more-settings → 导航标题“设置”
12. 每个入口必须断言真实 destination 后再返回，不得用可选 if exists 把缺失能力静默跳过。

identifier 查询使用 app.descendants(matching: .any).matching(identifier: ...).firstMatch 或等价通用查询，因为 loaded section 可能是 container，不要假定全是 button。

保留 screenshot helper。测试必须确定性等待，不用固定 sleep，不降低原断言。

## 7. Green 与交付

实现后先执行：

    git diff --check
    git status --short --untracked-files=all
    rg -n 'TabView|tabItem|tag|NavigationStack|more-' \
      App/RootView.swift UI/More/MoreView.swift UI/SyncCenter/SyncCenterView.swift UITests/SmokeTests.swift
    xcodegen generate
    xcodebuild test \
      -project HealthManager.xcodeproj \
      -scheme HealthManager \
      -destination 'platform=iOS Simulator,id=6364DCEB-82DF-448C-91D9-2C19FD844AA8' \
      -only-testing:HealthManagerUITests/SmokeTests/test_tabsAndCommonFlows_rendered \
      -resultBundlePath /tmp/healthmanager-stage007d2-coder-green-20260714-attempt01.xcresult

若 green 失败，只做有证据的有界修复，并为每次重跑换全新 resultBundlePath；不得删除旧结果。

最终只报告：

- 起点检查；
- red 路径、失败原因；
- 实际修改文件；
- 关键实现映射；
- green 路径与测试计数；
- git diff --check；
- 最终 git status --short --untracked-files=all；
- 未执行项。

不要宣称 D2 或视觉 QA PASS；主架构师负责验收。
