# STAGE-010G 全量无障碍、深色与视觉回归

## 状态

`PASS`

## 目标

在 STAGE-010A～010F 页面与交互全部就位后，用固定 Simulator 矩阵验证全 App 的 Dynamic Type、深色、Reduce Motion、关键可访问性标签与真实 UI 流程。只修复运行证据捕获的纯视图 / 可访问性问题，不再做风格扩写或业务改造。

## 已验证起点

- STAGE-010A～010F：PASS；最近全量自动化 258 / 258。
- 各阶段已有 light / dark / accessibility 证据和 reference / runtime 同屏对照；本阶段建立跨页固定矩阵，不替代既有页面级证据。
- 010E accessibility-extra-large 已观察到长 `HMEvidenceTag` 使用胶囊时两端弧度过大、占用视觉面积；010F 已观察并修复动态图标越界。
- 关键流程已由永久 `SmokeTests` 覆盖，010F 新增的卡片编辑流程会在结束前恢复默认布局。

## 允许修改

- `UI/DesignSystem/HMDesignSystem.swift`
- 固定运行矩阵真实捕获问题的具体 `UI/` 文件，只限布局、自适应、颜色、accessibility label / hint / value、Reduce Motion 表达；
- 与本阶段直接相关的 test-only UI 审计、测试和文档。

## 禁止修改

- `Core/`、任何 store / loader / manager、数据库、schema、HealthKit、同步、通知、LLM、计算或持久化合同；
- 导航目的地、保存 / 删除 / 同步 / 请求授权等副作用调用关系；
- 新页面、新功能、假数据、production QA 路由、装饰性动画或视觉风格重做；
- 为通过视觉测试隐藏文字、缩小到不可读、固定页面高度或降低 Dynamic Type；
- commit、tag、push。

## 固定验收矩阵

1. iPhone 17 / iOS 26.5 / zh-Hans / portrait / 09:41。
2. light-large：复用 010A～010F accepted evidence，并在正式 diff 上执行永久 Smoke。
3. dark-large：Today、Diet、餐食编辑、Medication、用药编辑、Trends、卡片编辑、More 的永久 Smoke；另覆盖 Settings / AI / 权限 / 同步等高密度页。
4. light-accessibility-extra-large：编辑器、设置、AI、权限、同步、来源和至少一个指标详情；必须证明顶部、关键动作与底部均可滚动到达。
5. Reduce Motion：打开系统 Reduce Motion 后运行代表性 Smoke / 审计，确认没有必须依赖动画才能理解或到达的内容。
6. 可访问性：关键图标动作有 label；颜色均配图标 / 文字；图表和证据链保留可读摘要；临时 audit 可使用 accessibility tree / 系统 audit，但不得用隐藏问题的例外清单换 PASS。

## 完成标准

- [x] accessibility-extra-large 长状态标签不再形成夸张胶囊或挤压正文；正文仍按系统字体放大。
- [x] 带 trailing 状态 / 时间的共享信息行在 accessibility size 不互相挤压或重叠。
- [x] dark 固定矩阵无强制浅色、低对比度正文、丢失分隔或颜色唯一表达。
- [x] Reduce Motion 下无持续 shimmer / 漂浮 / 必须动画；关键流程仍可完成。
- [x] 固定截图矩阵与真实 UI 流程通过；发现的问题均有前后证据，不做无证据美化。
- [x] 定向、全量 258 / 258、`git diff --check` 通过；临时 test 删除并重新生成工程。

## 验证边界

- Simulator 截图与 accessibility tree 不等于真实用户的完整 VoiceOver 操作体验；不得外推真机触觉、系统权限面板或第三方 App。
- 系统 TabBar / NavigationBar 在极大字号的外观服从 iOS；只要求内容可滚动到达、动作可点击，不自绘系统壳。
- 不进入 STAGE-010H；不以 Preview 替代运行态。

## 结果

`PASS` — 固定 Simulator 矩阵、永久交互、Reduce Motion、定向与全量回归均通过；只修复了运行证据捕获的纯视图 / 可访问性问题。

### 改动

- `HMEvidenceTag` 在 accessibility size 改用受控圆角与更紧凑内边距；默认字号仍保持既有短状态标签外观。
- `HMInformationRow` 在 accessibility size 把 trailing 状态 / 时间移动到正文下方，避免与长标题横向争抢空间；默认字号仍为同一行。
- Dashboard 卡片显隐动画遵循 `accessibilityReduceMotion`；源码审计没有持续 shimmer、漂浮或 `repeatForever`。

### 视觉与交互证据

- dark 高密度页 8 张、1 / 1：`/tmp/healthmanager-stage010g-visual-dark-20260716-attempt02.xcresult`，导出目录 `/tmp/healthmanager-stage010g-acceptance-20260716/dark/`。
- accessibility-extra-large 高密度页最终 8 张、1 / 1：`/tmp/healthmanager-stage010g-visual-accessibility-20260716-attempt02.xcresult`，导出目录 `/tmp/healthmanager-stage010g-acceptance-20260716/accessibility-final/`。
- dark 永久 Smoke：1 / 1，`/tmp/healthmanager-stage010g-dark-smoke-20260716-attempt01.xcresult`。
- 系统 Reduce Motion 实测值为 `1` 时永久 Smoke 1 / 1：`/tmp/healthmanager-stage010g-reduce-motion-smoke-20260716-attempt01.xcresult`；测试后已恢复为 `0`。
- dark 首轮因 test-only 选择器文案错误未进入产品断言；accessibility 首轮因证据行未进入截图视口而收窄补拍。两项均不是 App failure，也未用例外清单隐藏问题。

### 自动化

- 构建：`/tmp/healthmanager-stage010g-architect-build-20260716-attempt02`，BUILD SUCCEEDED。
- 定向：30 / 30，`/tmp/healthmanager-stage010g-architect-targeted-20260716-attempt01.xcresult`。
- 全量：258 / 258，0 failed，0 skipped，`/tmp/healthmanager-stage010g-architect-full-20260716-attempt01.xcresult`。
- `git diff --check`、`xcodegen generate`：PASS；临时 `Stage010GVisualAuditTests.swift` 已删除。

### 边界

Simulator 与截图不能外推真实 iPhone VoiceOver 操作手感、触觉反馈、系统权限面板或第三方 App；系统 TabBar 在极大字号下保持系统行为，验收只证明内容可滚动到达且永久流程可完成。
