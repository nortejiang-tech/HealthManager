# STAGE-004A：餐次持久化与外部副作用编排 seam

> 状态：PASS（2026-07-14，真机 HealthKit 证据为 INCOMPLETE）
>
> 执行者：Coder；主架构师验收
>
> 前置决策：[ADR-001](../adr/ADR-001-normalized-meal-item-snapshots.md)

## 1. 唯一目标

建立可测试的餐次保存/删除编排模块，明确 SQLite、照片文件和 HealthKit 的先后顺序，并让 HealthKit 返回“真实写入”而不是仅返回一个候选 sync id。

本阶段只建立并接线 seam；`MealEditView` 真正加载/保存分项在 STAGE-004B。

## 2. 已验证问题

当前源码已确认：

- `HealthKitManager.syncMealNutrition` 在设备不可用、没有可写样本或写入失败时会返回传入的 existing id；调用方无法区分“实际写入成功”和“只是已有候选 id”。
- `DietView` 与 `SyncEngine` 都直接执行 `UPDATE meal_records SET hk_sync_id`，绕过 `MealStore`。
- 保存后的旧照片清理、HealthKit 写回和数据库保存散落在 View 中；删除路径也直接删除父记录后再清理外部资源。
- SQLite、文件系统和 HealthKit 不存在共同事务。任何声称三者原子成功的实现都是错误的。

## 3. 决策后的边界

### 3.1 HealthKit 写入结果

在 `HealthKitManager` 中引入显式、可比较且可发送的结果类型，语义至少为：

- `written(syncID:)`：本次确实向 HealthKit 保存了 correlation 或 samples。
- `notWritten`：设备不可用、没有获准且有效的样本，或所有写入尝试失败。

`syncMealNutrition` 只在 `store.save` 实际成功后返回 `written`。existing id 仍用于删除重写和幂等标记，但它本身不构成成功证据。

### 3.2 MealStore 元数据入口

为已出现的真实用例增加一个窄入口：按 meal id 记录非空 HealthKit sync id，返回更新后的 `MealRecord`。

- id 不存在：复用显式 `mealNotFound(id)`。
- trim 后 sync id 为空：新增显式错误；不得写空字符串。
- 只更新 `hk_sync_id`，不替换 children、不重算 totals、不改变照片、备注或时间。

### 3.3 MealPersistenceCoordinator

新增具体 `MealPersistenceCoordinator`；不创建 protocol。生产环境使用 `MealStore`、`HealthKitManager` 和 `MealPhotoStore`，测试通过窄 closure 注入外部副作用。

保存顺序固定为：

1. 把全部 `MealItemDraft` 转成 Store input；任一草稿校验失败时尚未发生数据库/文件/HealthKit 副作用。
2. 调用 `MealStore.save`，父餐次和分项先在 SQLite 中原子提交。
3. 数据库成功后，删除 original photo paths 中已不再被保存快照引用的文件。
4. 使用 `MealStore.save` 返回的父餐次（不是调用前 record）写 HealthKit，确保保守汇总投影生效。
5. 只有结果为 `written(syncID:)` 时才调用 MealStore 记录 id；结果为 `notWritten` 时保持原数据库 id 状态，供后续 catch-up 重试。

删除顺序固定为：

1. 调用 `MealStore.delete` 得到删除前 receipt；不存在则不做外部副作用。
2. SQLite 删除成功后清理 receipt 中的照片。
3. receipt 有 `hkSyncId` 时 best-effort 删除对应 HealthKit 样本。

SQLite 是本地事实源。数据库成功后外部清理失败不回滚数据库，也不得伪造外部成功；日志和次日真机验证承担剩余可观察性。

## 4. 生产接线

- `AppEnvironment` 构造并持有同一个 `MealStore` 与 `MealPersistenceCoordinator`，并把该 Store 传给 `SyncEngine`。
- `SyncEngine` catch-up 只在 `written` 后通过 MealStore 记录 id；记录失败不能计入 synced 数量。
- 当前 `DietView.syncNutritionToHealth` 仅做最小编译/语义适配：只处理 `written`，并用 `environment.mealStore` 写 id。完整替换为 Coordinator 属于 STAGE-004B。
- 完成本阶段后，`DietView` 和 `SyncEngine` 不再出现直接更新 `hk_sync_id` 的 SQL。
- Coordinator 不负责 `notifyLocalDataChanged()`；调用 UI 在数据库成功后通知，避免把 AppEnvironment 反向注入模块。

## 5. 自动化证据

至少覆盖：

1. MealStore 记录 sync id 后，父记录除 id 外字段和全部 children 保持不变。
2. 缺失 meal id 与空 sync id 显式失败。
3. Coordinator 保存时先完成数据库提交；外部 writer 收到 Store 投影后的父餐次。
4. 只有 `written` 才持久化 sync id；`notWritten` 保持 nil/原值。
5. 草稿校验或 Store 保存失败时，不清理照片、不调用 HealthKit writer。
6. 保存成功后只清理被移除的 original photos，保留仍引用及本次新增的 paths。
7. 删除成功返回 receipt、删除全部 receipt 照片并调用对应 HealthKit delete；不存在 id 无外部副作用。
8. 现有 MealStore 和 MealNutritionSync 测试继续通过。

测试不得复制 Store 事务或 HealthKit 结果判断；通过 Coordinator seam 和真实测试数据库观察顺序与后置条件。

## 6. 允许与禁止范围

允许：

- `Core/HealthKit/HealthKitManager.swift`
- `Core/Database/MealStore.swift`
- `Core/Sync/SyncEngine.swift`
- `App/AppEnvironment.swift`
- 新增 `UI/Diet/MealPersistenceCoordinator.swift`
- 对 `UI/Diet/DietView.swift` 做 HealthKit 返回类型和 Store id 写入的最小适配
- `Tests/MealStoreTests.swift`
- 新增 `Tests/MealPersistenceCoordinatorTests.swift`
- 必要时最小修改 `Tests/MealNutritionSyncTests.swift`
- xcodegen 必要生成结果

禁止：

- 修改迁移/schema/数据库 record
- 在本阶段让 MealEditView 加载或保存 `meal_items`
- 改照片导入、AI、导航、来源展示、最近餐或复制功能
- 创建跨 SQLite/文件/HealthKit 的伪事务或通用 Repository/protocol
- 修改 ADR/STAGE 文档、commit、tag 或 push

## 7. 完成标准与验证边界

- `MealStoreTests`、`MealPersistenceCoordinatorTests`、`MealNutritionSyncTests` 全部通过。
- 全量 `HealthManagerTests` 由主架构师独立运行。
- iPhone 17 / iOS 26.5 Simulator build 成功。
- 允许范围外无 diff；直接 `hk_sync_id` 更新 SQL 不再出现在 View/SyncEngine；`git diff --check` 通过。
- Simulator 无法证明真实 HealthKit 写入/删除，相关项保持自动化逻辑 PASS、真机证据 INCOMPLETE。

## 8. 正式结果

> 由主架构师填写。

- 状态：PASS（软件与 Simulator 范围）；真实 HealthKit 写入/删除：INCOMPLETE
- 验收日期：2026-07-14
- 验收 commit：本文件所在 STAGE-004A checkpoint
- 证据：定向 `MealStoreTests` 11/11、`MealPersistenceCoordinatorTests` 6/6、`MealNutritionSyncTests` 2/2，共 19/19；全量 `HealthManagerTests` 142/142；iPhone 17 / iOS 26.5 Simulator build succeeded；允许范围、空白检查通过；View 与 SyncEngine 中直接更新 `hk_sync_id` 的 SQL 为零命中
- 结果包：`/tmp/healthmanager-stage004a-targeted-20260714.xcresult`（定向）与 `/tmp/healthmanager-stage004a-unit-20260714.xcresult`（全量）
- 架构核对：AppEnvironment、Coordinator 与 SyncEngine 共用同一个 MealStore；保存先完成全部 draft 转换与 SQLite 原子提交，再清理照片、写 HealthKit、按显式 `written` 结果记录 sync id；返回快照反映成功写回后的真实数据库状态；删除先取得数据库 receipt，再执行文件与 HealthKit 后置副作用
- HealthKit 语义核对：设备不可用、没有获授权且有效的 samples、写入失败均返回 `notWritten`；existing/candidate id 不再构成成功证据；没有候选 samples 时不会先删除既有 HealthKit 数据；只有实际 `HKHealthStore.save` 成功后才返回 `written`
- 验收修正：Coder 首稿遗漏既有 sync id 保持、Store 失败无外部副作用和返回快照一致性证据，并产生 DietView 缩进污染；一次定向返修后补齐上述合同、`Sendable` outcome 与删除前候选样本门禁，主架构师独立执行全量测试和构建
- 残余风险：Simulator 不能证明 HealthKit 授权、真实样本落盘、删除与失败恢复，全部保留为 INCOMPLETE；MealEditView 尚未通过 Coordinator 加载/保存 `meal_items`，属于 STAGE-004B；真机既有数据库升级与照片/HealthKit 端到端路径进入 STAGE-009 次日清单
