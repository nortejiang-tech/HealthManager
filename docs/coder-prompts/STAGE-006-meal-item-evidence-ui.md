# 给 Coder 的提示词：STAGE-006 餐食来源与证据呈现

## 任务开始

只执行 HealthManager `STAGE-006`。不要读取记忆库、重新做竞品研究或继续相邻阶段；完整阅读：

- `docs/adr/ADR-001-normalized-meal-item-snapshots.md`
- `docs/stages/STAGE-005B-meal-reuse-ui.md`
- `docs/stages/STAGE-006-meal-item-evidence-ui.md`
- `Core/Database/Models/MealItemRecord.swift`
- `UI/Diet/MealItemDraft.swift`
- `UI/Diet/DietView.swift`
- `Tests/MealItemDraftTests.swift`
- `Tests/MealEditorDraftTests.swift`
- `UITests/MealPersistenceUITests.swift`
- `UITests/MealReuseUITests.swift`
- `UITests/SmokeTests.swift`

先确认：

1. 分支是 `codex/health-planning-20260713`。
2. `git merge-base --is-ancestor f21589f HEAD` 成功。
3. 从 `f21589f` 到当前 HEAD 只多出本阶段的 `docs/stages/STAGE-006-meal-item-evidence-ui.md` 与 `docs/coder-prompts/STAGE-006-meal-item-evidence-ui.md`。
4. 工作区干净。

任一不成立就停止并报告，不要修复基线。

唯一目标：把现有 item 级来源、引用、版本、置信、修订、备餐状态和四项营养字段覆盖，以“默认紧凑、按需展开”的方式接入每个餐食分项；只展示已保存事实，不生成质量分或准确性结论。

按 TDD 纵向切片执行：先新增 `MealItemEvidencePresentationTests` 并保存 red 证据，再实现纯 presentation；随后实现聚焦 evidence view 并嵌入 editor；最后扩展现有手工 item UI round-trip，保存展开截图并验证 UI 定向清理。不要先写大段 View 再补测试。

关键合同：

- 新建 `UI/Diet/MealItemEvidenceView.swift`，其中纯值 `MealItemEvidencePresentation` 是所有中文映射、引用/版本 trim、覆盖统计、风险说明和 accessibility 摘要的唯一规则源。它不依赖 Color、Store、数据库、环境对象或 SwiftUI 状态，可直接单测。
- 四类来源标题固定为：手工录入、AI 估算、营养数据库、包装标签。confidence 只显示现有 low=低、medium=中、high=高；不生成百分比或“准确/验证/权威”结论。
- `.manual` 且 confidence=nil 时紧凑行不显示置信徽标，详情写“不适用（手工录入）”；AI/database/label 缺失时显示“置信未提供”。异常历史 manual 若确有 confidence，不能隐藏保存事实。
- `isUserEdited=true` 时显示“已人工修订”；false 时展开详情仍要准确区分“原始手工录入”与“未人工修订”。不伪造修订时间、字段或操作者。
- preparation 映射 unknown=未标注、raw=生重、cooked=熟重，只展示不编辑。
- “营养字段：N/4 已记录”只按 calories/protein/fat/carbs 非 nil 计数；0 算已记录，nil 才未知。列出稳定未知字段名，但这不是完整度分数，不改父汇总。
- 引用/版本只在展示时 trim，空白省略；不得改 draft 原值。当前来源是 item 级，不能暗示每个营养素有独立来源。
- `MealItemEvidenceView` 默认一行徽标，同行按钮展开详情，不开 sheet、不写库。长引用多行并可文本选择。按钮使用 `meal-item-evidence-toggle-{index}`，并提供人类可读 label/value；详情 source/confidence/revision/preparation/coverage/unknown/caution 都给稳定 identifier，技术字符串不能成为 VoiceOver 文案。
- 在 `nutritionItemRow` 宏量行之后、常用克数之前嵌入 view。Presentation 每次从当前 bound item 派生，现有 sticky `isUserEdited` 改变后 UI 自动更新，不建第二套状态。
- 删除页尾只代表最后异步 batch、重开会消失的 `nutritionEstimate.confidence` 文字及无用 helper；保留 estimate note/error。每项持久化 confidence 才是本阶段事实。
- 不修改任何保存、取消、AI 请求、照片、复用、常用克数、父汇总或 Coordinator 行为。

单元测试至少覆盖四种来源、全部 confidence case 与 nil、空白引用/版本、AI 修订事实、三种 preparation、0/nil 覆盖和各来源风险说明。用 `ProvenanceKind.allCases`/`Confidence.allCases` 让新增 enum case 会暴露测试缺口。

UI 只最小扩展 `MealPersistenceUITests.test_manualItemRoundTripRemainsOnReloadThenCleanup`：新增手工 item 后检查紧凑来源；展开检查 0/4、未标注和手工说明；保存重开后再检查来源仍在；保留截图。继续用唯一 marker 经真实 UI 删除。不要清空全库、直写 SQLite、加 debug seed，亦不要为 AI/database/label UI 测试调用真实 LLM；这些由纯 presentation 测试覆盖。

允许修改：

- 新增 `UI/Diet/MealItemEvidenceView.swift`
- `UI/Diet/DietView.swift`
- 新增 `Tests/MealItemEvidencePresentationTests.swift`
- `UITests/MealPersistenceUITests.swift`
- xcodegen 必要生成结果

禁止修改 schema/迁移/Record/MealStore/MealItemDraft/MealEditorDraft/Coordinator/AppEnvironment/数据库、AI prompt/请求/解析、照片、HealthKit、SyncEngine、通知、复用、常用克数、导航和 docs。不要新增来源编辑、评分、食品库、OCR/条码、份量单位、ViewModel、Repository、protocol、缓存或单例。不要 commit、tag 或 push。若需要越界才能完成，停止并精确报告。

运行并简要报告：

    xcodegen generate
    xcodebuild -project HealthManager.xcodeproj -scheme HealthManager -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -only-testing:HealthManagerTests/MealItemEvidencePresentationTests -only-testing:HealthManagerTests/MealItemDraftTests -only-testing:HealthManagerTests/MealEditorDraftTests test
    xcodebuild -project HealthManager.xcodeproj -scheme HealthManager -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -only-testing:HealthManagerUITests/MealPersistenceUITests -only-testing:HealthManagerUITests/MealReuseUITests -only-testing:HealthManagerUITests/SmokeTests test
    xcodebuild -project HealthManager.xcodeproj -scheme HealthManager -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' build
    git diff --check
    git status --short

不要运行全量单元测试，不要继续 STAGE-007。最终只列：候选状态、TDD red/green 证据、改动文件、定向单测/UI/build 结果、UI 测试清理证据、未验证边界、git status。

## 任务结束
