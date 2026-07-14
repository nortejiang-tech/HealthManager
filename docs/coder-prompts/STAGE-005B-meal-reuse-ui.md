# 给 Coder 的提示词：STAGE-005B 低摩擦餐食复用入口

## 任务开始

只执行 HealthManager `STAGE-005B`。不要读取记忆库、重新做竞品研究或处理相邻阶段；完整阅读：

- `docs/adr/ADR-001-normalized-meal-item-snapshots.md`
- `docs/stages/STAGE-005A-meal-reuse-core.md`
- `docs/stages/STAGE-005B-meal-reuse-ui.md`
- `Core/Database/MealStore.swift`
- `Core/Database/MealReuseModels.swift`
- `Core/Database/MealNutritionProjection.swift`
- `UI/Diet/DietView.swift`
- `UI/Diet/MealEditorDraft.swift`
- `UI/Diet/MealItemDraft.swift`
- `Tests/MealEditorDraftTests.swift`
- `Tests/MealItemDraftTests.swift`
- `UITests/MealPersistenceUITests.swift`
- `UITests/SmokeTests.swift`

先确认：

1. 分支是 `codex/health-planning-20260713`。
2. `git merge-base --is-ancestor 0b614ff HEAD` 成功。
3. 从 `0b614ff` 到当前 HEAD 只多出本阶段的 `docs/stages/STAGE-005B-meal-reuse-ui.md` 与 `docs/coder-prompts/STAGE-005B-meal-reuse-ui.md`。
4. 工作区干净。

任一不成立就停止并报告，不要修复基线。

目标：把 STAGE-005A 已验收接口接成“最近餐/选中项 → 现有新增编辑器 → 用户显式保存”的低摩擦路径，并展示同名同 preparation 的常用克数；绝不自动保存。

按 TDD 纵向切片执行：先补 `ItemInput → MealItemDraft` 与 `CopyDraft → MealEditorDraft` 测试并保存 red 证据，再实现窄 initializer；再做单一 sheet destination、最近餐浏览/选择页和常用克数；最后写真实 UI 流程测试。不要在测试中重写 Store 的排序、投影或复制算法。

关键合同：

- `DietView` 用一个 `.sheet(item:)` destination 表达新增、编辑、复用，保留 `diet-add-meal`，新增 `diet-reuse-meal`；dismiss 后继续 refresh。`SmokeTests` 改点稳定 identifier，不能再用 toolbar 下标。
- 新建 `UI/Diet/MealReuseView.swift` 承担复用 sheet、最近餐 load/empty/error+retry/loaded、餐次行、选中分项页及常用克数组件；不要把这些继续堆进 `DietView.swift`，不要建 ViewModel/router。
- 最近餐只调 `recentSnapshots(limit: 20, excludingMealId: nil)`；View 不直查 GRDB、不排序。未知营养显示“—”；legacy 0-item 只允许整餐。
- 整餐入口从饮食页到可编辑草稿只需“打开复用”“复用整餐”两次操作。选中页使用持久化 child id Set，空选择禁用确认，输出顺序/缺失错误都交给 Store。
- 调用 `makeCopyDraft` 时只采样一次 `Date`，同一值同时用于 `MealType.suggested(for:)` 与 `eatenAt`。生成后在同一复用 sheet 流内切到 `MealEditView(copying:)`；取消关闭 sheet 且不写库。
- `MealItemDraft` 增加从 `MealStore.ItemInput` 的窄 initializer，完整保留复制事实和来源字段，baseline 使用复制值、createdAt=nil。`MealEditorDraft` 增加 `init(copyDraft:)`，得到 ready 新餐；有 items 用共享投影，0-item legacy 保留父文本。
- `MealEditView(copying:)` 只初始化现有 editor；保存仍唯一走 `mealPersistenceCoordinator.save`，不得增加旁路或回写来源 snapshot。
- 每个非空 item 用 `.task(id:)` 查询 `commonGramSuggestions`，精确传入 item preparation，limit 3；连续输入短 debounce，取消旧任务。点击建议只设置 `gramsText`；失败记录日志并隐藏辅助，不阻断保存。
- AI 配置与复用无关；不得因 AI 关闭而禁用历史复用。
- 所有新增交互添加稳定 accessibility identifier，至少覆盖 loading/error/empty、recent row、whole/select、item toggle/confirm 和 common grams。

允许修改：

- 新增 `UI/Diet/MealReuseView.swift`
- `UI/Diet/DietView.swift`
- `UI/Diet/MealEditorDraft.swift`
- `UI/Diet/MealItemDraft.swift`
- `Tests/MealEditorDraftTests.swift`
- `Tests/MealItemDraftTests.swift`
- 新增 `UITests/MealReuseUITests.swift`
- `UITests/SmokeTests.swift` 仅稳定 add identifier
- xcodegen 必要生成结果

禁止修改 Core Store/模型/投影、schema/迁移/Record/DatabaseManager、AppEnvironment、Coordinator、照片、HealthKit、SyncEngine、通知、AI、导航和 docs。不要新增 ViewModel、Repository、protocol、router、缓存或单例。不要 commit、tag 或 push。若合同在允许范围内无法实现，停止并精确报告，不要扩大范围。

UI 测试必须通过真实界面创建并最终清理数据，至少证明：

1. 整餐复制进入带分项/克数的“添加餐次”，取消后 `meal-row-*` 数量不变。
2. 选中分项只带入勾选项，历史备注不带入；显式保存、列表出现、重开仍正确，然后清理来源与副本。
3. 新分项输入同名后出现历史常用克数按钮，点击更新克数字段。

运行并简要报告：

    xcodegen generate
    xcodebuild -project HealthManager.xcodeproj -scheme HealthManager -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -only-testing:HealthManagerTests/MealEditorDraftTests -only-testing:HealthManagerTests/MealItemDraftTests -only-testing:HealthManagerTests/MealReuseTests test
    xcodebuild -project HealthManager.xcodeproj -scheme HealthManager -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -only-testing:HealthManagerUITests/MealReuseUITests -only-testing:HealthManagerUITests/MealPersistenceUITests -only-testing:HealthManagerUITests/SmokeTests test
    xcodebuild -project HealthManager.xcodeproj -scheme HealthManager -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' build
    git diff --check
    git status --short

不要运行全量单元测试以外的额外范围，不要继续 STAGE-006。最终只列：候选状态、TDD red/green 证据、改动文件、定向单测/UI/build 结果、最终测试数据清理证据、未验证边界、git status。

## 任务结束
