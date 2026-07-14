# STAGE-005A：餐食历史复用语义内核

> 状态：PASS（软件与 Simulator 范围；STAGE-004B checkpoint `ccbfb15`）
>
> 执行者：Coder；主架构师验收
>
> 前置决策：[ADR-001](../adr/ADR-001-normalized-meal-item-snapshots.md)

## 1. 唯一目标

在不新增数据库表、不接 UI 的前提下，为 `MealStore` 增加最近餐、常用克数和整餐/选中分项复制的窄接口，并把复制定义为“生成一个尚未保存的新餐草稿”，而不是直接写库。

本阶段只建立低摩擦复用的查询与复制语义；入口、选择界面和编辑器接线属于 STAGE-005B。

## 2. 产品边界

竞品的价值不是“功能数量”，而是让重复餐更快完成。HealthManager 只采用与自身需求一致的部分：

- 历史数据仍是稳定快照，复制不能回写或改动来源餐。
- 用户必须在编辑器确认并显式保存；查询和复制本身无数据库、照片或 HealthKit 副作用。
- 复用食物与营养快照，不复制历史照片、备注、数据库 id、HealthKit 同步 id 或旧创建时间。
- 不做收藏、模板、食品目录、份量单位、条码/OCR、跨餐移动或自动保存。

## 3. 模块与接口

继续使用现有具体 `MealStore`；不新建 Repository、protocol 或第二套数据库访问层。允许新增 `Core/Database/MealReuseModels.swift`，用 `MealStore` 的嵌套值类型表达：

- `CopySelection`：`.wholeMeal` 或一组持久化 child id。
- `CopyDraft`：一个新父 `MealRecord` 和按保存接口表达的 `[MealStore.ItemInput]`。
- `CommonGramSuggestion`：克数、历史使用次数和最后使用时间。
- `ReuseError`：至少区分空选择和不存在的 child id；缺失 id 按升序返回，便于稳定测试与错误展示。

`MealStore` 增加三个窄入口，命名可以按 Swift 风格微调，但行为不能改变：

1. `recentSnapshots(limit:excludingMealId:)`
2. `commonGramSuggestions(forName:preparationState:limit:)`
3. `makeCopyDraft(from:selection:targetMealType:eatenAt:)`

名称规范化必须有一个 Core 层唯一规则源，例如 `MealItemIdentity.canonicalName(_:)`；现有 `MealItemDraft.normalizedName` 只委托给它，不能让历史查询与 UI 去重各保留一套算法。

## 4. 最近餐查询合同

- `limit <= 0` 返回空；正数最多取 50，避免 UI 参数导致无界结果。
- 先排除 `excludingMealId`，再应用 limit。
- 父餐次按 `eaten_at DESC, id DESC` 稳定排序；包含 0 个分项的 legacy 餐次。
- 每个 snapshot 的 children 按 `sort_order` 排序。
- 父与全部 children 必须在同一个一致性 read 中读取；使用一次父查询和一次批量 child 查询，不得为每餐循环查询。
- 查询不得修改数据库，也不得触发照片、HealthKit 或通知。

## 5. 常用克数合同

- 名称按同一 canonical 规则比较：去掉 Unicode 空白并做大小写归一；空名称返回空结果。
- `preparationState == nil` 表示不过滤备餐状态；非 nil 时只统计完全相同状态。
- 只统计有限且大于 0 的非空克数；同一个精确 `Double` 值为一个候选，不做平均、区间合并或隐式四舍五入。
- 每个历史 item occurrence 计一次。排序依次为：使用次数降序、最后使用时间降序、克数升序。
- `limit <= 0` 返回空；正数最多返回 10 个候选。
- item 与其父餐时间在一个一致性 read 中批量取得，不得 N+1。

不用平均值是刻意决策：平均会生成用户从未使用过的份量，违背“复用本人确认过的数据”。

## 6. 复制合同

### 6.1 共同规则

- 输入是一个 `MealStore.Snapshot`；输出只是一份 `CopyDraft`，不调用 `save`。
- 新父餐次使用调用方明确提供的 `targetMealType` 与 `eatenAt`。
- 新父餐次 `id/photoPath/notes/hkSyncId` 均为 nil；`createdAt` 只读取一次 Store 的 `now` 并使用新值。
- 复制分项保持来源顺序，并保留 name、grams、preparation、四项可空营养、provenance kind/ref/version、confidence 和 `isUserEdited`。
- 新分项的 `createdAt` 必须为 nil，让之后真正保存时生成新快照时间；不得沿用来源 child id、meal id、sort order 或旧时间戳。
- 未知值继续为 nil，合法 0 继续为 0。

### 6.2 整餐

- 有分项时复制全部分项，并通过共享 `MealNutritionProjection` 重新得到父汇总，不盲信可能陈旧的父字段。
- 0 分项 legacy 餐次复制原父级四项可空汇总，以继续支持历史快速记录。

### 6.3 选中分项

- 选择使用持久化 child id；空集合显式失败。
- 任一请求 id 不在 snapshot 中时整体失败，不得静默部分复制。
- 输出按来源 `sort_order`，而不是 Set 或用户点选顺序。
- 父汇总只由被选中的分项通过共享投影计算；不得混入来源餐未选择的父汇总。

## 7. 自动化证据

新增 `MealReuseTests`，至少覆盖：

1. canonical 名称规则与现有 dedup 共用同一入口，ASCII/全角/换行等空白和大小写得到稳定结果。
2. 最近餐排序、排除后 limit、legacy 0 分项、child 顺序和非正 limit。
3. 常用克数按次数/最近时间/克数稳定排序；名称归一、可选备餐过滤、未知与非正 limit。
4. 整餐复制生成全新的父身份，清空照片/备注/HealthKit，保留全部分项事实和来源元数据，使用一次新时钟，并保持来源 snapshot 不变。
5. 有未知指标的分项复制仍按保守投影得到 nil；合法 0 不丢失。
6. legacy 0 分项整餐复制保留父级小数、0 与 nil。
7. 选中分项按来源顺序复制，只投影所选项；空选择和未知 id 均显式失败且缺失列表稳定。
8. 查询和 make-copy 前后原餐数量、内容和同步 id 不变，证明接口本身无写入副作用。

测试必须通过生产接口组装结果；不得在测试中重新实现排序、名称规范化或父汇总算法。

## 8. 允许与禁止范围

允许：

- 新增 `Core/Database/MealReuseModels.swift`
- `Core/Database/MealStore.swift`
- `UI/Diet/MealItemDraft.swift` 仅把名称规范化委托给 Core 规则
- 新增 `Tests/MealReuseTests.swift`
- 必要时最小修改 `Tests/NutritionItemDedupTests.swift`
- xcodegen 必要生成结果

禁止：

- 修改任何 schema、迁移、数据库 Record 或 `DatabaseManager`
- 修改 `DietView`、`MealEditorDraft`、Coordinator、AppEnvironment、照片、HealthKit、SyncEngine 或 AI
- 新增 UI、收藏/模板/食品库/来源展示/导航
- 自动保存复制结果或复制照片、备注、历史 id/时间戳
- 引入 protocol、Repository、缓存、全局单例或第二套名称/汇总规则
- 修改 ADR/STAGE 文档、commit、tag 或 push

## 9. 完成标准与验证边界

- `MealReuseTests`、`MealStoreTests` 与 `NutritionItemDedupTests` 全部通过。
- 全量 `HealthManagerTests` 由主架构师独立运行。
- iPhone 17 / iOS 26.5 Simulator build 成功。
- `git diff --check` 通过且 diff 只有允许文件。
- 静态核对查询没有 N+1，复制路径没有 `save`、照片、HealthKit 或通知调用。
- 本阶段不验证 UI 完成时间、交互选择、保存后重开、HealthKit 或真机。

## 10. 正式结果

> 由主架构师填写。

- 状态：PASS（软件与 Simulator 范围）
- 验收日期：2026-07-14
- 验收 commit：本文件所在 STAGE-005A checkpoint
- 定向证据：`MealReuseTests` 10/10、`MealStoreTests` 12/12、`NutritionItemDedupTests` 6/6，共 28/28；结果包 `/tmp/healthmanager-stage005a-architect-targeted-final-20260714.xcresult`
- 全量证据：`HealthManagerTests` 173/173；结果包 `/tmp/healthmanager-stage005a-full-unit-20260714.xcresult`；独立 iPhone 17 / iOS 26.5 Simulator build succeeded，结果包 `/tmp/healthmanager-stage005a-build-20260714.xcresult`
- 行为核对：最近餐先排除再限量，父级按 `eaten_at DESC, id DESC`、children 按 `sort_order`；常用克数只统计完全相同的有限正数，并按次数、最近时间、克数稳定排序；整餐与选中分项复制均只生成未保存草稿，按来源 `sort_order` 保留完整营养与来源事实，清空父级身份、照片、备注及 HealthKit id，错误路径不读取时钟
- 数据与副作用核对：新增持久化前后测试直接比较数据库父餐数量、原 snapshot 与 `hkSyncId`，查询及 make-copy 前后完全不变；legacy 零分项父级小数、合法 0 与 nil 均保留；有分项时父汇总只经共享 `MealNutritionProjection` 计算，任一未知指标继续为 nil
- 静态核对：`recentSnapshots` 在同一 `asyncRead` 中执行一次父查询和至多一次批量 child 查询；`commonGramSuggestions` 在同一 `asyncRead` 中执行一次 item 查询和一次批量父查询；两者均无循环查询。新增三个入口没有 `asyncWrite`、`save`、照片、HealthKit 或通知调用；名称规范化只有 `MealItemIdentity.canonicalName` 一个规则源；`git diff --check` 通过，范围仅含本阶段白名单文件与本验收结果
- 验收修正：Coder 初稿和唯一一次集中修复完成了主体实现并使其自报定向测试通过，但主架构师复核仍发现缺少“查询与复制不改变持久化数量、内容和同步 id”的合同证据，遂按约定接管补齐；首次补测因在 `XCTUnwrap` autoclosure 内直接 `await` 编译失败，拆分异步读取与 unwrap 后在最终代码上独立重跑定向、全量单测与 build，全部通过
- 残余风险：本阶段未接 UI，因而不证明入口、选择交互、编辑确认与最终保存；这些属于 STAGE-005B。查询当前按个人本地数据库规模批量读取候选 item 后在内存执行 canonical 比较，避免了 schema/迁移扩张，但若未来数据规模显著增长，应以真实 profile 决定是否增加可索引规范化字段。真实 HealthKit、PhotosPicker/相机和既有真机数据库仍按总计划保留为 INCOMPLETE
