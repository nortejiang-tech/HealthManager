# STAGE-010C 餐食记录、复用、证据与用药计划编辑器

## 状态

`PASS`

## 目标

在 STAGE-010A～010B 已验收的证据型视觉系统上，重组四个高频编辑流程的视觉层级：

1. 餐食新增 / 编辑；
2. 最近餐复用与分项选择；
3. 餐食分项来源证据；
4. 用药计划新增 / 编辑与星期选择。

本阶段只改善信息组织、状态表达、控件可读性和动作层级，不改变任何保存、复制、AI、通知、数据库或 HealthKit 语义。

## 已验证起点

- STAGE-010A：PASS。
- STAGE-010B：PASS；全量自动化 258 / 258。
- 现有编辑器基于原生 `Form` / `List`，已有 UI 自动化依赖固定 accessibility identifier。
- 餐食证据的来源、置信度、人工修订、备餐状态、字段覆盖和未知字段均已有确定性 presentation 合同。
- 最近餐复用已有“整餐复用”和“选择分项”两条真实路径；复用后生成新草稿，不修改原记录。
- 用药计划已有本地提醒授权、星期、时间和覆盖旧提醒的真实语义；计划时间不是服药动作时间。

## 设计依据

- `docs/adr/ADR-002-evidence-led-functional-ui-language.md`
- `docs/design/2026-07-16-ui-redesign-design-contract.md`
- `docs/design/assets/ui-redesign-2026-07-16/06-meal-editor.png`
- `docs/design/assets/ui-redesign-2026-07-16/07-medication-plan-editor.png`
- `docs/design/assets/ui-redesign-2026-07-16/16-meal-reuse.png`
- `docs/design/assets/ui-redesign-2026-07-16/22-meal-item-evidence.png`
- `docs/design/assets/ui-redesign-2026-07-16/29-ai-partial-failure.png`

参考图只规定信息层级、色彩角色和状态组织。若示例文案与真实代码合同冲突，以真实合同为准，不制造示例数据、功能或结论。

## 允许修改

- `UI/Diet/DietView.swift` 中 `MealEditView` 及其纯视觉子视图；
- `UI/Diet/MealReuseView.swift`；
- `UI/Diet/MealItemEvidenceView.swift` 中 View 层；
- `UI/Medication/MedicationView.swift` 中 `MedicationPlanEditView`、`WeekdayPicker` 及其纯视觉子视图；
- `UI/DesignSystem/HMDesignSystem.swift`，仅限至少两个本阶段页面立即复用的轻量组件 / token；
- 与本阶段直接相关的 Preview、测试和文档。

## 禁止修改

- `Core/`、schema、迁移、query、Store、同步、HealthKit、通知调度器、LLM 客户端或解析器；
- 餐食草稿、保存副作用、照片文件生命周期、复用 copy draft 和来源 presentation 的业务语义；
- 用药计划保存与通知重排语义；
- STAGE-010B 的五个一级页面以及 STAGE-010D～010F 的详情 / 设置页面；
- 新的产品能力、假数据、第三方 UI 包、自绘资产或运行时 QA 路由；
- commit、tag、push。

## 交互与事实合同

### 餐食编辑器

- 保留餐次、时间、多图、文字描述、AI 估算、营养分项、保守汇总、备注、取消和保存的真实路径。
- AI 是可选估算，不得写成确认事实；必须保留真实的“发送到已配置服务”边界说明。
- 部分输入失败时，已成功结果继续保留，失败输入可单独重试；技术错误为次级信息，不覆盖可继续手工编辑的主路径。
- 手工汇总和结构化分项汇总的切换语义不变；任一分项字段未知时，相应合计继续显示 `—`。
- 原有 `meal-edit-*` 与 `meal-item-evidence-*` identifier、保存禁用、取消清理、照片增删和加载 / 保存状态必须保持。

### 最近餐复用

- 整餐复用与选择分项必须都可到达、可完成；原餐次不变，目标是新草稿。
- 加载、空白、错误、列表、选择详情分别表达；不得把错误写成空白。
- 保留现有 `meal-reuse-*` identifier 和 UI 测试依赖的文案 / 路由。

### 餐食证据

- 紧凑态说明来源并允许展开；展开态保留来源、引用、版本、置信、修订、备餐、覆盖、未知和 caution。
- 人工修改不把 AI / 数据库 / 标签估算升级为已验证。
- 颜色不得是唯一状态信号；长引用可换行且可选择。
- `MealItemEvidencePresentation` 的事实映射和已测试字符串不得改变。

### 用药计划编辑器

- 计划预览只由当前频率、星期和时间输入确定；不得暗示已经服药。
- 本地通知授权拒绝必须是显式可恢复状态；不虚构设置深链。
- 星期控件至少 44×44 pt 可触达，支持 Dynamic Type、VoiceOver 选中状态和每天 / 工作日 / 周末快捷选择。
- 保存、授权请求、旧提醒替换和本地数据通知行为不变。

## 完成标准

- [x] 四个范围内页面使用统一的语义色、标题、表面和来源表达，且没有装饰性堆砌。
- [x] `Form` / `List` 原生滚动、键盘、Picker、DatePicker、Toggle、Menu、PhotosPicker、sheet / fullScreenCover 行为保持。
- [x] 所有既有 accessibility identifier 仍唯一存在并可到达。
- [x] 餐食 AI 部分成功 / 失败、证据展开、复用选择和用药权限拒绝均有可读状态。
- [x] light、dark、accessibility-large 运行态无固定高度裁切、重叠或不可触达控件。
- [x] 参考图与运行截图在同一张对照图中复核，差异有事实说明。
- [x] 定向单元 / UI 测试与全量测试通过，`git diff --check` 通过。

## 验证矩阵

1. 构建：iPhone 17 / iOS 26.5 Simulator，独立 DerivedData。
2. 定向单元：`MealEditorDraftTests`、`MealReuseTests`、`MealItemEvidencePresentationTests`、`NotificationScheduleTests`。
3. 定向 UI：`MealPersistenceUITests`、`MealReuseUITests`。
4. 全量：`HealthManager` scheme 全测试，并用 `xcresulttool` 记录 executed / passed / failed / skipped。
5. 视觉：四个页面及关键错误 / 展开态至少覆盖 light、dark、accessibility-large；同状态 reference / runtime 同屏对照。

## 验证边界

- 不做真实 AI 服务请求；只验证现有状态和失败恢复 UI。
- 不改变或重新验证通知后台准时性，只验证现有输入 / 授权 / 保存路径未被 UI 改版破坏。
- 不进入 010D～010H，不以 Preview 代替 Simulator 运行证据。

## 结果

主架构师结论：`PASS`。

### Accepted 实现

- 餐食编辑器继续使用现有 `Form`、照片、文字、AI、分项和保存路径；AI 动作提升为明确的紫色估算入口，并把“只在点击后外发”“结果仍是估算”和部分失败后保留成功输入写进可读状态。保存错误固定在底部恢复区域，不再因表单变长而脱离懒加载树。
- 最近餐复用把加载、空白、失败、列表和分项选择分开表达；整餐复用与选择菜品继续生成新草稿，来源、未知营养和“原记录不变”边界可见。选择控件使用 SF Symbols、文字与 VoiceOver 选中状态，不以颜色或文本符号单独表达。
- 餐食分项证据继续完全消费既有 `MealItemEvidencePresentation`，紧凑态用来源标签，展开态保留引用、版本、置信、修订、备餐状态、字段覆盖、未知项与 caution；没有改变任何事实映射或已测试字符串。
- 用药计划编辑器把未来计划与实际动作明确分开；提醒拒绝使用可恢复状态，计划预览不暗示已服药。星期控件达到 44×44 pt，并在 accessibility size 自动切换为适应列布局，保留每天 / 工作日 / 周末快捷选择。
- 新增 `HMEditorGuide` 与 `HMEditorCallout` 均有至少两个真实使用点；没有新增图片资产、第三方 UI 包、运行时 QA 路由或产品能力。

### 回归修正

首轮定向 UI 回归发现两个真实可达性问题，并保留原始失败证据：

1. 餐食保存错误随表单内容增加后离开懒加载树；修正为不改变原始错误文本和 identifier 的底部恢复区，单项复验 1 / 1 通过。
2. 餐食编辑器顶部的非必要说明块挤占滚动空间，使第二次“添加菜品”在既有复用流程中不可达；删除该说明块而不是放宽 UI 测试，原失败流程复验 1 / 1 通过。

### 自动化证据

- 构建：`/tmp/healthmanager-stage010c-architect-build-20260716-attempt02`，exit 0，`BUILD SUCCEEDED`。
- 最终定向：42 / 42 passed，0 failed，0 skipped；`/tmp/healthmanager-stage010c-architect-targeted-20260716-attempt05.xcresult`。
- 最终全量：258 / 258 passed，0 failed，0 skipped；`/tmp/healthmanager-stage010c-architect-final-20260716-attempt01.xcresult`。
- 设备：iPhone 17 / iOS 26.5（23F77）Simulator；`xcresulttool` 已读取上述真实统计。
- `git diff --check`：PASS。

### 运行时视觉证据

- 专用 Simulator：`HealthManager-STAGE010C-QA-20260716` / `4B5F15D0-0C49-4820-A6E1-DFC8AAC98417`。
- 餐食编辑、复用列表、证据展开和用药计划编辑各有 light-large、dark-large、light-accessibility-large，共 12 张：`/tmp/healthmanager-stage010c-acceptance-20260716/screenshots/`。
- 四组 reference / runtime 同屏对照：`/tmp/healthmanager-stage010c-acceptance-20260716/comparisons/`；均已作为组合图逐张打开复核。
- dark-large 三条真实 UI 流程 3 / 3，通过：`/tmp/healthmanager-stage010c-visual-dark-large-20260716-attempt01.xcresult`；首次通知系统弹窗只影响取证画面，授权后用正式 Smoke 再取证 1 / 1，通过：`/tmp/healthmanager-stage010c-visual-dark-large-20260716-attempt02.xcresult`。
- accessibility-large 三条真实 UI 流程 3 / 3，通过：`/tmp/healthmanager-stage010c-visual-light-accessibility-large-20260716-attempt01.xcresult`。

参考图提供信息层级和色彩角色，不是业务 fixture。运行态没有写入参考图中的食物照片、AI 结果、药名或营养数值；因此同屏对照只判断真实状态下的层级、动作、来源、滚动和可读性，不把示例数据差异伪称为像素误差。最终未发现固定高度裁切、横向溢出、低对比度关键状态或不可达主动作。

本阶段没有发起真实 AI 请求，也不外推通知后台准时性、真实照片选择或真机行为；这些边界未被 UI 改版改变。没有 commit、tag 或 push。
