# 给 Coder 的提示词：STAGE-005A 餐食历史复用内核

## 任务开始

只执行 HealthManager `STAGE-005A`。不要读取记忆库、重新做竞品研究或处理相邻阶段；完整阅读：

- `docs/adr/ADR-001-normalized-meal-item-snapshots.md`
- `docs/stages/STAGE-005A-meal-reuse-core.md`
- `Core/Database/MealStore.swift`
- `Core/Database/MealNutritionProjection.swift`
- `Core/Database/Models/MealRecord.swift`
- `Core/Database/Models/MealItemRecord.swift`
- `UI/Diet/MealItemDraft.swift`
- `Tests/MealStoreTests.swift`
- `Tests/NutritionItemDedupTests.swift`

先确认：

1. 分支是 `codex/health-planning-20260713`。
2. `git merge-base --is-ancestor ccbfb15 HEAD` 成功。
3. 从 `ccbfb15` 到当前 HEAD 只多出本阶段的 `docs/stages/STAGE-005A-meal-reuse-core.md` 与 `docs/coder-prompts/STAGE-005A-meal-reuse-core.md`。
4. 工作区干净。

任一不成立就停止并报告，不要修复基线。

目标：只建立最近餐、常用克数和整餐/选中分项复制的查询与纯草稿语义；不接 UI，不保存复制结果。

按 TDD 纵向切片执行：先写 `MealReuseTests` 并保留一次因接口不存在而失败的 red 证据，再依次实现名称唯一规则、最近餐、常用克数、整餐复制和选中分项复制。测试从生产接口观察，不复制一套生产排序/投影算法。

关键合同：

- 继续深化具体 `MealStore`；不要创建 protocol、Repository、第二个 Store、缓存或全局单例。
- 可新增 `Core/Database/MealReuseModels.swift`，用 `MealStore` 嵌套值类型表达 `CopySelection`、`CopyDraft`、`CommonGramSuggestion`、`ReuseError`。
- `recentSnapshots(limit:excludingMealId:)`：非正 limit 返回空，正数 cap 50；排除后再 limit；父按 `eaten_at DESC, id DESC`，children 按 `sort_order`；同一 read 内一次父查询加一次批量 child 查询，禁止 N+1；包含零分项 legacy 餐。
- 名称 canonical 规则只有一个 Core 实现：移除 Unicode 空白并小写；空结果视为空名称。`MealItemDraft.normalizedName` 只委托该规则，不能保留旧算法副本。
- `commonGramSuggestions(forName:preparationState:limit:)`：nil preparation 不过滤，非 nil 精确过滤；只统计有限且 > 0 的 grams；相同精确 Double 聚合；按次数降序、最后使用时间降序、克数升序；非正 limit 为空，cap 10；父时间批量读取，不得 N+1，不算平均值。
- `makeCopyDraft(from:selection:targetMealType:eatenAt:)` 只构造值，不调用 `save`。新 parent 使用目标餐次/时间，id、photoPath、notes、hkSyncId 为 nil，createdAt 从注入 clock 只取一次。
- 复制 item 保持来源 sort order，保留 name/grams/preparation/macros/provenance ref/version/confidence/isUserEdited；新 `ItemInput.createdAt=nil`，不沿用 child id、meal id、sort order、created/updated 时间。
- 整餐有 items 时用共享 `MealNutritionProjection` 生成父汇总；零 items legacy 餐保留原父汇总。
- 选中项使用 child id Set；空集合抛显式错误；任一 id 不存在时整体失败并返回升序缺失 id；输出仍按来源顺序；父汇总只投影所选项。
- 查询和 copy builder 都不得写数据库、触发照片、HealthKit、通知或 AI。

允许修改：

- `Core/Database/MealReuseModels.swift`
- `Core/Database/MealStore.swift`
- `UI/Diet/MealItemDraft.swift` 仅名称规范化委托
- `Tests/MealReuseTests.swift`
- `Tests/NutritionItemDedupTests.swift` 的最小共享规则证据
- xcodegen 必要生成结果

禁止修改迁移、数据库 Record、DatabaseManager、DietView、MealEditorDraft、Coordinator、AppEnvironment、照片、HealthKit、SyncEngine、AI、导航和 docs。不要提交、tag 或 push。若合同在允许范围内无法实现，停止并说明具体阻塞，不要扩大范围。

运行并简要报告：

    xcodegen generate
    xcodebuild -project HealthManager.xcodeproj -scheme HealthManager -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -only-testing:HealthManagerTests/MealReuseTests -only-testing:HealthManagerTests/MealStoreTests -only-testing:HealthManagerTests/NutritionItemDedupTests test
    xcodebuild -project HealthManager.xcodeproj -scheme HealthManager -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' build
    git diff --check
    git status --short

不要运行全量测试（主架构师会独立运行），不要继续 STAGE-005B。最终只列：候选状态、TDD red/green 证据、改动文件、定向测试和 build 结果、未验证边界、git status。

## 任务结束
