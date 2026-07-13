# 给 Coder 的提示词：STAGE-004A MealPersistenceCoordinator

## 任务开始

只执行 HealthManager `STAGE-004A`。不要读取记忆库、竞品报告或无关 skill；完整阅读：

- `docs/adr/ADR-001-normalized-meal-item-snapshots.md`
- `docs/stages/STAGE-004A-meal-persistence-coordinator.md`
- `Core/Database/MealStore.swift`
- `UI/Diet/MealItemDraft.swift`
- `Core/HealthKit/HealthKitManager.swift` 的 nutrition write-back
- `Core/Sync/SyncEngine.swift` 的 `pushMealNutritionToHealth`
- `App/AppEnvironment.swift`
- `UI/Diet/DietView.swift` 的 save/delete/`syncNutritionToHealth`
- `Tests/MealStoreTests.swift`
- `Tests/MealNutritionSyncTests.swift`

先确认分支为 `codex/health-planning-20260713`、历史包含 STAGE-003 checkpoint `1b545a3`，HEAD 只比它多一个 STAGE-004A 文档 checkpoint且工作区干净；不符则停止。

目标：建立可测试的 `MealPersistenceCoordinator`，并把 HealthKit nutrition 写回改为显式 `written(syncID:) / notWritten`；不要在本阶段把编辑页切换到分项加载/保存。

按 TDD 纵向实现：先扩展 MealStore 元数据测试和 Coordinator 行为测试并看到因能力缺失而失败，再实现窄 Store 方法、显式 HealthKit outcome、Coordinator，最后做 AppEnvironment/SyncEngine/当前 View 的最小编译接线。

关键合同：

- `HealthKitManager.syncMealNutrition` 只有 `HKHealthStore.save` correlation 或 samples 成功才返回 `written`；不可用、无样本、失败均为 `notWritten`。候选/existing id 不是成功。
- MealStore 新方法只记录 trim 后非空 sync id；missing id 与 blank id 显式失败，不触碰 children 或其他父字段。
- Coordinator save 必须先把全部 draft 转 input，再 `MealStore.save`；数据库成功后才清理已移除照片、调用 HealthKit；writer 必须收到 Store 返回的投影 meal。
- 只有 `written` 才记录 id；`notWritten` 不伪造。元数据记录失败只日志，不反向声称外部没写，也不回滚已成功的主保存。
- Coordinator delete 必须先取得 Store 删除 receipt，再清理 receipt 照片与 HealthKit；missing id 不触发外部 closure。
- 生产 convenience init 可把 `HealthKitManager`/`MealPhotoStore` 适配成 closure；测试直接注入窄 closure。不要创建 protocol 或通用 Repository。
- AppEnvironment 创建一个 MealStore，并让 Coordinator 与 SyncEngine 共用；Coordinator 不注入 AppEnvironment、不负责 notify。
- SyncEngine 和当前 View 只在 `written` 后用 MealStore 记录 id，移除直接 `UPDATE ... hk_sync_id` SQL。View 其他保存/删除逻辑暂不改，STAGE-004B 再接 Coordinator。

允许修改仅限任务书第 6 节文件。禁止迁移/schema/record、分项 UI 加载保存、照片导入、AI、导航、docs 和 Git 操作；遇到范围冲突就停止报告。

目标测试至少证明：Store 窄更新不碰 children；written/notWritten；先 DB 后外部；失败无副作用；照片差集；delete receipt/missing id。不要用“必定成功”断言，不复制生产分支。

运行并报告：

    xcodegen generate
    xcodebuild -project HealthManager.xcodeproj -scheme HealthManager -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -only-testing:HealthManagerTests/MealStoreTests -only-testing:HealthManagerTests/MealPersistenceCoordinatorTests -only-testing:HealthManagerTests/MealNutritionSyncTests test
    xcodebuild -project HealthManager.xcodeproj -scheme HealthManager -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' build
    rg -n 'UPDATE meal_records SET hk_sync_id' UI/Diet/DietView.swift Core/Sync/SyncEngine.swift
    git diff --check
    git status --short

不要跑全量测试（主架构师独立运行），不要提交，不要继续 STAGE-004B。最终只列候选状态、TDD red/green、改动文件、目标测试数量、未验证真机边界和 git status。

## 任务结束
