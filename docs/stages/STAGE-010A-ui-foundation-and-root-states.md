# STAGE-010A：证据型 UI 基础与根状态

> 状态：PASS（2026-07-16，主架构师验收）
>
> 执行者：Coder；主架构师独立验收
>
> 依赖：ADR-002 Accepted；全页面设计合同 PASS

## 1. 唯一目标

建立本轮改版真正会被使用的轻量设计 token 与共享状态组件，并只改造四个低业务风险表面：

1. 首次连接 Apple 健康；
2. Apple 健康不可用；
3. Today 首次加载；
4. Today 加载失败。

本阶段不改 Today loaded 内容、不改五个一级页面、不改数据合同，也不进入饮食、用药、趋势、同步或 AI 页面。

## 2. 起点与必须先读

预期代码起点：`main` @ `3e657fa`。

必须先读：

- `docs/adr/ADR-002-evidence-led-functional-ui-language.md`
- `docs/design/2026-07-16-ui-redesign-design-contract.md`
- `docs/design/assets/ui-redesign-2026-07-16/README.md`
- `docs/design/assets/ui-redesign-2026-07-16/20-onboarding.png`
- `docs/design/assets/ui-redesign-2026-07-16/21-health-unavailable.png`
- `docs/design/assets/ui-redesign-2026-07-16/28-today-loading.png`
- `docs/stages/STAGE-010A-architect-acceptance-protocol.md`
- `UI/Dashboard/Cards/CardTheme.swift`
- `UI/Onboarding/OnboardingView.swift`
- `UI/Today/TodayView.swift`
- `App/RootView.swift`

工作区会存在主架构师生成的未跟踪 `docs/adr/ADR-002...`、`docs/design/...`、本任务书、Coder 提示词和 handoff。它们是本阶段输入，不得删除、覆盖或顺手改写。

## 3. 允许修改

- 新增 `UI/DesignSystem/` 下最少量的 token / 组件文件；
- `UI/Onboarding/OnboardingView.swift`；
- `UI/Today/TodayView.swift`，只允许改 `TodayLoadingView`、`TodayFailureView` 和为它们服务的纯视觉小组件 / preview；
- `App/RootView.swift`，只允许改 `.denied` 对应 View 的命名、文案和视觉；
- `Tests/` 中与新增纯值语义映射直接相关的最小测试；
- `project.yml` 与 `HealthManager.xcodeproj/project.pbxproj`，仅限 XcodeGen 纳入新增源文件产生的机械变化。

## 4. 禁止修改

- `Core/`、数据库、migration、HealthKit 请求、同步、通知、LLM、餐食或用药逻辑；
- `TodayEvidenceLoader`、`TodayEvidencePresentation` loaded 映射和 Today 交互目的地；
- 五栏导航、任何一级页面 loaded 内容；
- Info.plist、entitlements、版本号、Bundle ID、签名配置；
- 新全局 router、repository、ViewModel、依赖注入协议或第三方 UI 包；
- 运行时 debug 数据源、数据库 seeder、为了截图新增的生产入口；
- 本阶段以外的“顺手统一样式”。

## 5. 设计约束

### 5.1 Token 层

- 新语义层只表达 `comparison / confirmed / actionRequired / estimate / neutral`；
- `CardTheme` 保持指标家族职责，不删除、不重定义、不批量迁移；
- token 支持 light / dark 动态颜色；不得强制浅色；
- 普通正文对比度达到 4.5:1；颜色不得成为唯一状态信号；
- 排版从 Dynamic Type 文本样式派生，不引入自定义字体；
- 只抽取本阶段四个表面立即使用的间距、圆角和组件，不建立空泛组件库。

### 5.2 首次授权

- 主标题“把 Apple 健康作为数据入口”；
- 明确本 App 只连接 Apple 健康，不直接登录第三方账户；
- 分开说明“读取”和“按需写回饮食营养”；
- 明确此步骤不调用外部 AI，授权可在系统设置修改；
- 主动作继续调用现有 View 内的 `requestAuth()`；该方法仍调用 `healthKit.requestAuthorization()`，不得改变请求类型、成功条件或错误处理；
- “我已授权，重新检测”仍调用现有 refresh seam；
- `isRequesting`、错误和禁用状态保持真实。

### 5.3 Apple 健康不可用

- 当前 `.denied` 实际只在 `HKHealthStore.isHealthDataAvailable() == false` 时进入，因此标题改为“Apple 健康暂不可用”或等价事实；
- 不写“你拒绝了权限”，不提供无法证明可达的精确隐私设置深链；
- 显示“重新检测”并继续调用现有 `refreshAuthorizationGate()`；
- 说明本地记录不会被清除，自动同步暂停；
- 可以把 `AuthorizationDeniedView` 重命名为更准确的名字，但只在 `RootView` 内做最小接线。

### 5.4 Today 加载 / 失败

- loading 使用中性骨架保留最终页面节奏；不显示值、来源、缺失或语义色；
- 显示“正在读取本机证据”或等价文案，不暗示云端 / AI；
- failure 显示真实 message、重试和折叠 / 可复制技术信息；不得显示成功空日；
- 保留 `today-screen`、`today-load-error`、`today-retry` 等既有 accessibility identifier；
- 不改变 reload、取消、generation 或 state machine 逻辑；
- Reduce Motion 下骨架不 shimmer；默认 loading 不应是只有一个居中 spinner 的空屏。

## 6. 预计完成标准

1. 新增设计 token / 共享组件已被至少两个本阶段页面真实使用，无死代码和重复主题系统。
2. `CardTheme` 行为和所有指标家族颜色保持不变。
3. Onboarding 的读取 / 写回 / 第三方路径 / AI 边界与真实 HealthKit 请求一致。
4. HealthKit 不可用页不再错误归因于用户拒绝，重试仍有效。
5. Today loading 无虚假值；Today failure 保留真实错误、重试和既有 identifier。
6. 默认字号与 accessibility-large 下无关键裁切；VoiceOver 有完整标题、状态和动作语义。
7. light / dark 均可读；Reduce Motion 无持续 shimmer。
8. 没有 `Core/`、schema、同步、LLM、通知或业务数据 diff。
9. XcodeGen、构建、全量 unit / UI tests 全部实际通过；失败必须停止并报告。
10. Coder 不提交、不 tag、不 push，不宣布视觉 PASS。
11. Onboarding、Apple 健康不可用、Today loading / failure 均有不触发真实业务副作用的纯展示 Preview；至少覆盖默认、dark 和 accessibility-large，供主架构师独立渲染验收。

## 7. 验证边界

- Coder 证明代码、构建、测试和可访问性基础，不负责最终视觉 PASS；
- 本阶段不证明真实 HealthKit 数据、真实权限选择或真机行为；
- 不用生产数据库 fixture 截图，不改用户或既有 Simulator 数据；
- Today loaded、五栏主页面和后续详情页视觉保持 NOT STARTED。

## 8. 正式结果

STAGE-010A 主架构师结论：`PASS`。

- 实现基线：`main` @ `3e657fa`；未创建提交、tag 或 push。
- 范围：新增 `UI/DesignSystem/HMDesignSystem.swift`；改造 Onboarding、HealthKit 不可用、Today loading / failure；没有 `Core/`、schema、同步、LLM、通知、HealthKit 请求或 Today loaded diff。
- 设计基础：语义 tone 为 comparison / confirmed / actionRequired / estimate / neutral；动态 light / dark token 被四个表面复用；`CardTheme` 未修改；未使用组件和 token 已在验收轮删除。
- 事实边界：Onboarding 保留真实 request / refresh seam；`.denied` 改为“设备不可用”事实；Today reload / cancellation / generation / loaded mapping 未修改；错误保留真实 message、技术信息和重试。
- 视觉证据：同一 disposable iPhone 17 / iOS 26.5 / portrait / zh-Hans / zh_CN，四个表面各有 light-large、dark-large、light-accessibility-large，共 12 张；参考与实现同屏对照 3 张。
- 视觉目录：`/tmp/healthmanager-stage010a-acceptance-20260716/screenshots/`。
- 对照目录：`/tmp/healthmanager-stage010a-acceptance-20260716/comparisons/`。
- Simulator：`HealthManager-STAGE010A-QA-20260716`，UDID `2E27DE90-4B5E-4956-88C4-B039843CCE8F`，Runtime build `23F77`。
- 最终测试命令：`xcodebuild -project HealthManager.xcodeproj -scheme HealthManager -destination 'platform=iOS Simulator,id=2E27DE90-4B5E-4956-88C4-B039843CCE8F' -derivedDataPath /tmp/healthmanager-stage010a-architect-final-dd-attempt01 -resultBundlePath /tmp/healthmanager-stage010a-architect-final-20260716-attempt01.xcresult test`。
- 最终测试：258 / 258 passed，0 failed，0 skipped；其中 unit 251、UI 7。
- 构建结果：succeeded，0 error，1 个既有 warning（`Tests/MealItemMigrationTests.swift:15` 的未变 `migrator`）。
- 结果包：`/tmp/healthmanager-stage010a-architect-final-20260716-attempt01.xcresult`。
- 设计 QA：仓库根 `design-qa.md` 的 STAGE-010A 节为 `passed`。

边界：本结果不证明 Today loaded、五个一级页面、真实 iPhone HealthKit 或 STAGE-010B～010F；这些继续按阶段验收。
