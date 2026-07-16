# 给 Coder：执行 STAGE-010A（只做这一阶段）

你正在 `/Users/nortepro/HealthManager` 的共享工作区工作。主会话是架构师和最终验收者；你只实现当前 STAGE，不提交 Git，不扩大范围。

## 目标

建立本轮 UI 改版立即会使用的轻量设计 token / 状态组件，并只改造：

- 首次连接 Apple 健康；
- Apple 健康不可用；
- Today 首次 loading；
- Today load failure。

不要改 Today loaded、五栏主页面、餐食、用药、趋势、同步、设置或 AI 页面。

## 第 0 步：先检查，不要直接写代码

执行并报告：

```bash
cd /Users/nortepro/HealthManager
git status --short --branch
git rev-parse --short HEAD
xcodebuild -version
xcrun simctl list devices available | rg 'iPhone 17|iOS 26.5'
```

预期代码基线是 `main` @ `3e657fa`。工作区存在主架构师新建的未跟踪设计 docs 和 PNG，这是预期输入；不要删除、覆盖或加入你的实现范围。若看到除这些设计文档以外的未知代码改动，立即停止并报告。

## 必须完整阅读

```text
docs/adr/ADR-002-evidence-led-functional-ui-language.md
docs/design/2026-07-16-ui-redesign-design-contract.md
docs/design/assets/ui-redesign-2026-07-16/README.md
docs/design/assets/ui-redesign-2026-07-16/20-onboarding.png
docs/design/assets/ui-redesign-2026-07-16/21-health-unavailable.png
docs/design/assets/ui-redesign-2026-07-16/28-today-loading.png
docs/stages/STAGE-010A-ui-foundation-and-root-states.md
docs/stages/STAGE-010A-architect-acceptance-protocol.md
UI/Dashboard/Cards/CardTheme.swift
UI/Onboarding/OnboardingView.swift
UI/Today/TodayView.swift
App/RootView.swift
project.yml
```

图片必须实际打开检查，不能只读文件名。图片与书面合同冲突时，按“代码 / 数据合同 → 设计合同 → ADR → 图片”处理。

## 允许修改

```text
UI/DesignSystem/**                      # 新增，必须是本阶段实际使用的最小集合
UI/Onboarding/OnboardingView.swift
UI/Today/TodayView.swift                # 只限 TodayLoadingView / TodayFailureView 与其纯视觉 helper / previews
App/RootView.swift                      # 只限 .denied 对应 View 的准确命名、文案和视觉
Tests/**                                # 只限新增纯值语义映射确有必要的最小测试
project.yml
HealthManager.xcodeproj/project.pbxproj # 仅 XcodeGen 机械变化
```

任何其他文件都禁止修改。需要越界时先停下，不要自行批准。

## 实现要求

### A. 设计 token

1. 建立一个轻量语义层，至少覆盖：
   - `comparison`：钴蓝，已观测比较 / 选中时点；
   - `confirmed`：青绿，本地事实 / 查询成功 / 已保存；
   - `actionRequired`：珊瑚，缺失 / 失败 / 需要处理；
   - `estimate`：柔紫，AI / 手工估算 / 外部可选能力；
   - `neutral`：加载和未知前的中性状态。
2. 提供 light / dark 动态颜色，不强制浅色。
3. 普通正文颜色对比度至少 4.5:1；`#FF6A2A` 只能做小面积强调，不直接承载小号白字。可使用设计合同建议值。
4. 系统字体 + Dynamic Type；不要引入字体或第三方 UI 包。
5. 保留 `CardTheme` 的指标家族职责，不改它的公开合同，不批量迁移现有卡片。
6. 只实现本阶段四个表面会重复使用的组件，例如 editorial header、语义状态标签、inline recovery、neutral skeleton。不要为了“设计系统完整”造未使用组件。

### B. Onboarding

按 `20-onboarding.png` 的层级实现，但必须遵守书面事实：

- 标题“把 Apple 健康作为数据入口”；
- “HealthManager 只连接 Apple 健康，不直接登录 Garmin、小米或其他第三方账户”；
- 数据路径：手表 / 健康 App → Apple 健康 → HealthManager 本机数据库；
- 分开列出“读取”和“按需写回饮食营养”；
- 显示“此步骤不会调用外部 AI；授权范围可随时在系统设置中修改”；
- 主按钮仍调用现有 `requestAuth()`，不得改变权限集合、成功条件或错误处理；
- “我已授权，重新检测”仍调用现有 `refreshAuthorizationGate()`；
- loading、disabled、localError 全部真实可见且可访问。
- 提供可编译的纯展示 Preview，至少覆盖默认、dark 和 accessibility-large。若拆分 content / shell，production shell 必须继续持有 `EnvironmentObject`、`isRequesting`、`localError` 和异步动作；Preview 不得触发真实授权。

### C. HealthKit 不可用

- 把当前误导性的“健康权限被拒绝”改为“Apple 健康暂不可用”或等价事实；
- 解释“当前设备没有提供可用的 Apple 健康接口，因此无法读取或同步”；
- 不写用户拒绝，不添加假的精确设置深链；
- “重新检测”继续调用 `refreshAuthorizationGate()`；
- 明确本地数据不会清除；自动同步暂停；
- 可以把 View 重命名，但不改 `AuthorizationGate` enum 和任何 HealthKit 判断。
- 提供可编译的纯展示 Preview，至少覆盖默认、dark 和 accessibility-large；不得为预览增加生产假权限 seam。

### D. Today loading / failure

- loading 使用中性骨架，保留 Today 的标题、日期、主曲线 / 透镜 / 时间线布局节奏；
- 不显示任何数值、来源、缺失或语义色；文案说明“正在读取本机证据”；
- Reduce Motion 时没有 shimmer；
- failure 使用共享 recovery 语言，显示真实 `message`、重试和可复制 / 折叠技术信息；
- 保留以下 identifier：`today-screen`、`today-load-error`、`today-retry`；
- 不修改 state、reload、cancellation、generation 或 loaded 映射；
- 不新增运行时 debug 数据 seam 或数据库 fixture。
- 保留并更新现有 `Loading` / `Failed` Preview；为这两个状态各补一个 accessibility-large 预览，dark 可用同一纯展示入口渲染；Preview 不得连接数据库、HealthKit 或 loader。

## 代码质量要求

- 新组件有清晰输入，不读取数据库、不持有业务状态；
- 避免 giant View body，也避免一个控件一个文件的碎片化；
- 不用字符串判断业务状态；
- 颜色之外必须有图标和文字；
- 点击区至少 44 pt；图标按钮有 accessibility label；
- accessibility-large 下可滚动，不使用固定高度裁切大标题 / 说明；
- 不把设计图中的硬编码日期或数值带入生产状态。

## 验证顺序

若新增 Swift 文件，先更新工程；然后直接运行全量 `test`，它同时完成构建与 unit / UI tests。任何一步失败就停止，先判断是实现失败还是环境 / 工具失败，不要在失败后继续写 PASS。

1. 若新增 Swift 文件，运行：

```bash
xcodegen generate
```

只接受新增文件纳入工程产生的机械 project diff。

2. 全量测试：

```bash
xcodebuild \
  -project HealthManager.xcodeproj \
  -scheme HealthManager \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  test
```

3. 记录：

- 最终 exit code；
- unit / UI 的实际 executed / passed / failed / skipped 数量；
- xcresult 绝对路径；
- build warning / error 数量；
- `git status --short`；
- `git diff --stat` 与逐文件改动摘要。

4. 编译并报告以下纯展示 Preview 是否存在且可渲染：Onboarding、HealthKit 不可用、Today loading、Today failure；每个至少有默认、dark 和 accessibility-large 入口。能在不添加生产调试入口、不写入用户数据库的前提下取得截图时，放到 `/tmp/healthmanager-stage010a-ui/` 并记录设备 / OS / appearance / content size。截图不是 Coder 的 PASS 权限；主架构师会按 acceptance protocol 独立渲染和对照。不能稳定渲染时写 INCOMPLETE，不要伪造截图或扩大代码范围。

## 停止条件

出现任一情况立即停止并报告：

- 需要修改 `Core/`、schema、HealthKit 请求或同步逻辑；
- 需要改 Today loaded 或其他页面才能“完成设计系统”；
- 发现用户 / 架构师的未知代码改动；
- 全量测试失败且原因不是已确认的环境问题；
- 为视觉验证需要新增生产 seeder、debug DB 或假权限状态；
- XcodeGen 产生与新增源文件无关的大范围 project diff。

## 最终输出格式

```text
STAGE-010A Coder 结果：DONE / BLOCKED

改动：
- <逐文件>

验证：
- <命令>
- exit code
- executed / passed / failed / skipped
- xcresult
- warnings / errors

视觉 / 无障碍：
- <实际验证>
- <未验证项必须标 INCOMPLETE>

边界：
- 未修改 Core / schema / HealthKit / sync / LLM / 业务数据
- 未提交 / 未 tag / 未 push

git status：
<原样粘贴>
```

不要写“整体视觉 PASS”；主架构师会直接检查共享工作区并独立验收。
