# 给 Coder 的提示词：STAGE-004B 餐食分项编辑器真实接入

## 任务开始

只执行 HealthManager `STAGE-004B`。不要读取记忆库、竞品报告或无关 skill；完整阅读：

- `docs/adr/ADR-001-normalized-meal-item-snapshots.md`
- `docs/stages/STAGE-004B-meal-editor-integration.md`
- `Core/Database/MealStore.swift`
- `Core/HealthKit/HealthKitManager.swift` 的 nutrition write-back
- `UI/Diet/MealItemDraft.swift`
- `UI/Diet/MealPersistenceCoordinator.swift`
- `UI/Diet/DietView.swift`
- `Tests/MealStoreTests.swift`
- `Tests/MealPersistenceCoordinatorTests.swift`
- `UITests/SmokeTests.swift`

先确认分支为 `codex/health-planning-20260713`、历史包含 STAGE-004A checkpoint `28983b9`、当前 HEAD 为本任务书 checkpoint `17d67af` 且工作区干净；不符则停止。

目标：让编辑页安全加载、保存、重开和删除规范化 meal items，并把未知值、照片 path、保存失败与最新 hkSyncId 保持为真实状态。不要做 STAGE-005 或视觉/导航扩展。

严格按任务书第 3–7 节实现。核心形状固定如下：

1. 新增纯值 `MealNutritionProjection` + `MealNutritionValues` + `MealNutritionTotals`。空 items 返回 nil；非空按单指标保守求和；Store 与 editor 共用，View/测试不得复制规则。totals 提供至少一个有限正值的 HealthKit 门禁。
2. `MealStore.save` 更新已有 meal 时在同一事务读取当前 row，并始终保留数据库当前 `hkSyncId`；只有 `saveSyncId` 管理该元数据。先写交错回归测试。
3. 新增纯值 `MealEditorDraft`，由 View 以 `@State` 持有；不要 ViewModel。它封装 snapshot apply、父汇总解析、共享投影、record 构造和历史 id/createdAt/hkSyncId 保留。
4. 新增按 path 绑定的 `MealPhotoDraft`，optional image 允许缺失占位，记录是否本会话新增。替换图片/路径并行数组；AI 只处理有 image 的照片；取消只清理 session-created 文件。
5. 已有 meal 从一开始 loading，只有 `mealStore.load` 成功才可保存；缺 id/not found/read error 可见且不可保存。新建直接 ready。
6. 保存按钮同步设置 saving 后再创建 Task；busy 时不可重复。只调用 Coordinator；成功通知一次再 dismiss，失败留在页面并显示错误。删除只调用 Coordinator receipt 路径。
7. 分项 Section 始终可见并支持第一个手工项；有分项时父汇总只读。未知显示“—”而非 0，小数不截断，非法字段不静默变 nil。
8. `syncMealNutrition` 在授权请求前对全 nil/0 输入直接 `notWritten`。不要新增“删除成功”语义，不清空 hkSyncId。
9. 用稳定 accessibility identifiers 实现两个 UI 场景：非法父汇总保存不关闭；唯一备注的手工分项保存后重开仍显示原名称/克数并清理该测试记录。

照片异步纪律：照片导入、AI、加载或保存期间禁止相关冲突动作；有未提交 session photos 时禁止手势关闭，Cancel 必须显式清理后关闭。缺失旧图片保留 path 和占位，不按 index 错配、不自动删数据库引用。

按 TDD 纵向推进：先写 projection/Store race/editor/photo 测试并看到能力缺失的 red；再实现纯模块与 Store；最后接 UI 并运行 UI test。不要把编译错误伪装成有意义的 red，不要降低断言通过。

允许修改仅限任务书第 9 节。不得改 docs、迁移/Record、AppEnvironment、Coordinator 顺序、SyncEngine、AI/导航；遇到范围冲突停止报告。

运行并报告：

    xcodegen generate
    xcodebuild -project HealthManager.xcodeproj -scheme HealthManager -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -only-testing:HealthManagerTests/MealNutritionProjectionTests -only-testing:HealthManagerTests/MealEditorDraftTests -only-testing:HealthManagerTests/MealStoreTests -only-testing:HealthManagerTests/MealPersistenceCoordinatorTests test
    xcodebuild -project HealthManager.xcodeproj -scheme HealthManager -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -only-testing:HealthManagerUITests/MealPersistenceUITests test
    xcodebuild -project HealthManager.xcodeproj -scheme HealthManager -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' build
    rg -n 'MealRecord\.(insert|update|deleteOne)|syncNutritionToHealth|syncMealNutrition|removeIfManaged' UI/Diet/DietView.swift
    git diff --check
    git status --short

不要跑全量单元/全量 UI（主架构师独立运行），不要提交，不要进入 STAGE-005。最终只列候选状态、真实 red/green、各套测试准确数量与 xcresult、变更文件、已知未验证边界和 git status；不得自行宣布架构 PASS。

## 任务结束
