# STAGE-003：可测试的餐食分项草稿模型

> 状态：READY（STAGE-002 PASS，checkpoint `66ee696`）
>
> 执行者：Coder；主架构师验收
>
> 前置决策：[ADR-001](../adr/ADR-001-normalized-meal-item-snapshots.md)

## 1. 唯一目标

把 `DietView.swift` 内的 `EditableNutritionItem` 抽成独立、可测试的 `MealItemDraft` 值类型，统一 AI 候选、已持久化快照和手工新增分项到 `MealStore.ItemInput` 的映射，并保留来源、置信度、未知值和用户修订语义。

本阶段只建立编辑草稿 seam；餐次编辑页加载/保存分项属于 STAGE-004。

## 2. 已验证问题

当前 `EditableNutritionItem` 存在于 View 文件末尾，并有以下已从代码确认的限制：

- AI 未返回克数时默认成 100g，未返回营养值时默认成 0，违反 ADR-001 的“未知仍为未知”。
- 克数展示会四舍五入到整数，无法无损承接数据库中的小数克数。
- AI 批次的 confidence 与所用模型没有进入分项草稿。
- 手工、AI 与数据库快照没有统一的 `MealStore.ItemInput` 映射入口。
- 用户改过 AI/数据库候选后，没有可测试的 `is_user_edited` 更新语义。

## 3. 模块与 seam

新增 `UI/Diet/MealItemDraft.swift`，提供具体值类型 `MealItemDraft`；不创建 protocol。

至少提供以下行为入口：

1. AI 映射：输入 `MealNutritionAnalyzer.Item`、批次 confidence、可选模型引用和可选版本，生成 `.aiEstimate` 草稿。
2. 快照映射：输入 `MealItemRecord`，保留名称、克数、备餐状态、四项可空营养、来源、引用/版本、置信度、用户修订和历史 `createdAt`。
3. 手工工厂：生成空名称、未知克数/营养、`.manual` 来源的草稿，不伪造 100g 或 0 营养。
4. Store 映射：通过一个可测试入口生成 `MealStore.ItemInput`；不得让 View 手工逐字段映射。
5. 去重：迁移现有规范化名称和顺序保留的 dedup 行为，不改变限定词区分规则。

草稿允许用 UUID 作为仅用于当前编辑会话的 SwiftUI identity；数据库 child id 不进入 `MealStore.ItemInput`。

## 4. 数据与编辑不变量

1. `grams`、calories、protein、fat、carbs 的未知值必须保持 nil，不得默认成 100 或 0 后写入 Store。
2. 已知克数和营养值作为 baseline；用户输入新的合法克数时，各个已知营养值按比例缩放，各个 nil 指标仍分别为 nil。
3. baseline 克数未知或用户清空克数时，不猜测缩放比例；已知营养快照保持原值，克数映射为 nil。
4. 非空克数字符串若不能解析为有限且大于 0 的数，Store 映射必须抛出显式草稿校验错误，不能静默当作 nil。
5. AI confidence 仅接受 trim/case 归一化后的 low/medium/high；其他字符串映射为 nil，不能制造可信度。
6. AI/数据库/标签来源草稿的名称或克数实际发生变化后，`isUserEdited` 变为 true；赋相同值不算修改，已为 true 不回退。
7. 手工草稿由用户输入是其来源本义，`isUserEdited` 保持 false；不得把手工输入伪装成“修改过 AI”。
8. 来源种类、引用、版本、备餐状态和历史 `createdAt` 在草稿转 Store 时不得丢失。
9. UI 为显示兼容把 nil 渲染成 0 或占位符时，只能使用明确命名的 display 值；Store 映射必须使用可空真实值。

## 5. DietView 最小接线

- 将 View 状态从 `[EditableNutritionItem]` 改为 `[MealItemDraft]`，删除旧类型定义。
- AI 成功结果必须把该次 `Estimate.confidence` 传给每个草稿。
- `AnalysisJob` 在创建时捕获所用模型名称：文字使用当时的 `LLMConfig.textModel`，照片使用当时的 `LLMConfig.visionModel`；空名称映射为 nil。不得保存 URL 或 API key。
- “添加菜品”使用手工工厂。
- 现有 AI 并发、输入去重、照片、父餐次保存与 HealthKit 行为保持不变。

## 6. 自动化证据

新增 `MealItemDraftTests`，并将现有 `NutritionItemDedupTests` 改到新类型。至少覆盖：

1. AI 映射保留可空字段、合法 confidence 和模型引用；未知克数/指标不被默认。
2. 非法 confidence 为 nil。
3. 手工草稿不伪造值，输入名称/克数不标记为机器候选修订。
4. 快照到草稿再到 `MealStore.ItemInput` 保留全部合同字段和小数克数。
5. 合法克数编辑按比例缩放，各指标 nil 独立保留。
6. 非手工候选发生名称或克数变化时标记用户修订；相同赋值不标记。
7. 非空非法、零、负数和非有限克数在 Store 映射时显式失败；空字符串映射 nil。
8. 现有五条名称去重行为继续通过。

测试必须通过 `MealItemDraft` 的公开 seam 观察结果，不复制映射实现。

## 7. 允许与禁止范围

允许：

- 新增 `UI/Diet/MealItemDraft.swift`
- 最小修改 `UI/Diet/DietView.swift`
- 新增 `Tests/MealItemDraftTests.swift`
- 修改 `Tests/NutritionItemDedupTests.swift`
- xcodegen 生成所需项目

禁止：

- 修改迁移、`MealItemRecord`、`MealStore` 或 `DatabaseManager`
- 在本阶段加载或保存 `meal_items`
- 修改照片文件清理、HealthKit 写回/删除、AI 请求或解析器
- 修改导航、来源展示、最近餐/复制功能
- 修改 ADR/STAGE 文档、commit、tag 或 push

## 8. 完成标准与验证边界

- `MealItemDraftTests` 与 `NutritionItemDedupTests` 全部通过。
- 全量 `HealthManagerTests` 由主架构师独立运行并通过。
- iPhone 17 / iOS 26.5 Simulator build 成功。
- diff 只有允许文件，`git diff --check` 通过。
- 本阶段不验证重新打开餐次、数据库分项持久化、照片清理、HealthKit 或真机。

## 9. 正式结果

> 由主架构师填写。

- 状态：PENDING
- 验收日期：—
- 验收 commit：—
- 证据：—
- 残余风险：—
