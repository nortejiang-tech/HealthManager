# STAGE-001：餐食分项 schema、记录类型与迁移证据

> 状态：READY（等待 ADR-001 Accepted 后执行）
>
> 执行者：Coder
>
> 正式验收者：主架构师会话
>
> 前置决策：[ADR-001](../adr/ADR-001-normalized-meal-item-snapshots.md)

## 1. 唯一目标

以追加迁移的方式建立 `meal_items` 持久化基础，并用自动化测试证明旧库升级、字段约束、枚举/NULL 往返和级联删除正确。

本阶段不实现 `MealStore`，不接入饮食界面，也不改变 HealthKit 行为。

## 2. 预期起点

- 分支：`main`
- 功能代码基线：v0.2.5 / HEAD `8c03941`
- 当前未跟踪 `docs/` 是主架构师产物，必须保留。
- 2026-07-13 基线：112 个单元测试和 1 个 UI 测试通过。

如果起点已有不属于 `docs/` 的源代码改动，Coder 必须停止并报告，不能覆盖或猜测其归属。

## 3. 允许修改

- `Core/Database/Migrations.swift`
- `Core/Database/Models/` 下新增餐食分项记录类型
- `Tests/` 下新增本阶段测试
- 运行 `xcodegen generate` 后由项目生成器产生的必要项目文件变化

如编译所必需，可对直接相关文件做最小调整，但必须在最终报告中逐项解释；不得借机重构相邻模块。

## 4. 禁止修改

- `v1_initial_schema`、`v2_add_source_origin`、`v3_add_llm_text`、`v4_meal_hk_sync_id` 的迁移体
- `UI/`、`Core/Sync/`、HealthKit、AI 分析、导航和版本号
- `MealRecord` 现有字段或语义
- `docs/` 中的 ADR、规划、研究和 STAGE 文件
- 提交、tag、push，以及任何 reset/checkout/clean/删除未跟踪文件操作

## 5. 实现合同

### 5.1 迁移可测试性

把迁移注册与执行拆开：提供一个内部可测试的 migrator 工厂，`run(on:)` 仍通过同一个工厂执行全部迁移。除追加 v5 外，不改变 v1-v4 的注册顺序和迁移体。

测试必须能先迁移到 `v4_meal_hk_sync_id`，写入旧格式 `meal_records`，再迁移到最新版本。

### 5.2 v5 schema

严格采用 ADR-001 的 `meal_items` 字段、原始值和约束：

- 外键 `meal_id -> meal_records.id`，`ON DELETE CASCADE`
- 同一餐 `(meal_id, sort_order)` 唯一
- `sort_order >= 0`
- `name` trim 后非空
- `grams` 为 NULL 或 `> 0`
- 四个营养指标为 NULL 或 `>= 0`
- preparation_state 仅为 `unknown/raw/cooked`
- provenance_kind 仅为 `manual/ai_estimate/nutrition_database/nutrition_label`
- confidence 为 NULL 或 `low/medium/high`
- `is_user_edited` 非空，默认 false

不得把可空数值改成 0 默认值。

### 5.3 Swift 记录类型

新增与表一一映射的 GRDB record，至少包含：

- 稳定 `CodingKeys`
- `didInsert` 回填 id
- `PreparationState`、`ProvenanceKind`、`Confidence` 原始值枚举
- Codable、FetchableRecord、MutablePersistableRecord、Identifiable、Equatable 所需能力

本阶段不增加食品目录关联、业务 Store、UI 文案或网络数据类型。

## 6. 必须提供的自动化证据

测试类命名为 `MealItemMigrationTests`，至少覆盖：

测试数据库配置必须与应用一致地启用 `PRAGMA foreign_keys = ON`，不能在外键关闭的 SQLite 连接上得出级联行为结论。

1. **旧库升级无损**：迁移至 v4，插入含汇总、照片、备注和 hk_sync_id 的餐次，再迁移至最新；父记录逐字段保持，分项数为 0。
2. **记录往返**：所有枚举原始值正确保存/读取；可空克数、营养值、来源引用、版本和置信度保持 NULL，不被转成默认值。
3. **顺序与唯一性**：分项可按 sort_order 稳定读取；重复 `(meal_id, sort_order)` 写入失败。
4. **字段约束**：非法空名称、负 sort_order、非正 grams、负营养值和非法枚举值至少通过代表性参数化/辅助方法验证为数据库拒绝。
5. **外键与级联**：不存在的 meal_id 写入失败；删除父餐次后分项自动删除。

测试应通过公开的迁移/记录边界验证行为，不复制一套测试专用 schema。

## 7. 完成标准

只有同时满足以下条件，本阶段才可由主架构师判为 PASS：

- diff 没有越界修改或已应用迁移改写。
- v5 为纯追加迁移，现有餐次升级无损。
- 上述自动化证据全部通过。
- 全量 `HealthManagerTests` 通过，数量不少于基线 112 加本阶段新增测试。
- App 在指定 Simulator 目标构建成功。
- `git diff --check` 通过。

Coder 的自报结果只是候选证据；正式 PASS 由主架构师重新检查工作区后回填。

## 8. 本阶段明确不验证

- MealEditView 的分项保存和重新打开
- 餐次汇总投影
- HealthKit 写回/删除
- 最近餐、复制餐次和常用克数
- 真机数据库升级

这些未验证项不能写成已完成或已通过。

## 9. 正式结果

> 由主架构师验收后填写；Coder 不编辑本节。

- 状态：PENDING
- 验收日期：—
- 验收 commit：未提交
- 证据：—
- 残余风险：—
