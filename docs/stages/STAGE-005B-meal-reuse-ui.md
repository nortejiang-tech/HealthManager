# STAGE-005B：低摩擦餐食复用入口

> 状态：PASS（软件与 Simulator 范围；STAGE-005A checkpoint `0b614ff`）
>
> 执行者：Coder；主架构师验收
>
> 前置决策：[ADR-001](../adr/ADR-001-normalized-meal-item-snapshots.md)

## 1. 唯一目标

把 STAGE-005A 已验收的最近餐、整餐/选中分项复制和常用克数接口接入现有饮食体验，使重复餐能快速进入一个可检查、可修改的新餐编辑草稿；用户仍必须显式点击保存，复用入口本身绝不写库。

本阶段只完成复用 UI 与编辑器草稿接线。来源/置信度展示属于 STAGE-006，主导航调整属于 STAGE-007，食品库、收藏模板、OCR、跨餐移动和自动保存均不进入本阶段。

## 2. 产品原则

- 优化自己的高频个人记录路径，不复制竞品的社区、目录、广告或复杂模板体系。
- “复用整餐”从饮食页入口到可编辑草稿最多两次明确操作：打开复用入口、选择复用整餐；保存仍是第三次独立确认。
- 复制只带入 STAGE-005A 允许的餐食与营养事实；历史照片、备注、数据库/HealthKit 身份和旧时间不能在 UI 层重新带回。
- 历史结果必须进入现有 `MealEditView`，用户可以调整餐次、时间、菜名、克数和营养后再保存；不得增加一条旁路保存逻辑。
- AI 未配置、关闭或离线时，历史复用与常用克数仍完整可用。

## 3. 状态所有权与模块边界

遵循现有 SwiftUI 和 iOS 17 基线：

- `DietView` 只拥有一个 item-driven sheet destination，统一表达新增、编辑和复用；不得继续堆叠多个互斥 Bool sheet。
- 新增聚焦组件 `UI/Diet/MealReuseView.swift`，承载复用 sheet、最近餐加载态、餐次卡片、选中分项页和常用克数小组件；不要继续扩大已很长的 `DietView.swift`。
- 复用 sheet 自己拥有“浏览最近餐 → 已生成 CopyDraft”阶段状态；选中后在同一个 sheet 流中切换到 `MealEditView`，不自动保存，也不通过全局 router 或 AppEnvironment 新状态协调。
- 最近餐用 `.task` 绑定 sheet 生命周期；loading、empty、failed/retry、loaded 必须互斥且可见。取消是正常路径，不显示为错误。
- 常用克数用 `.task(id:)` 随 canonical name 与 preparation state 变化而重载；对连续输入做短 debounce，并在取消后停止旧查询。查询失败只记录并隐藏这个非关键辅助，不阻断编辑或保存。
- 继续直接使用 `environment.mealStore`；不得新增 ViewModel、Repository、protocol、缓存、单例或第二套复用模型。

## 4. 饮食页入口与 sheet 合同

- 保留现有 `diet-add-meal` 按钮和编辑餐次入口。
- 新增可识别的 `diet-reuse-meal` 工具栏按钮，文案/辅助功能名称为“复用餐次”。
- 新增、编辑和复用改为一个 `.sheet(item:)` destination；任一时刻只能存在一个饮食 sheet。所有 sheet dismiss 后沿用现有 `refresh()`。
- 既有 smoke 不得依赖 toolbar 下标；改为点击稳定的 `diet-add-meal` identifier。
- 复用入口在没有历史数据时仍可打开，并显示明确空状态及关闭按钮；数据库读取失败显示中文错误和重试按钮。

## 5. 最近餐与复制交互合同

### 5.1 最近餐浏览

- 只调用 `MealStore.recentSnapshots(limit: 20, excludingMealId: nil)`，保持 Store 的排序、上限、legacy 与批量查询语义；View 不得自行查询 GRDB 或重新排序。
- 每个餐次至少显示餐次类型、时间、营养摘要和分项名称摘要；未知营养显示“—”，不能伪装为 0。
- 每个 snapshot 提供明确的“复用整餐”按钮；有持久化分项时另提供“选择菜品”。legacy 零分项餐只允许整餐复用。
- 不加载或展示历史照片，不把历史备注作为复制输入；可用菜名摘要帮助辨识来源餐。

### 5.2 生成草稿

- 生成草稿时只调用 `MealStore.makeCopyDraft`。目标时间只采样一次当前 `Date`；`targetMealType` 用该同一时间调用 `MealType.suggested(for:)`，`eatenAt` 也来自该时间。
- 整餐直接使用 `.wholeMeal`；选中页用持久化 child id Set，空选择时确认按钮禁用。
- 选中页按 snapshot 的来源顺序展示；点击行切换 checkmark。确认后只把选中项加入编辑器，任一 Store 错误以中文可见错误展示，不静默回退为整餐或部分复制。
- CopyDraft 生成后切换到现有新增餐编辑器；取消编辑应关闭整个复用 sheet，并且数据库餐次数量不变。

## 6. 编辑器接线合同

- `MealItemDraft` 新增从 `MealStore.ItemInput` 构建复用草稿的窄 initializer：保留 name、grams、preparation、四项可空营养、provenance kind/ref/version、confidence、`isUserEdited`；baseline 使用复制值以保持后续克数缩放语义；`createdAt` 保持 nil。
- `MealEditorDraft` 新增从 `MealStore.CopyDraft` 构建新餐的 initializer：`id=nil`、ready、无照片/备注/HealthKit id、`originalPhotoPaths=[]`，使用 CopyDraft 的新餐次、时间、createdAt 与营养事实。
- 有分项时 `nutritionItems` 与 `itemTotals` 来自 CopyDraft items 和共享投影；零分项 legacy copy 保留父级小数、合法 0 与 nil 文本，继续走手工汇总模式。
- `MealEditView(copying:)` 只用上述 initializer 初始化现有编辑器；保存仍唯一调用 `mealPersistenceCoordinator.save`，成功通知/关闭和失败保留草稿语义不得改变。
- 不把复制来源 snapshot 保存在编辑器，不允许保存时回写来源餐。

## 7. 常用克数合同

- 每个非空菜名分项最多展示前三个 `commonGramSuggestions` 结果；查询使用同一 canonical name，并按该 item 的精确 `preparationState` 过滤，防止混用生重与熟重。
- 建议显示稳定的小数格式和“g”；每个按钮有稳定 accessibility identifier。
- 点击建议只更新该分项 `gramsText`，让现有 `MealItemDraft` 缩放和 `isUserEdited` 规则自然生效；不得直接改四项营养、来源或父汇总。
- 空名称、无结果、查询取消或失败时不展示占位的 0g；失败不影响其他编辑能力。

## 8. 自动化证据

单元测试至少覆盖：

1. `ItemInput → MealItemDraft` 保留所有可空营养、合法 0、preparation、来源/置信度/修订状态，且 createdAt 为 nil；改变克数仍按复制 baseline 缩放。
2. 有分项 `CopyDraft → MealEditorDraft` 是 ready 的新餐，父身份、照片、备注、HealthKit 均为空，分项顺序/事实完整，汇总使用共享投影。
3. legacy 零分项 CopyDraft 保留父级小数、0 与 nil，并处于手工汇总模式。
4. 从复用草稿 `makeMealRecord` 与 `nutritionItems.toItemInput()` 仍能穿过现有保存接口，不创建第二套映射。

UI 自动化至少覆盖：

5. 整餐复用从 `diet-reuse-meal` 两次操作进入“添加餐次”编辑器，分项/克数已带入；取消后餐次行数量不增加。
6. 选中分项只把勾选项带入编辑器，来源备注未带入；显式保存后列表出现新记录，重开仍只有选中分项，测试最后清理来源与副本。
7. 为同名同 preparation 的新分项显示历史常用克数，点击后 `gramsText` 使用该值。
8. 原有新增、编辑和 smoke 仍通过稳定 identifier；不得通过测试专用数据库旁路或复制生产筛选/投影算法造结果。

## 9. 允许与禁止范围

允许：

- 新增 `UI/Diet/MealReuseView.swift`
- `UI/Diet/DietView.swift` 的单一 sheet 接线、复用入口、copy initializer 调用和常用克数组件嵌入
- `UI/Diet/MealEditorDraft.swift`
- `UI/Diet/MealItemDraft.swift`
- 最小修改 `Tests/MealEditorDraftTests.swift`、`Tests/MealItemDraftTests.swift`
- 新增 `UITests/MealReuseUITests.swift`
- `UITests/SmokeTests.swift` 只把 toolbar 下标改为稳定 identifier
- xcodegen 必要生成结果

禁止：

- 修改 schema、迁移、DatabaseManager、数据库 Record、MealStore/MealReuseModels/MealNutritionProjection 合同
- 修改 AppEnvironment、Coordinator、照片存储、HealthKit、SyncEngine、通知或 AI 请求/解析
- 增加来源徽标、置信度 UI、食品库、收藏模板、OCR、条码、跨餐移动、导航改版或睡眠
- 自动保存、复制历史照片/备注/id/同步 id/旧时间，或给取消操作增加写入副作用
- 引入 ViewModel、protocol、Repository、全局 router、缓存或新的全局单例
- 修改 ADR/STAGE 文档、commit、tag 或 push

## 10. 完成标准与验证边界

- 新增/修改单元测试、`MealReuseTests` 与相关 editor/item 测试全部通过。
- 新增 `MealReuseUITests`、原有 `MealPersistenceUITests` 和 `SmokeTests` 在 iPhone 17 / iOS 26.5 Simulator 全部通过，且 `uitest-*` 测试记录最终清零。
- 全量 `HealthManagerTests`、全量 UI tests 与独立 build 由主架构师运行。
- `git diff --check` 通过且 diff 只有允许文件；静态核对复制入口不直接写库，保存仍只走 Coordinator。
- Simulator 只证明 UI、SQLite 与编辑器流；真实 PhotosPicker/相机和 HealthKit 不在本阶段触发，既有真机数据库仍为 INCOMPLETE。

## 11. 正式结果

> 由主架构师填写。

- 状态：PASS（软件与 Simulator 范围）
- 验收日期：2026-07-14
- 验收 commit：本文件所在 STAGE-005B checkpoint
- 定向证据：`MealEditorDraftTests` 与 `MealItemDraftTests` 等本阶段相关单元测试共 31/31；结果包 `/tmp/healthmanager-stage005b-architect-unit-v2-20260714.xcresult`
- 全量证据：最终代码上的 `HealthManagerTests` 176/176；结果包 `/tmp/healthmanager-stage005b-full-unit-v2-20260714.xcresult`。最终代码上的 `HealthManagerUITests` 6/6，覆盖既有持久化 2 项、餐食复用 3 项和全局 smoke 1 项；结果包 `/tmp/healthmanager-stage005b-full-ui-v3-20260714.xcresult`。独立 iPhone 17 / iOS 26.5 Simulator build succeeded，0 error、0 warning；结果包 `/tmp/healthmanager-stage005b-build-v2-20260714.xcresult`
- 交互与视觉核对：最终 UI 结果包保留 `reuse-whole-list`、`reuse-whole-editor`、`reuse-item-selection`、`common-grams-suggestion` 四张本阶段截图以及既有 smoke 截图；主架构师导出并逐张核对。整餐复用在两次选择后进入现有“添加餐次”编辑器，选中分项只带入勾选项，常用克数按钮写入现有 `gramsText`，取消不新增记录，显式保存的副本可重开且来源备注未带入
- 数据与副作用核对：最终全量 UI 回归后直接读取实际 iPhone 17 Simulator 的 `health.sqlite`，测试标记父餐、四类测试分项和全库孤儿分项计数均为 `0|0|0`。测试只通过真实 UI 定向删除自己创建的唯一标记记录，无批量清库或测试专用数据库写入。复用页只调用 `recentSnapshots`、`makeCopyDraft` 与 `commonGramSuggestions`，不直接调用 Coordinator、GRDB、数据库写入、照片或 HealthKit；最终保存仍唯一经过现有 `mealPersistenceCoordinator.save`
- 合同核对：`DietView` 只有一个 `.sheet(item:)` destination；新增、编辑和复用互斥。CopyDraft 到编辑草稿时清空父 id、照片、备注、HealthKit id 和旧 photo path，child `createdAt` 保持 nil，合法 0、未知 nil、preparation、来源/置信度和分项顺序保持不变；有分项父汇总继续使用共享保守投影，legacy 零分项继续走手工汇总。常用克数按 canonical name、精确 preparation 和 `limit: 3` 查询，180 ms debounce，取消旧 task，失败只隐藏辅助项
- 静态与审查核对：`git diff --check` 通过；diff 仅含本阶段白名单实现、测试和本验收结果。主架构师按 `b7f5ce1` 固定点完成产品合同与代码实现双轴审查，最终无未解决 finding；额外修正了 VoiceOver 不应朗读测试技术前缀，以及正常路径虽已禁用但仍应穷举中文展示的空选择错误
- 执行记录：Coder 初稿曾包含不符合安全边界的批量清理方式，主架构师在进入 checkpoint 前中止；按约定给予一次集中修复后仍存在连续编译与质量问题，因此由主架构师接管。接管后改为唯一 marker 的 UI 定向清理，补齐复制映射、single-sheet 流、常用克数生命周期、无障碍标识与最终全量证据；被拒绝的批量清理代码未进入提交
- 残余风险：本阶段没有触发真实 PhotosPicker/相机或 HealthKit，也不证明既有真机数据库行为，继续保留为 INCOMPLETE。空历史和数据库失败/重试分支已做静态合同审查，但本阶段没有为生产 Store 注入故障以取得动态 UI 证据；后续只有出现真实故障或建立通用可控依赖注入边界时再补，不为单一测试引入 ViewModel/protocol。来源与置信度的用户可见呈现属于 STAGE-006
