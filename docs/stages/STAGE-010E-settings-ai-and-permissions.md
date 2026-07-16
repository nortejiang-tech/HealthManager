# STAGE-010E 设置、AI 双通道与权限证据

## 状态

`PASS`

## 目标

在 STAGE-010A～010D 已验收的证据型 UI 上，改造设置、AI 文本 / 图像双通道、兼容接口、Profile 保存和 Apple 健康权限下钻。把数据默认留在本机、何时外发、Keychain、数据库导出和权限可观察边界讲清楚，同时保持所有既有配置与副作用语义。

## 已验证起点

- STAGE-010A～010D：PASS；最近全量自动化 258 / 258。
- `SettingsView` 已有数据库统计 / 导出、HealthKit gate、通知状态、对账阈值和 AI 入口。
- `LLMSettingsView` 已有文本与图像各自的 Base URL / 模型 / Key、provider preset、Profile、连接测试、保存与清除。
- Apple 不提供完整读取授权清单；`authorizationGate` 不能外推成逐类型读取状态。写回授权可由 `authorizationStatus(for:)` 观察，最近读取证据可由本地样本 / 同步结果表达。

## 设计依据

- `docs/adr/ADR-002-evidence-led-functional-ui-language.md`
- `docs/design/2026-07-16-ui-redesign-design-contract.md`
- `18-settings-data-ledger.png`、`19-ai-config.png`、`23-add-ai-provider-structure-only.png`、`25-apple-health-permission-scope.png`

参考图规定层级与边界，不是配置 fixture。不得把示例 provider、模型、授权结果、样本数或时间写成真实状态。

## 允许修改

- `UI/Settings/SettingsView.swift`
- `UI/Settings/LLMSettingsView.swift`
- `UI/DesignSystem/HMDesignSystem.swift`，仅限至少两个本阶段页面立即复用的轻量补充；
- 与本阶段直接相关的 test-only UI 审计、测试和文档。

## 禁止修改

- `Core/`、`LLMConfig`、`LLMClient`、Keychain、HealthKit manager / catalog、数据库 schema / query contract、同步 / 对账 / 通知实现；
- STAGE-010A～010D accepted 页面、Dashboard 卡片编辑器和其他 010F+ 页面；
- 保存、应用 / 删除 Profile、preset、Key 记忆、测试连接、导出数据库、通知授权、对账阈值或 onboarding 重置的调用关系；
- 新云服务、新 provider 合同、OAuth、云同步、逐类型伪授权百分比、假数据或 production QA 路由；
- commit、tag、push。

## 事实与交互合同

- 默认健康记录与应用数据库在本机；只有用户启用并实际触发 AI 时，日报 / 周报外发本地聚合后的摘要文本，餐食照片分析外发用户主动选择的图片。
- API Key 存储在系统 Keychain，不进入数据库快照或 Profile；添加兼容接口只保存名称、URL 和建议模型，不保存 Key，不自动启用或发送。
- 文本评注与照片分析是两个配置通道；即使总开关共享，也必须分别显示各自 provider / 模型 / Key 状态、输入范围和测试动作，不能把一个通道测试成功冒充另一个成功。
- 测试失败不得覆盖已保存配置；保存 / 取消、Profile 应用 / 删除、自定义接口删除和清除全部配置保持现有行为。
- Apple 健康读取侧只能表达 gate、最近真实样本 / 查询证据和未知；没有样本不等于没有授权。饮食营养写回状态单独显示，并继续按需请求。
- 数据库路径、记录数、导出、对账阈值、通知和版本等既有功能必须全部可达；隐私文案不得再写成与 AI 功能冲突的“绝不外发”。

## 完成标准

- [x] 设置页顶部形成准确的数据去向总账，并按权限 / 数据管理 / AI / 对账 / 技术项分层，既有功能无丢失。
- [x] AI 页面清楚区分文本与图像通道、provider / 模型 / Key、发送内容、测试结果和 Profile 边界。
- [x] 添加接口与保存 Profile 的“不会保存 Key / 不自动启用或发送”边界可见，保存 / 取消路径保持。
- [x] Apple 健康权限下钻不伪造读取清单；最近数据证据、读取未知和饮食写回授权分开。
- [x] light、dark、accessibility-large 无关键裁切、水平溢出或不可达动作；颜色均有图标 / 文字。
- [x] reference / runtime 组合对照、定向测试、全量测试与 `git diff --check` 通过。

## 验证矩阵

1. 构建：iPhone 17 / iOS 26.5 Simulator，独立 DerivedData。
2. 定向单元：`LLMConfigTests`（若存在）、`MealNutritionAnalyzerTests`、`MealPersistenceCoordinatorTests`、`NotificationScheduleTests`、`SourceAttributionTests`。
3. UI：正式 `SmokeTests` 与设置 / AI 既有 UI 用例；必要时只增加临时 test-only 截图审计，结束前删除。
4. 全量：`HealthManager` scheme 全测试，用 `xcresulttool` 记录真实统计。
5. 视觉：设置、AI、添加接口、Profile 保存、Apple 健康权限下钻的 light；设置 / AI 另覆盖 dark 与 accessibility-large，并制作 reference / runtime 组合图。

## 验证边界

- 不输入或外发真实 API Key，不向真实 AI 服务发送请求。
- Simulator 不证明真实 iPhone 的 HealthKit 逐类型授权、系统通知面板或 Keychain 跨安装行为。
- 不进入 STAGE-010F～010H，不以 Preview 代替 Simulator 运行证据。

## 结果

`PASS` — 2026-07-16 由主架构师独立验收。

- 实现保持在 `SettingsView` / `LLMSettingsView` 与既有共享视觉组件边界内；没有修改 `Core/`、配置存储、网络、Keychain、HealthKit manager、schema、通知或对账合同。
- 设置页建立“本机记录 → 本地数据库 → 可选外部 AI”的数据去向总账；AI 页分别表达摘要文本与用户主动选择照片的输入、provider / 模型 / Key 状态和测试边界。
- 新增 Apple 健康权限证据下钻：读取侧只显示本地最近实际导入样本和未知边界，写入侧单独显示至少一个营养类型的可观察授权；没有样本不被解释为没有权限。
- 添加兼容接口只保存接口结构；Profile 预览明确不含 Key。真实 UI 流程发现 Profile sheet 挂在滚动 Section 上时无法稳定呈现，已把 sheet 移到页面根节点并复验通过。
- 构建：`/tmp/healthmanager-stage010e-architect-build-20260716-attempt03`，BUILD SUCCEEDED。
- 定向：77 / 77；`/tmp/healthmanager-stage010e-architect-targeted-20260716-attempt01.xcresult`。
- 全量：258 / 258；`/tmp/healthmanager-stage010e-architect-full-20260716-attempt01.xcresult`。
- 视觉：light 6 张、dark 4 张、accessibility-extra-large 4 张，分别位于 `/tmp/healthmanager-stage010e-acceptance-20260716/`；设置、AI、添加接口、权限 4 张 reference / runtime 组合图已逐张复核。
- 没有输入真实 API Key、没有向 AI 服务发送请求、没有伪造 provider / 授权 / HealthKit 样本。Simulator 证据不外推真实 iPhone 的逐类型授权或 Keychain 跨安装行为。
- `git diff --check`：PASS；临时视觉审计 test 已删除并重新生成工程；未 commit、tag 或 push。
