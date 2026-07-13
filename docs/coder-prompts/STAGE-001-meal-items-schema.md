# 给 Coder 的提示词：STAGE-001 餐食分项 schema

把下面从“任务开始”到“任务结束”的全部内容原样交给 Coder 会话。

---

## 任务开始

你是 HealthManager 的实现 Coder。当前只执行 **STAGE-001：餐食分项 schema、记录类型与迁移证据**。不要规划或实现后续阶段。

工作目录：

    /Users/nortepro/HealthManager

### A. 开始前必须做

1. 先运行 `git status --short` 和 `git rev-parse --short HEAD`。
2. 预期执行分支为 `codex/health-planning-20260713`，功能代码基线为 `main@8c03941`；`docs/` 是主架构师已提交产物，必须原样保留。
3. 如果发现任何未提交改动，立即停止，不覆盖、不恢复、不猜测归属；把文件列表报告给用户。
4. 完整阅读：
   - `AGENTS.md`（如果存在）
   - `docs/adr/ADR-001-normalized-meal-item-snapshots.md`
   - `docs/stages/STAGE-001-meal-items-schema.md`
   - `Core/Database/Migrations.swift`
   - `Core/Database/DatabaseManager.swift`
   - `Core/Database/Models/MealRecord.swift`
   - `project.yml`
5. 确认 ADR-001 状态为 Accepted；如果不是，停止并报告。

### B. 唯一目标

追加 `v5_meal_items` 迁移，新增对应 GRDB record，并用真实迁移测试证明旧库升级、约束、NULL/枚举往返和级联删除正确。

本阶段不做 MealStore，不改 UI，不改 HealthKit，不改 AI，不改导航，不改版本号。

### C. 实现要求

1. 在 `Migrations` 中增加内部可测试的 migrator 工厂（例如 `static func makeMigrator() -> DatabaseMigrator`）。`run(on:)` 必须调用同一个工厂。只移动必要的注册结构并追加 v5；**不得修改 v1-v4 迁移体、名称或顺序**。
2. v5 创建 `meal_items`，字段和约束必须与 ADR-001 完全一致：
   - `id` 自增主键
   - `meal_id` 非空，引用 `meal_records(id)`，删除父记录时 cascade
   - `sort_order` 非空且 >= 0
   - `name` 非空且 trim 后非空
   - `grams` 可空；非空时 > 0
   - `preparation_state` 非空，只允许 `unknown/raw/cooked`
   - `calories_kcal/protein_g/fat_g/carbs_g` 可空；非空时 >= 0
   - `provenance_kind` 非空，只允许 `manual/ai_estimate/nutrition_database/nutrition_label`
   - `provenance_ref/provenance_version` 可空
   - `confidence` 可空；非空时只允许 `low/medium/high`
   - `is_user_edited` 非空、默认 false
   - `created_at/updated_at` 非空整数 Unix 秒
   - `(meal_id, sort_order)` 唯一索引
3. 在 `Core/Database/Models/` 新增一一映射的 `MealItemRecord`。沿用仓库现有 GRDB 模型风格，提供稳定 CodingKeys、didInsert 和三个 String raw-value 枚举。不要把 UI label 放进持久化枚举。
4. 在 `Tests/` 新增 `MealItemMigrationTests`。测试必须使用真实 `Migrations.makeMigrator()`，不得复制测试专用 schema；自建测试 pool 时必须像应用配置一样启用 `PRAGMA foreign_keys = ON`。至少覆盖：
   - migrate upTo `v4_meal_hk_sync_id` -> 插入旧餐次 -> migrate latest；汇总、照片、备注、hk_sync_id 逐字段不变且无分项
   - record 的枚举和可空字段 round-trip；NULL 不变 0
   - sort_order 查询顺序与 `(meal_id, sort_order)` 唯一性
   - 非法名称、sort_order、grams、营养值、枚举被 SQLite 拒绝
   - 无效 meal_id 被拒绝；删除父餐次后 child 数为 0
5. 约束由数据库承担，不能只写 Swift precondition。测试遇到数据库错误时验证“确实失败”，不要依赖脆弱的整段错误文案。
6. 保持实现最小、可读。当前只有一个 GRDB 实现，不创建 Repository protocol，不创建食品目录表，不实现投影逻辑。

### D. 允许与禁止范围

允许：

- `Core/Database/Migrations.swift`
- `Core/Database/Models/MealItemRecord.swift`（或等价的单一新模型文件）
- `Tests/MealItemMigrationTests.swift`（或等价的单一新测试文件）
- `xcodegen generate` 必需的生成文件变化

禁止：

- 修改 `docs/`
- 修改任何 v1-v4 迁移体
- 修改 `UI/`、`Core/Sync/`、`MealRecord` 业务语义、AI、HealthKit、导航、版本号
- commit、tag、push
- `git reset --hard`、`git checkout --`、`git clean`、删除未跟踪文件
- 为了“顺手优化”扩大重构范围

如果编译迫使你越界，先停止并解释原因，不要自行扩大范围。

### E. 必须实际执行的验证

使用以下 Simulator 目标；如果本机目标不可用，先列出可用目标并报告工具阻塞，不要伪造结果。

    xcodegen generate

    xcodebuild -project HealthManager.xcodeproj \
      -scheme HealthManager \
      -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
      -only-testing:HealthManagerTests/MealItemMigrationTests \
      test

    xcodebuild -project HealthManager.xcodeproj \
      -scheme HealthManager \
      -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
      -only-testing:HealthManagerTests \
      test

    xcodebuild -project HealthManager.xcodeproj \
      -scheme HealthManager \
      -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
      build

    git diff --check
    git status --short

命令失败时保留原始失败摘要，判断是代码失败还是工具/目标失败。不得把未运行或失败项写成 PASS。无需运行 UI 测试或真机迁移，因为不在本阶段验证边界内。

### F. 最终输出格式

只按以下结构报告：

1. **Coder 候选状态**：PASS / FAIL / INCOMPLETE（正式状态由主架构师决定）
2. **实际改动文件**：逐项列出及目的
3. **关键实现**：迁移、约束、模型和测试各 1-3 句
4. **验证证据**：逐条列出命令、退出状态、测试数量/失败数量或关键失败摘要
5. **未验证边界**：明确 UI、MealStore、HealthKit、真机迁移未验证
6. **当前 git status**：原样粘贴
7. **风险或偏差**：没有则写“无”；如有越界需求必须写明并停止

不要提交代码。完成后等待主架构师验收，不要继续 STAGE-002。

## 任务结束
