# STAGE-006：餐食来源与证据呈现

> 状态：PASS（软件与 Simulator 范围）
>
> 执行者：Coder 初稿；主架构师接管修复并独立验收
>
> 前置决策：[ADR-001](../adr/ADR-001-normalized-meal-item-snapshots.md)

## 1. 唯一目标

把已经随 `MealItemDraft` 持久化并能无损复用的来源、引用、版本、置信度、备餐状态、营养字段覆盖和人工修订事实，转成每个餐食分项都能看见、按需展开的数据依据；不新增或推断任何可信分数。

本阶段只做现有事实的纯展示与编辑器接线。食品数据库接入、标签 OCR、条码、份量单位、来源选择器、修订历史时间线和异常检测属于后续阶段，不在这里提前建设。

## 2. 产品判断与设计选择

竞品研究中真正符合 HealthManager 边界的不是一个绿色“准确”勾，而是让用户能回答“这条数据来自哪里、依据是什么、是否被我改过、哪些营养字段仍未知”。当前 schema 已有 item 级来源事实，STAGE-006 应把它们诚实呈现出来，不把字段包装成未经验证的准确率。

比较过三种方案：

1. 只放一个来源徽标：安静，但引用、版本、未知字段和风险说明不可审计，信息不足。
2. 每个分项永久展开全部元数据：完整，但会让高频记录表单变成诊断页面，破坏 STAGE-005B 刚建立的低摩擦体验。
3. **采用：一行紧凑事实徽标 + 同行按需展开的数据依据**。默认只显示来源、已保存置信字段和“已人工修订”；展开后显示引用、版本、备餐状态、营养字段覆盖及与来源类型相匹配的说明。

明确不采用综合 Data Confidence 分数、颜色化好坏等级或“已验证”勾。当前只有四项宏量字段、item 级来源和一个未校准 confidence 字段，不能据此制造可比较的质量评分。

## 3. 唯一展示规则来源

新增纯值 `MealItemEvidencePresentation`（建议位于 `UI/Diet/MealItemEvidenceView.swift`），由一个 `MealItemDraft` 生成：

- 来源标题和 SF Symbol 名称；
- 可选紧凑置信文案；
- 是否显示“已人工修订”；
- 详情行（来源、可选引用、可选版本、置信记录、修订状态、备餐状态、营养字段覆盖）；
- 与来源类型匹配的中文说明；
- 供无障碍按钮朗读的单一摘要。

Presentation 不依赖 `Color`、SwiftUI 状态、Store、数据库或环境对象，必须可直接单元测试。View 只负责样式、展开状态和 accessibility identifier；不得在 `DietView`、测试或多个 View 中复制映射 switch。

`provenanceRef` 与 `provenanceVersion` 只在展示时 trim；空白值按缺失处理，但不得修改或重写草稿内保存的原值。当前 schema 是 item 级来源，UI 不得暗示四个营养素各自拥有独立来源。

## 4. 来源与措辞合同

| `ProvenanceKind` | 默认来源标题 | 紧凑置信行为 | 展开说明要点 |
|---|---|---|---|
| `.manual` | 手工录入 | nil 时紧凑行不显示置信徽标，详情写“不适用（手工录入）”；若异常历史数据确有 confidence，仍如实显示 | 由用户手工录入，未附加独立数据来源 |
| `.aiEstimate` | AI 估算 | 有值显示“置信：低/中/高”，nil 显示“置信未提供” | confidence 来自模型输出且未校准，AI 是估算，保存前应核对 |
| `.nutritionDatabase` | 营养数据库 | 有值显示记录值，nil 显示“置信未提供” | 数据库名称或引用不等于当前条目已被独立验证 |
| `.nutritionLabel` | 包装标签 | 有值显示记录值，nil 显示“置信未提供” | 标签口径可能是每份或每 100g；当前模型没有份量单位证据时不能声称已经核对 |

置信只映射现有 enum：low=低、medium=中、high=高。不得出现准确率百分比、临床级、权威、可靠或“高置信 = 正确”等表述。

`isUserEdited == true` 时始终显示“已人工修订”。false 时紧凑行不增加噪声，但展开详情必须明确：手工来源写“原始手工录入”，其他来源写“未人工修订”。当前字段没有修订时间和字段级差异，不能展示伪造的历史、操作者或修改内容。

备餐状态显示：unknown=未标注，raw=生重，cooked=熟重。这里只展示，不新增编辑控件。

## 5. 营养字段覆盖合同

展开详情显示“营养字段：N/4 已记录”，只统计当前 `MealItemDraft` 的 calories/protein/fat/carbs 是否非 nil：

- 合法 0 算已记录；nil 算未知；
- 不把 4/4 命名为“完整”“准确”或“高质量”；
- 若存在未知项，列出“未知：热量、蛋白质、脂肪、碳水”中的实际子集；
- 不把 grams、名称或备餐状态混入 4 项计数；
- 不改变 `MealNutritionProjection`，不为展示另算父汇总。

该信息只是事实覆盖，不是质量分数。它允许用户区分“某项明确为 0”和“某项根本没有数据”。

## 6. 编辑器 UI 合同

- 新增聚焦 `MealItemEvidenceView`，嵌入现有 `nutritionItemRow` 的宏量营养行之后、常用克数之前；不要继续把元数据 switch 堆进 `DietView.swift`。
- 默认折叠时是一行可点击的紧凑徽标：来源必有；非手工来源的缺失 confidence 也必须可见；已人工修订按事实出现。长引用和版本不得塞进默认行。
- 点击同一行展开/收起详情，不打开新 sheet、不改变键盘输入、不写库。每个 item 自己持有本地展开 Bool；ForEach 的现有 draft UUID 继续保证状态归属。
- 展开详情按需显示引用和版本，始终显示置信记录/修订状态/备餐状态/字段覆盖与来源说明。长引用允许多行和文本选择，不截断为误导性短值。
- 展开按钮必须有稳定 identifier `meal-item-evidence-toggle-{index}`，并使用人类可读 accessibility label/value；详情至少有稳定的 source、confidence、revision、preparation、coverage、unknown 与 caution identifiers。技术 identifier 不能成为 VoiceOver 文案。
- Presentation 随绑定 item 值重新生成；AI/数据库/标签草稿的名称或克数发生真实修改后，现有 `isUserEdited` 变 true，徽标应立即出现，无第二套状态同步。
- 删除当前只反映最后一次异步 batch 的 `nutritionEstimate.confidence` 页尾文字；多输入可能有不同 confidence，而且该临时值重开后消失。保留现有 estimate note 和 error；每项持久化 confidence 才是来源展示事实。
- 保存、取消、照片、AI 请求、常用克数、复用、父汇总和 Coordinator 流程均不得改变。

## 7. 自动化证据

新增 `MealItemEvidencePresentationTests`，至少覆盖：

1. 四种 `ProvenanceKind` 都得到准确中文来源标题和稳定 symbol；用 `allCases` 防止漏 case。
2. low/medium/high 与 nil 的显示规则；manual nil 不制造“低置信”，AI/database/label nil 显示未提供。
3. 引用与版本 trim 后展示，纯空白被省略但原 draft 不变。
4. AI 的模型引用、版本、置信、已人工修订、cooked 及风险说明同时存在；说明不包含准确率或“已验证”。
5. 名称或克数修订后 presentation 立即反映现有 sticky `isUserEdited`，不修改 `MealItemDraft` 规则。
6. 四项覆盖对 nil 与合法 0 区分正确，未知名称列表稳定且不参与任何汇总。
7. 手工、数据库和包装标签的详情措辞不会把来源名称等同于准确性。

最小扩展现有 `MealPersistenceUITests.test_manualItemRoundTripRemainsOnReloadThenCleanup`：

8. 手工 item 默认出现“手工录入”紧凑依据行，展开后可见“0/4 已记录”、备餐未标注和手工来源说明；保存并重开后仍存在。
9. 保留一张展开状态截图作为布局证据；测试继续只用唯一 marker 通过真实 UI 删除自己创建的餐次。

AI/database/label 不允许为 UI 测试新增 debug seed、数据库旁路或真实 LLM 依赖；这些类型由纯 presentation 单测穷举，生产 UI 接线由同一个 View 覆盖。

## 8. 允许与禁止范围

允许：

- 新增 `UI/Diet/MealItemEvidenceView.swift`
- 最小修改 `UI/Diet/DietView.swift`：嵌入 evidence view、移除误导性的 transient batch confidence 及失去用途的 helper
- 新增 `Tests/MealItemEvidencePresentationTests.swift`
- 最小修改 `UITests/MealPersistenceUITests.swift`
- xcodegen 必要生成结果

禁止：

- 修改 schema、迁移、`MealItemRecord`、`MealStore`、`MealItemDraft` 映射/修订语义、`MealEditorDraft`、Coordinator、AppEnvironment 或数据库
- 修改 AI prompt/请求/解析、照片、HealthKit、SyncEngine、通知、复用、常用克数或导航
- 新增来源选择器、可信度编辑器、修订历史、食品库、OCR、条码、份量单位或异常检测
- 新增综合评分、准确率、验证勾、上传、分析 SDK、ViewModel、Repository、protocol、缓存或单例
- 为测试清空用户餐次、直写 SQLite、增加 debug seed，或依赖真实 LLM
- 修改 ADR/STAGE 文档、commit、tag 或 push

## 9. 完成标准与验证边界

- 新增 presentation 单测、现有 `MealItemDraftTests`/`MealEditorDraftTests` 全部通过。
- 修改后的 `MealPersistenceUITests`、`MealReuseUITests` 和 `SmokeTests` 通过；测试记录最终清零。
- 全量 `HealthManagerTests`、全量 UI tests 与独立 build 由主架构师运行。
- 主架构师导出并目视核对展开状态截图；紧凑行不遮挡名称、克数、宏量值、常用克数或保存按钮。
- `git diff --check` 通过且 diff 只有白名单文件；静态核对 presentation 是唯一 switch，evidence view 无 Store/数据库/写入调用。
- Simulator 能证明 UI 映射、保存重开和布局；它不证明 VoiceOver 真机听感、Dynamic Type 最大档、PhotosPicker/相机或 HealthKit，未执行项保持 INCOMPLETE。

## 10. 正式结果

- 状态：PASS（软件与 Simulator 范围）
- 验收日期：2026-07-14
- 验收 commit：本文件所在 STAGE-006 checkpoint
- 定向证据：最终代码上的 `MealItemEvidencePresentationTests`、`MealItemDraftTests` 与 `MealEditorDraftTests` 共 29/29；结果包 `/tmp/healthmanager-stage006-architect-unit-v2-20260714.xcresult`。新增的 8 个 Presentation 测试穷举四类来源、全部 confidence、manual 异常历史 confidence、引用/版本 trim、三类备餐状态、0 与 nil 覆盖、四类风险措辞、sticky 修订事实，以及 AI 引用/版本/置信/人工修订/熟重/风险说明的同实例组合合同
- 全量证据：最终代码上的 `HealthManagerTests` 184/184；结果包 `/tmp/healthmanager-stage006-architect-full-unit-v2-20260714.xcresult`。最终代码上的 `HealthManagerUITests` 6/6；结果包 `/tmp/healthmanager-stage006-architect-full-ui-v2-20260714.xcresult`。独立 iPhone 17 / iOS 26.5 Simulator build succeeded，0 error、0 warning；结果包 `/tmp/healthmanager-stage006-architect-build-v2-20260714.xcresult`
- 交互与视觉核对：最终 UI 结果包导出至 `/tmp/healthmanager-stage006-full-ui-v2-attachments`。主架构师目视核对 `meal-item-evidence-expanded` 与复用编辑器截图：来源行是真实 44pt 点击区，折叠/展开状态明确；0/4、未知字段和手工来源说明可读；名称、克数、宏量值、常用克数、添加菜品、合计和顶部保存均未被遮挡或截断
- 数据与副作用核对：最终全量 UI 后直接读取实际 iPhone 17 Simulator 的 `health.sqlite`，测试标记父餐、测试分项和全库孤儿分项计数为 `0|0|0`。测试继续只通过唯一 marker 的真实 UI 定向删除，不清库、不直写 SQLite、不加入 debug seed 或真实 LLM 依赖
- 产品合同核对：`MealItemEvidencePresentation` 是来源标题、symbol、风险说明、confidence、紧凑/详情修订文案、备餐状态、覆盖和 accessibility 摘要的唯一规则源；四类来源元数据集中在单一 switch。manual nil 不制造置信徽标，异常历史 manual confidence 不被隐藏；0 算已记录、nil 才未知；View 不依赖 Store、GRDB、环境对象或写入调用。页尾瞬态 batch confidence 已删除，estimate note/error 与保存、AI、照片、复用、常用克数、父汇总和 Coordinator 路径未改变
- 双轴审查：以 `e02cd40` 为固定点完成 Standards 与 Spec 复核。首轮发现紧凑修订文案绕过 Presentation、缺少 AI 组合用例和来源元数据重复 switch，均已修正；复核结论为规格轴 PASS、标准轴无阻断 finding。两个 UI 测试文件保留局部滚动/输入 helper 重复，作为当前仅两处且不引入跨阶段共享测试框架的非阻断取舍；出现第三个调用方时再抽取
- 执行与接管记录：首个 Coder 候选的定向单测通过，但 UI 为 4/6；一次集中修复仍未遵守“失败即停止”并继续扩大测试 helper，主架构师按约定中止 Coder 并接管。接管后从失败 xcresult、Accessibility hierarchy 与屏幕录制定位出三类问题：懒加载前读取元素 identifier、被 sheet 覆盖的底层 TabBar 被误判为遮挡、圆角来源行视觉高度与真实 14.3pt 点击区不一致；最终分别以查询生命周期修复、真实 sheet 边界判断和 44pt 内容点击区闭环
- 边界例外：`UITests/MealReuseUITests.swift` 不在原 Coder 白名单，但新增 Evidence 行使既有备注输入回归真实失败。主架构师批准仅调整滚动可见性与输入后置条件，并用最终全量 6/6 证明；未修改复用产品逻辑。该例外有失败结果包与 UI 层级证据，不扩展产品范围
- 残余风险：Simulator 不证明 VoiceOver 真机听感、Dynamic Type 最大档、真实 PhotosPicker/相机、HealthKit 或既有真机数据库行为；这些项目继续标记 INCOMPLETE，进入 STAGE-009 次日真机清单。本阶段没有来源编辑器、食品数据库/OCR/条码、份量单位、综合评分或准确率结论
