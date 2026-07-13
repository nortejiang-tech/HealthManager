# ADR-001：以规范化餐食分项快照作为饮食记录基础

> 状态：Accepted
>
> 日期：2026-07-13
>
> 接受依据：用户于 2026-07-13 回复“全部按建议执行”
>
> 决策范围：v0.3 饮食记录的数据模型、持久化边界和后续扩展 seam

## 1. 背景

当前 `MealRecord` 只保存一餐的热量和三大营养素汇总。饮食编辑器中的 `EditableNutritionItem` 只存在于 SwiftUI View 状态中，保存后每个食物的名称、克数、营养值和识别来源都会丢失。

这会直接阻塞已经确认的产品目标：

- 用户修正后再次打开，必须看到自己真正保存过的分项，而不是重新估算。
- 最近餐、常用克数和复制上一餐需要可查询的分项数据。
- AI 估算、手工输入、营养数据库和包装标签需要区分来源及置信度。
- 未来可以接入食品数据源，但历史记录不能随着外部食品条目更新而被静默改写。

本产品的边界仍是私密、可信、可纠正的个人健康闭环，不建设社区、电商、广告、内容课程或以减重为唯一目标的重型平台。

## 2. 决策驱动因素

按优先级排序：

1. 历史记录必须稳定、可恢复、可纠正。
2. 未知值必须继续是未知值，不能把缺失营养素静默当成 0。
3. 需要支持低摩擦复用和来源说明，而不是只满足当前编辑界面。
4. 数据库迁移必须是追加式，现有餐次和 HealthKit 同步标识不得丢失。
5. v0.3 只建立最小可靠基础，不预建尚未验证的食品目录、份量换算和食谱系统。

## 3. 已考虑方案

### 方案 A：在 meal_records 增加 items_json

优点是实现快、表结构少。

不采用的原因：分项名称、克数、来源和置信度难以查询和索引；复制、统计和纠错会把 JSON 解析散落到多个调用方；后续 JSON 结构本身还需要一套隐藏的迁移机制。它降低了眼前代码量，却把长期复杂度留给每一个消费者。

### 方案 B：增加规范化 meal_items 快照表

每个分项是所属餐次在保存时的历史快照，按外键和顺序归属于 `meal_records`。分项可独立查询，来源与未知值有明确字段，未来食品目录只能作为可选参考，不会成为历史值的动态真相。

这是本 ADR 选择的方案。

### 方案 C：立即建立 foods、servings、meal_items 完整食品目录

长期表达力最高，但当前没有确定的数据许可、版本策略、份量模型和真实使用证据。现在实施会把尚未验证的假设固化成核心 schema，属于过度设计。因此延后到 v0.4 的独立 ADR。

## 4. 决策

### 4.1 数据结构

追加迁移 `v5_meal_items`，创建 `meal_items`：

| 字段 | 类型/约束 | 含义 |
|---|---|---|
| id | INTEGER PRIMARY KEY | 分项本地标识 |
| meal_id | INTEGER NOT NULL, FK meal_records(id), ON DELETE CASCADE | 所属餐次 |
| sort_order | INTEGER NOT NULL, >= 0 | 用户可见顺序 |
| name | TEXT NOT NULL, trim 后非空 | 保存时名称快照 |
| grams | REAL NULL, > 0 | 可选克数；未知不是 0 |
| preparation_state | TEXT NOT NULL | unknown / raw / cooked |
| calories_kcal | REAL NULL, >= 0 | 可选热量快照 |
| protein_g | REAL NULL, >= 0 | 可选蛋白质快照 |
| fat_g | REAL NULL, >= 0 | 可选脂肪快照 |
| carbs_g | REAL NULL, >= 0 | 可选碳水快照 |
| provenance_kind | TEXT NOT NULL | manual / ai_estimate / nutrition_database / nutrition_label |
| provenance_ref | TEXT NULL | 来源条目、本地模型或标签识别的可选引用；v0.3 不设外键 |
| provenance_version | TEXT NULL | 数据集或模型版本快照 |
| confidence | TEXT NULL | low / medium / high；没有证据时为 NULL |
| is_user_edited | BOOLEAN NOT NULL DEFAULT 0 | 用户是否改过机器/数据库候选 |
| created_at | INTEGER NOT NULL | Unix 秒 |
| updated_at | INTEGER NOT NULL | Unix 秒 |

建立 `(meal_id, sort_order)` 唯一索引。它同时约束同一餐的稳定顺序并支持按餐查询。

枚举在 Swift 与 SQLite 中使用上述稳定原始值；界面文案不得作为持久化值。

### 4.2 快照语义

- `meal_items` 是历史快照，不是对未来可变食品目录的实时引用。
- 用户编辑一餐时可以在同一事务中替换或更新其分项；“快照”不表示永不编辑，而表示外部数据更新不得静默改变已保存值。
- v0.3 不增加 foods、servings、recipes、条码或纠错历史表。
- `provenance_ref` 和 `provenance_version` 先保存可解释线索；未来是否增加目录外键由新的 ADR 决定。

### 4.3 餐次汇总兼容语义

现有 `meal_records.calories_kcal/protein_g/fat_g/carbs_g` 暂时保留，因为仪表盘和 HealthKit 写回正在读取这些字段。

后续 `MealStore` 按以下规则维护它们：

- 一餐有分项时，每个指标只有在所有分项的该指标都已知时才求和；任一分项未知则餐次该指标为 NULL。
- 一餐没有分项时，保留用户直接录入或历史遗留的餐次汇总值。
- 不允许调用方各自实现求和和未知值规则。

这是一层兼容投影，不是第二套独立真相。未来若移除或替代它，需要单独迁移和 ADR。

### 4.4 持久化模块边界

在 schema 稳定后建立一个具体的 `MealStore` 深模块，隐藏以下复杂性：

- 餐次和分项的原子读写。
- 分项顺序与替换语义。
- 餐次汇总的保守投影。
- 删除餐次后的级联数据结果。

SwiftUI View 不再直接拼装父子表写入。当前只有 SQLite/GRDB 一个真实实现，因此先使用具体类型和可替换的 `DatabaseManager`，不为假想的第二个实现提前创建 protocol。出现第二个真实 adapter 时再提取接口。

### 4.5 迁移纪律

- 不修改 `v1_initial_schema` 到 `v4_meal_hk_sync_id` 的任何已应用迁移内容。
- v5 只新增表和索引，不回填或重写现有 `meal_records`。
- 已有餐次迁移后拥有 0 个分项，原汇总、照片、备注和 `hk_sync_id` 保持不变。
- 外键必须实际启用，并由迁移测试证明级联删除行为。

## 5. 后果

正面后果：

- 分项记录成为可测试、可查询、可复用的稳定事实。
- 来源、置信度和用户修订不再依赖 UI 临时状态。
- 后续食品目录可以通过 adapter 和可选引用接入，不污染历史值。
- 未知营养素不会因为求和方便而被伪装成 0。

代价与风险：

- 一次保存涉及父子表事务，必须由 `MealStore` 集中处理。
- 现有汇总字段与分项之间需要明确投影规则和测试。
- v0.3 仍不解决食品名称标准化、份量单位换算和数据库许可问题。

## 6. 验证与生效条件

用户已确认该边界，本 ADR 已从 Proposed 改为 Accepted，表示该决策获准实施。

当前实现验证状态：VERIFIED。STAGE-001 已证明旧库从 v4 升级无损、v5 约束与外键级联有效，并通过 117 个全量单元测试及 Simulator 构建。实施验证不是接受决策的前置条件，避免形成循环依赖。

如果实施证据表明 schema 需要破坏性修改，停止后续 STAGE，将本 ADR 标为 Superseded 或重新 Proposed；不得直接改写已发布的 v5 迁移。
