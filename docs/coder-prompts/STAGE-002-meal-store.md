# 给 Coder 的提示词：STAGE-002 MealStore

## 任务开始

只执行 HealthManager `STAGE-002`。不要读取记忆库、竞品报告或无关 skill；完整阅读：

- `docs/adr/ADR-001-normalized-meal-item-snapshots.md`
- `docs/stages/STAGE-002-meal-store.md`
- `Core/Database/DatabaseManager.swift`
- `Core/Database/Models/MealRecord.swift`
- `Core/Database/Models/MealItemRecord.swift`
- `Tests/MealItemMigrationTests.swift`

先确认分支为 `codex/health-planning-20260713`、提交历史包含 STAGE-001 checkpoint `d469db8`、工作区干净；允许其后只有主架构师的规划提交，否则停止。

目标：按 STAGE 文档建立具体 `MealStore`，只有 `load/save/delete` seam；不创建 protocol，不接 UI/HealthKit/照片。

按 TDD 纵向切片：先写一个 `MealStoreTests` 行为测试并确认因缺少能力而失败，再写最小实现；逐个完成新建、投影、未知值、编辑替换、事务回滚、缺失 id、删除回执。测试必须从 Store 接口观察行为，不复制持久化逻辑。

关键要求：

- save 输入分项不能要求调用方提供 id/meal_id/sort_order。
- 分项按数组下标排序，名称 trim；时间使用可注入 Unix 秒时钟且一次 save 只取一次。
- 分项非空时，每个宏量指标分别执行“全部已知才求和，否则 nil”；分项为空保留父汇总。
- 父更新、旧 child 删除、新 child 插入同一事务；非法 child 必须证明完整回滚。
- delete 返回删除前快照，只做 SQLite。
- 只允许新 Store、Store tests、必要 Sendable/生成文件；禁止迁移、UI、Sync、AI、docs 和 Git 提交。

运行并简要报告：

    xcodegen generate
    xcodebuild -project HealthManager.xcodeproj -scheme HealthManager -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -only-testing:HealthManagerTests/MealStoreTests test
    xcodebuild -project HealthManager.xcodeproj -scheme HealthManager -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' build
    git diff --check
    git status --short

不要运行全量测试（主架构师独立运行），不要提交，不要继续 STAGE-003。最终只列：候选状态、改动文件、测试结果、未验证边界、git status。

## 任务结束
