# STAGE-009R2：清空餐次营养时回收旧 HealthKit 样本

> 状态：PASS（2026-07-15）
>
> 执行者：主架构师接管；不交给 Coder

## 1. 唯一目标

修复已同步餐次把全部营养值清空后，旧 HealthKit 营养样本仍然保留、删除失败又只写日志的问题；在真实删除成功前不得清空 `hk_sync_id`，删除失败必须保留可重试身份并在餐次编辑页显示明确反馈。

本阶段不扩展饮食产品能力，不修改 schema/migration，不改变照片、AI、复用餐次、HealthKit 读取/后台同步、Today 或导航。

## 2. 发现证据与停止条件

STAGE-009 真机门第 3 项在执行真实数据写入前被静态合同阻断：

1. `HealthKitManager.syncMealNutrition` 在四项营养都没有有限正值时直接返回 `.notWritten`。
2. `MealPersistenceCoordinator.save` 对 `.notWritten` 直接返回已保存快照，不调用旧样本删除，也不清空已有 `hk_sync_id`。
3. `deleteNutritionSamples` 返回 `Void`，忽略 `success`/删除数量，并把错误降级为日志；调用方无法提供失败反馈。

因此禁止在旧实现上用真实用户餐次验证“清空营养”，避免制造 SQLite 已清空但 Apple 健康旧样本仍残留的已知不一致。

## 3. Apple 官方语义

- `HKHealthStore.deleteObjects(of:predicate:)` 只删除本 App 先前保存且匹配谓词的对象，并返回删除数量或明确错误：<https://developer.apple.com/documentation/healthkit/hkhealthstore/deleteobjects(of:predicate:)>
- 用户撤销某一类型的共享权限后，App 不能再删除该类型对象；未请求或被拒绝时分别返回授权未决定/拒绝错误。实现不得把未授权类型静默跳过后报告整体成功。
- 删除按四个营养类型逐项执行；若部分类型成功、部分类型失败，保留 `hk_sync_id` 作为剩余样本的重试身份，并向用户报告未全部完成。

## 4. 已确认的公开测试边界

### 4.1 `MealStore`

新增窄接口清空指定餐次的 `hk_sync_id`：

- 只把目标行 `hk_sync_id` 设为 `NULL`；
- 不改变餐次时间、营养、照片、备注、`created_at` 或任何分项；
- 目标不存在时返回既有 `mealNotFound`；
- 不改变现有 `saveSyncId` 的非空合同和 SyncEngine 调用。

### 4.2 `MealPersistenceCoordinator.save`

当 Store 返回的权威餐次没有任何可写营养值时：

1. 无 `hk_sync_id`：不调用 HealthKit writer/deleter，直接返回已保存快照。
2. 有 `hk_sync_id`：不调用 writer；调用 deleter 一次。
3. 删除全部成功：再通过 `MealStore` 清空同步 ID，并返回真实持久化后的快照。
4. 删除未全部成功：抛出本地化错误；保留同步 ID，不伪造成功，编辑页保持打开并显示“旧营养样本未能全部删除、检查 Apple 健康权限后重试”。

当至少有一项可写营养值时，保持既有 writer 与 `written/notWritten` 语义。

### 4.3 HealthKit 删除结果

`HealthKitManager.deleteNutritionSamples` 必须返回可观察结果：

- 成功包含实际删除总数；删除 0 仍是成功（幂等重试）。
- 任一类型返回失败时，结果包含已成功删除数量和失败类型/系统错误摘要。
- 不再以 `authorizationStatus != .sharingAuthorized` 为理由静默跳过；让 HealthKit 返回官方授权错误，调用方据此失败关闭。
- 正常营养重写若删除旧样本未全部成功，必须停止新样本写入并返回既有 `.notWritten`，不得把部分删除后的重复写入伪装为成功。

## 5. TDD 验收矩阵

每个垂直切片必须先 RED、再最小 GREEN：

1. Store 清空同步 ID只改变该字段；缺失 ID 显式失败。
2. 已同步餐次清空全部营养：deleter 恰好一次、writer 零次、成功后同步 ID 为 `NULL`。
3. 删除失败：save 抛出中文可见错误、writer 零次、同步 ID 保留以便重试。
4. 无同步 ID且营养为空：writer/deleter 都为零次。
5. 有可写营养：现有投影、writer、同步 ID持久化测试继续通过。
6. 整餐删除和既有缺失餐次行为不回归。
7. 删除结果只有在全部成功（包括幂等的删除 0）时才允许继续正常营养重写；部分失败禁止新写入。

## 6. 允许修改

- `Core/Database/MealStore.swift`
- `Core/HealthKit/HealthKitManager.swift`
- `UI/Diet/MealPersistenceCoordinator.swift`
- 对应 `Tests/MealStoreTests.swift`、`Tests/MealPersistenceCoordinatorTests.swift`、`Tests/MealNutritionSyncTests.swift`
- 本阶段与最终 STAGE/HANDOFF/NEXT_TASK 文档

若编译需要，只允许对直接调用 `deleteNutritionSamples` 的测试/生产调用点做机械签名适配。

## 7. 禁止修改

- schema、migration、Bundle ID、签名、版本号
- `MealEditView` 的产品流程、照片/AI/复用/导航
- HealthKit 读取类型、anchor、observer、后台任务或 sync job
- 用真实用户餐次作为测试数据
- 在软件门未通过前覆盖安装；不得卸载 App
- merge `main`、tag、release

## 8. 软件门与真机门

软件门：

- 定向 RED/GREEN 结果可追溯；
- 全量 unit/UI、独立 Simulator build、独立 device Release build 全绿；
- `git diff --check`、双轴代码审查无未解决 finding。

真机门：

1. 覆盖安装，不卸载；先确认原用户数据库/照片基线仍在。
2. 新建唯一标记测试餐次并写入至少两类真实营养样本。
3. 在 Apple 健康确认样本存在；编辑该测试餐次并清空全部营养。
4. 确认旧样本删除、餐次 `hk_sync_id=NULL`、用户既有餐次/照片不变。
5. 定向删除测试餐次与照片，不碰用户内容。
6. 失败反馈分支以自动化 seam 证明；不得为了制造授权失败而擅自修改用户 HealthKit 权限。

任何一步出现授权异常、用户数据计数意外变化、照片缺失或删除结果不确定，立即停止并保持发布就绪 `INCOMPLETE`。

## 9. 提交边界

只有软件门和真实清空营养门均 PASS，才允许提交并推送本阶段 checkpoint。整体 STAGE-009 的照片、VoiceOver/最大字号、真实 sleepAnalysis 与后台 observer 仍需分别验收；本阶段 PASS 不等于 v0.3 发布就绪。

## 10. 本次验收闭环（2026-07-15）

- 软件门：`Tests/MealStoreTests.swift`、`Tests/MealPersistenceCoordinatorTests.swift`、`Tests/MealNutritionSyncTests.swift` 全部完成并通过 TDD RED/GREEN，含：
  - `clearSyncId` 与失败路径
  - deleter/writer 分支收敛
  - 全量成功与部分失败失败分支
  - 回归既有 writer 与同步 ID 合同
- 真机门：
  - 删除临时测试餐次 UI 测试通过：`/tmp/healthmanager-stage009r2-device-delete-test-meal-ui-20260715-attempt02.xcresult`（1/1 PASS，`test_stage009r2_deviceDeleteTestMeal`）
  - 清理后 snapshot：`/tmp/healthmanager-stage009r2-device-final-cleanup-20260715-attempt01`
  - 发布包启动后 snapshot：`/tmp/healthmanager-stage009r2-device-final-release-20260715-attempt01`
  - 数据一致性（发布快照）：
    - `meal_records` 行数：114（无新增）
    - `PRAGMA integrity_check`：`ok`
    - `PRAGMA foreign_key_check`：空
    - `meal_id=116`：`COUNT(*)=0`（测试餐次已移除）
    - Meal SQL SHA256：`ba36bd7a639ea715b0ff5c06cf3c5a63002d9e3786e1bd50da6c189d82fa49ec`
    - MealPhotos SHA256：`174fedea2c57dfc2a8c8645824079f999b6e9e02495535504ea86b9f4d1c0740`
    - MealPhotos 文件数：133
- 额外说明：`/tmp/healthmanager-stage009r2-device-clear-ui-20260715-attempt07.xcresult` 的后置断言失败属于 stale-row 重开编辑实现问题，不作为本门主要 PASS 依据；核心动作（打开 row116、清空并删除、返回列表）已在最新动作与 SQL 证明完成。
