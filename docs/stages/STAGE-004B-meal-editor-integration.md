# STAGE-004B：餐食分项编辑器真实持久化接入

> 状态：PASS（2026-07-14；真实 HealthKit 与真机照片路径证据为 INCOMPLETE）
>
> 执行者：Coder；主架构师验收
>
> 前置决策：[ADR-001](../adr/ADR-001-normalized-meal-item-snapshots.md)

## 1. 唯一目标

让 `MealEditView` 通过 `MealStore` 与 `MealPersistenceCoordinator` 真正加载、保存和重新打开餐食分项；保存/删除失败必须留在当前界面并给出可见反馈，不得丢失分项、照片、未知值或最新 HealthKit 同步标识。

本阶段完成“可信记录基础”的实际 UI 接入，不加入最近餐、复制、食品库、来源标签或导航改版。

## 2. 已验证的当前风险

当前源码与独立只读审计已确认：

- 编辑页只接收父 `MealRecord`，没有加载 `meal_items`；若直接把当前空 `nutritionItems` 交给 Store，会删除已保存 children。
- 保存按钮无互斥，且无论内部保存是否失败都会 `dismiss()`；双击新建还可能重复插入。
- `MealStore.save` 更新整条父记录，陈旧编辑快照可能把刚由 `saveSyncId` 写入的最新 `hkSyncId` 覆盖成旧值或 nil。
- 图片与路径由两个数组按 index 配对；旧文件缺失时 `compactMap` 会使二者错位，之后删除或 AI 分析可能作用于错误路径。
- UI 以 `nil ?? 0` 汇总分项，违反 ADR-001“未知不能伪装为 0”；父汇总小数还会被 `Int` 截断。
- 分项存在时底部父汇总仍可编辑，但 Store 最终会用分项投影覆盖它，形成“输入看似生效、保存后被静默丢弃”的假交互。
- 列表删除仍绕过 Coordinator，照片和 HealthKit 清理由列表中的潜在陈旧 record 驱动，而不是数据库删除 receipt。

## 3. 深模块与唯一规则来源

### 3.1 MealNutritionProjection

新增纯值模块 `MealNutritionProjection`，提供小接口：

- 输入为一组只含四项 optional 营养值的 `MealNutritionValues`。
- 空数组返回 nil，表示“没有分项，保留父记录手工/历史汇总”。
- 非空数组返回 `MealNutritionTotals`；每个指标只有全部分项都已知时才求和，任一未知则该指标为 nil；已知 0 必须仍是 0。
- `MealNutritionTotals` 提供“是否至少有一个有限且大于 0 的 HealthKit 可写值”的只读判断。

`MealStore` 和编辑表单都调用这一模块；不得在 View 或测试中各自复制求和规则。`MealStore` 仍是实际数据库投影与事务的唯一事实源。

### 3.2 MealEditorDraft

新增由 View 以 `@State` 持有的纯值 `MealEditorDraft`，不引入 ViewModel、protocol 或 Repository。它把以下行为藏在同一 interface 后：

- `init(meal:)`：用列表父记录提供即时初值，但不把它视为完成加载。
- `apply(snapshot:)`：以 Store snapshot 一次性覆盖父字段并把 records 映射为 `MealItemDraft`，保留顺序、来源、置信度、修订标记、createdAt 与 nil。
- `reconcileTotalsFromItems()`：仅调用 `MealNutritionProjection` 更新显示文本；有分项时未知显示为空/占位而非 0；删除到 0 个分项时保留当前父汇总，转回可编辑的快速汇总模式。
- `makeMealRecord(photoPaths:now:)`：显式解析无分项时的父汇总，保留已加载 meal 的 id、createdAt、hkSyncId；空文本为 nil，合法 0 与小数不丢失，非空非法/非有限/负数抛出字段明确的错误。有分项时父值来自共享投影，最终仍由 Store 复核。

### 3.3 MealPhotoDraft

用单一 `MealPhotoDraft` 数组替代 `previewImages` + `savedPhotoPaths` 的并行状态。每项至少绑定：

- path；
- optional image（文件缺失时仍保留 path 并显示占位，不自动丢数据库引用）；
- 是否为本次编辑会话新建。

现有照片由带 loader closure 的窄构造入口生成，测试可注入缺失文件；AI 只处理有 image 的项。取消时只清理本会话新建且未提交的文件。照片导入、保存或 AI 分析期间禁止取消/交互式关闭，避免异步导入完成后留下孤儿文件。

## 4. Store 并发不变量

`MealStore.save` 更新已有 meal 时，必须在同一 write 事务中读取数据库当前记录，并始终保留数据库中的最新 `hkSyncId`；一般餐食编辑不具备清空或改写该元数据的权限。新建 meal 仍保留输入 record 的 sync id。

必须用交错回归测试证明：陈旧 snapshot 为 nil/旧 id，期间 `saveSyncId` 已写入新 id，之后保存餐食字段与 children 不会把新 id 覆盖掉；Coordinator 的 HealthKit writer 收到的也应是 Store 返回的最新 id。

## 5. 编辑器加载、保存与删除合同

### 5.1 加载

- 新建页直接 ready。
- 传入已有 meal 时从初始化起进入 loading；保存按钮禁用。
- 只有 `environment.mealStore.load(id:)` 成功返回 snapshot 后才进入 ready。
- 传入 editing 但 id 缺失、Store 返回 nil 或读取失败时显示明确错误并保持不可保存；不得降级成新建。
- snapshot 是权威状态；照片按 path 构建，文件缺失不造成 path/image 错位。

### 5.2 保存

- 按钮 action 必须同步设置 `isSaving` 后再启动异步工作，阻止双击产生两个任务。
- loading、saving、照片导入或 AI 分析期间不可保存；保存期间不可取消。
- 先由 `MealEditorDraft` 构造 record，再只调用 `environment.mealPersistenceCoordinator.save(meal:drafts:originalPhotoPaths:)`。
- Coordinator 成功返回后更新当前 snapshot/original photos，恰好通知一次 `notifyLocalDataChanged()`，然后 dismiss。
- 任一校验或数据库失败都不通知、不 dismiss、不清理仍在编辑器中引用的新照片；错误必须在界面可见，用户可修正后重试。
- 移除当前 View 内直接父记录 insert/update、旧照片 GC、HealthKit 写回和 `syncNutritionToHealth`。

### 5.3 删除

- `DietView` 列表删除只调用 `mealPersistenceCoordinator.delete(mealId:)`。
- 成功后通知一次并 refresh；失败不通知，显示可见错误。
- 无 id 时不触发外部副作用。

## 6. UI 语义

- 分项 Section 始终存在；没有 AI 结果时也能添加第一个手工菜品。
- 单项未知营养显示“—”，不能显示 `0 kcal/0g`；合法已知 0 仍显示 0。
- 有分项时父汇总字段只读，并说明由分项保守汇总；无分项时保留快速手工汇总编辑。
- 分项名称为空、克数非法或父汇总非法时显示中文、字段明确的错误，不关闭界面。
- 加载与保存有进度反馈；给保存、错误、备注、父汇总、添加分项和首个分项输入增加稳定 accessibility identifier，供 UI 验收使用。
- 不在本阶段展示来源/置信度徽标，不改 AI 请求、模型设置、导航或视觉体系。

## 7. HealthKit 无效请求门禁

`syncMealNutrition` 在请求授权前先用共享 totals 判断原始输入是否至少有一个有限且大于 0 的值；全 nil/0 时直接 `notWritten`，不得为一餐没有可写营养的记录弹出授权。existing id 本身仍不构成成功。

“已同步餐次后来清空全部营养时如何可确认地删除旧 HealthKit 样本”需要真实删除结果与真机验证；本阶段不得把 best-effort 删除伪装成成功，列入 STAGE-009/次日真机清单。

## 8. 自动化证据

至少覆盖：

1. 共享投影：空分项、全已知、单指标未知、合法 0 和 HealthKit 可写判断。
2. Store 陈旧 snapshot 与 `saveSyncId` 交错后保留最新 id、children 与其他编辑字段。
3. EditorDraft 从权威 snapshot 恢复全部分项元数据、父级小数/nil、照片之外的表单字段。
4. 新建/编辑 record 构造保留或生成正确 id/createdAt/hkSyncId；非法父汇总显式失败。
5. 有分项时 UI 投影与 Store 保存结果一致，未知指标仍为 nil；零分项 legacy 往返保持父汇总。
6. PhotoDraft 中间图片缺失仍保持 path 顺序；取消清理只作用于会话新增文件。
7. UI 自动化：非法父汇总保存后编辑页仍在且出现错误；新增手工分项保存后，从列表重新打开仍看到相同名称/克数，最后清理测试记录。
8. 静态检查证明 `DietView` 不再直接 insert/update/delete MealRecord，不再直接清理已保存照片或调用 meal nutrition HealthKit 写回。

测试必须穿过 `MealNutritionProjection`、`MealEditorDraft`、MealStore/Coordinator 的真实 interface；不得复制生产求和、解析或副作用判断。

## 9. 允许与禁止范围

允许：

- 新增 `Core/Database/MealNutritionProjection.swift`
- `Core/Database/MealStore.swift`
- `Core/HealthKit/HealthKitManager.swift` 仅做授权前无可写值门禁
- 新增 `UI/Diet/MealEditorDraft.swift`
- `UI/Diet/DietView.swift`
- `Tests/MealStoreTests.swift`
- 新增 `Tests/MealNutritionProjectionTests.swift`
- 新增 `Tests/MealEditorDraftTests.swift`
- 必要时最小补充 `Tests/MealPersistenceCoordinatorTests.swift`
- 新增或最小修改 `UITests` 中的餐食持久化验收
- xcodegen 必要生成结果

禁止：

- 修改 schema、迁移、数据库 Record 或 AppEnvironment
- 改 Coordinator 的副作用顺序、SyncEngine、AI 请求/解析、模型配置
- 实现最近餐、复制、来源徽标、食品库、标签 OCR、导航或睡眠
- 引入 ViewModel、protocol、Repository、通用表单框架或新的全局单例
- 在缺少真实结果时清空 hkSyncId 或宣称 HealthKit 删除成功
- 修改 ADR/STAGE 文档、commit、tag、push

## 10. 完成标准与验证边界

- 新增/修改的定向单元测试全部通过。
- 餐食持久化 UI 测试在 iPhone 17 / iOS 26.5 Simulator 通过。
- 全量 `HealthManagerTests`、全量现有 UI smoke 与独立 build 由主架构师运行。
- `git diff --check` 通过且无范围外 diff；View 的直接写/删/HealthKit 旧路径零命中。
- Simulator 只能证明 UI、SQLite、照片状态模块和 outcome 分支；真实 HealthKit 授权、写入、删除与既有真机数据库仍为 INCOMPLETE。

## 11. 正式结果

> 由主架构师填写。

- 状态：PASS（软件与 Simulator 范围）；真实 HealthKit 授权、写入与删除：INCOMPLETE
- 验收日期：2026-07-14
- 验收 commit：本文件所在 STAGE-004B checkpoint
- 定向证据：`MealNutritionProjectionTests` 8/8、`MealEditorDraftTests` 10/10、`MealStoreTests` 12/12、`MealPersistenceCoordinatorTests` 7/7，共 37/37；结果包 `/tmp/healthmanager-stage004b-final2-targeted-20260714.xcresult`
- 全量证据：`HealthManagerTests` 162/162，结果包 `/tmp/healthmanager-stage004b-final2-full-unit-20260714.xcresult`；全部 UI tests 3/3（餐食持久化 2/2、原有 smoke 1/1），结果包 `/tmp/healthmanager-stage004b-final2-full-ui-20260714.xcresult`；独立 iPhone 17 / iOS 26.5 Simulator build succeeded，结果包 `/tmp/healthmanager-stage004b-final2-build-20260714.xcresult`
- 行为核对：已有餐次先由 `MealStore.load` 取得权威 snapshot；保存只经 Coordinator；成功后恰好通知一次并关闭，失败保留页面与草稿并显示中文字段错误；删除只经数据库 receipt 驱动的 Coordinator；手工分项已由 UI 自动化证明保存、重开与最终清理
- 数据核对：父级汇总和 Store 共用 `MealNutritionProjection`；未知值保持 nil/“—”，合法 0 与小数保留；legacy 零分项记录保持父级汇总；缺失中间照片不改变 path 顺序；取消清理集合只含本会话新照片；Store 的真实 `saveSyncId` 交错测试证明陈旧编辑不会覆盖数据库最新 id，Coordinator writer 也收到该最新 id
- HealthKit 核对：授权请求前使用共享 `MealNutritionTotals.hasWritableValue` 门禁；全 nil/0/非有限输入不会触发请求；单个 sample 仍须有限且大于 0；未新增“删除成功”假语义，也未清空既有 id
- 静态核对：`DietView` 中 `MealRecord.insert/update/deleteOne`、直接 `database.asyncWrite`、`syncNutritionToHealth`、`syncMealNutrition` 与 `display*` 零命中；仅两处 `removeIfManaged`，均由 session-created 状态或其纯值路径集合门禁；`git diff --check` 通过；Simulator 中 `uitest-*` 遗留记录为 0
- 验收修正：Coder 首稿虽编译且定向单测通过，但保存任务被自身 `isSaving` 拦截、首次 AI 无法启动、未知营养仍显示为 0、父文本覆盖分项投影、并发与照片测试不真实且 UI 2/2 失败；唯一一次集中返修后核心路径转绿。主架构师仍发现进度反馈、中文校验错误、小数展示、删除最后分项后的父汇总承接，以及 legacy/nil/完整元数据证据不足，按约定接管收口，并在最终代码上独立执行定向、全量单测、全量 UI 与 build
- 残余风险：Simulator 不能证明真实 HealthKit 授权弹窗、样本落盘、更新与删除，也不能代替真机 PhotosPicker/相机文件生命周期和既有用户数据库升级后的端到端编辑；“已同步餐次清空全部营养后可确认删除旧样本”仍无真实删除结果。上述项目全部保留为 INCOMPLETE，进入 STAGE-009 次日真机清单
