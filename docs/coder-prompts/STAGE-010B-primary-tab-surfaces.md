# 给内部 Coder：只实现 STAGE-010B

你在共享工作区 `/Users/nortepro/HealthManager` 中工作。主会话是架构师与最终验收者。当前工作区故意包含未提交但已由主架构师验收 PASS 的 STAGE-010A Swift / docs diff；必须在其上增量实现，不能删除、覆盖或回退。

## 唯一任务

严格实现：

```text
docs/stages/STAGE-010B-primary-tab-surfaces.md
```

把 Today、Diet、Medication、Dashboard、More 五个一级页面改造成已批准的“基线叙事 + 局部决策透镜”界面；不进入编辑器、详情页或业务逻辑。

## 开工前必须完整阅读

```text
docs/adr/ADR-002-evidence-led-functional-ui-language.md
docs/design/2026-07-16-ui-redesign-design-contract.md
docs/stages/STAGE-010A-ui-foundation-and-root-states.md
docs/stages/STAGE-010B-primary-tab-surfaces.md
UI/DesignSystem/HMDesignSystem.swift
UI/Dashboard/Cards/CardTheme.swift
UI/Today/TodayView.swift
UI/Diet/DietView.swift
UI/Medication/MedicationView.swift
UI/Dashboard/DashboardView.swift
UI/More/MoreView.swift
App/RootView.swift
```

并实际查看 010B 任务书列出的 6 张 PNG。视觉参考服从真实代码与设计合同；不得照抄错误事实。

## 硬边界

- 不修改 `Core/`、schema、query、loader、snapshot、同步、通知调度、LLM、持久化、HealthKit、Info.plist、entitlements。
- 不修改 `MealEditView`、`MedicationPlanEditView`、MealReuse、详情页、Settings 或 AI 页面。
- 不改变 Today reload / cancellation / generation / state machine；010A loading / failure 已验收，不得重写。
- 不改变五栏顺序、名称、目的地、sheet / push 行为和既有 accessibility identifier。
- 不新增运行时 debug router、fixture、seeder、假数据源、第三方 UI 包、自绘 TabBar、新 ViewModel / repository。
- 不提交、不 tag、不 push；不使用 reset / checkout / clean。

## 实现纪律

1. 先列出你将触碰的 struct / 文件和为什么在范围内，再编辑。
2. 复用 010A 的 token / component；新增共享组件必须至少有两个真实使用点。
3. 现有 closures、Task、refresh、delete、recordTaken、route 和 identifiers 原样接回；只改 UI 组合。
4. 未知显示 `—` 与原因；空白、加载、失败分开；不制造健康结论或任务。
5. 五页主动作各不超过一个；次动作权重明确降低；所有可见控件可实际工作。
6. 只用 SF Symbols / 现有真实资产；不手绘 SVG / ASCII / 占位图。
7. 提供默认、dark、accessibility-large 的纯展示 Preview；Preview 不得触发真实写入。

## 验证

使用从未存在的新路径：

```bash
xcodegen generate
xcodebuild \
  -project HealthManager.xcodeproj \
  -scheme HealthManager \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -derivedDataPath /tmp/healthmanager-stage010b-coder-build-20260716 \
  build

xcodebuild \
  -project HealthManager.xcodeproj \
  -scheme HealthManager \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -resultBundlePath /tmp/healthmanager-stage010b-coder-final-20260716-attempt01.xcresult \
  test
```

若路径已存在，改用下一个 attempt；不得覆盖旧结果。随后用 `xcresulttool` 读取 test summary 与 build results。

## 最终输出

只报告真实事实：

- 修改文件与各自作用；
- 五页如何保持原数据 / 动作 / identifier；
- `git diff --check`；
- build exit code；
- test executed / passed / failed / skipped、warning / error、xcresult；
- 哪些 dark / Dynamic Type / 视觉项仅提供 Preview、仍待主架构师独立验收；
- 明确没有 commit / tag / push。

不要自行宣布 STAGE-010B PASS；完成代码与自动化后停下，等待主架构师验收。
