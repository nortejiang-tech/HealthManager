# 给 Coder 的提示词：STAGE-003 MealItemDraft

## 任务开始

只执行 HealthManager `STAGE-003`。不要读取记忆库、竞品报告或无关 skill；完整阅读：

- `docs/adr/ADR-001-normalized-meal-item-snapshots.md`
- `docs/stages/STAGE-003-meal-item-draft.md`
- `Core/LLM/MealNutritionAnalyzer.swift` 中 `Item/Estimate`
- `Core/Database/Models/MealItemRecord.swift`
- `Core/Database/MealStore.swift`
- `UI/Diet/DietView.swift` 中 `MealEditView`、`AnalysisJob`、`EditableNutritionItem`
- `Tests/NutritionItemDedupTests.swift`

先确认分支为 `codex/health-planning-20260713`、历史包含 STAGE-002 checkpoint `66ee696`，HEAD 只比它多一个由主架构师创建的 STAGE-003 文档 checkpoint，且工作区干净；若起点或改动范围不符则停止。

目标：按任务书把 View 内的 `EditableNutritionItem` 抽成独立 `MealItemDraft` 值类型，建立 AI/快照/手工来源到 `MealStore.ItemInput` 的单一映射 seam；不接分项数据库读写。

按 TDD 纵向切片：先写最小行为测试并确认因缺少新类型/能力而失败，再实现 AI 映射与未知值；随后完成缩放、修订标记、显式克数校验、快照往返和 dedup 迁移。测试从草稿公开行为观察结果，不重写一份生产映射算法。

关键要求：

- 新文件放在 `UI/Diet/MealItemDraft.swift`；不要创建 protocol、Repository 或全局单例。
- 可空 grams/macros 必须保留；不要延续旧类型的 100g/0 默认值。
- Store 映射使用一个会抛出显式校验错误的入口：空克数为 nil；非空值只有有限且 > 0 才合法。
- 合法克数变化只缩放已知指标，nil 指标仍为 nil；没有 baseline grams 时不猜比例。
- AI confidence 只归一化 low/medium/high；每个 AI 分项保存 `.aiEstimate`、本次 confidence 和任务创建时捕获的 text/vision model 名称，绝不保存 Base URL/API key。
- 非手工候选的 name/gramsText 实际变化后 `isUserEdited=true`；相同赋值不算，手工输入保持 false。
- 快照映射保留 preparation/source/ref/version/confidence/createdAt；child id、meal_id、sort_order、updated_at 不由草稿控制。
- DietView 只做类型替换、AI 元数据传入和显示字段适配；现有并发、照片、父餐次保存与 HealthKit 代码不改语义。
- 删除 `DietView.swift` 内旧 `EditableNutritionItem` 定义，现有五条 dedup 测试迁移到新类型。

允许修改：

- `UI/Diet/MealItemDraft.swift`
- `UI/Diet/DietView.swift`
- `Tests/MealItemDraftTests.swift`
- `Tests/NutritionItemDedupTests.swift`
- xcodegen 必要生成结果

禁止修改迁移、数据库模型、MealStore、DatabaseManager、照片、HealthKit、AI 请求/解析、导航、docs 和 Git 历史。遇到接口无法在该范围内实现时停止并报告，不要自行扩范围。

运行并简要报告：

    xcodegen generate
    xcodebuild -project HealthManager.xcodeproj -scheme HealthManager -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -only-testing:HealthManagerTests/MealItemDraftTests -only-testing:HealthManagerTests/NutritionItemDedupTests test
    xcodebuild -project HealthManager.xcodeproj -scheme HealthManager -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' build
    git diff --check
    git status --short

不要运行全量测试（主架构师独立运行），不要提交，不要继续 STAGE-004。最终只列：候选状态、TDD red/green 证据、改动文件、目标测试结果、未验证边界、git status。

## 任务结束
