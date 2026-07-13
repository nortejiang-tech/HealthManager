# STAGE-002：MealStore 原子持久化模块

> 状态：READY（STAGE-001 PASS）
>
> 执行者：Coder；主架构师验收
>
> 前置决策：[ADR-001](../adr/ADR-001-normalized-meal-item-snapshots.md)

## 1. 唯一目标

建立具体的 `MealStore` 深模块，以小接口隐藏餐次与分项的原子读写、替换顺序、保守汇总投影和删除回执；本阶段不接 UI、HealthKit 或照片文件系统。

## 2. 预先确认的测试 seam

测试只通过 `MealStore` 的三个行为入口观察结果：

- `load(id:)`：返回餐次及按 `sort_order` 排列的分项，找不到返回 nil。
- `save(meal:items:)`：新增或更新餐次，并在同一事务中替换分项，返回实际持久化快照。
- `delete(id:)`：在同一事务中取得并删除快照；找不到返回 nil。

当前只有 SQLite/GRDB 一个实现，不创建 protocol 或 Repository 层。

## 3. 接口与数据合同

`MealStore` 至少提供：

- `Snapshot`：`meal: MealRecord` 与 `items: [MealItemRecord]`。
- `ItemInput`：不包含数据库 id、meal_id、sort_order 或 updated_at；包含名称、克数、备餐状态、四项营养、来源、来源引用/版本、置信度、用户修订标记，以及可选历史 `createdAt`。
- 可注入的 Unix 秒时钟；默认取当前时间，测试使用固定值。一次 save 只采样一次时钟。
- 显式错误：更新不存在的 meal id；trim 后空名称及其数组下标。其他 SQLite 约束错误可以原样抛出。

如 Swift 并发约束要求，可为纯值 record/enum 添加正确的 `Sendable`，不得使用无依据的可变共享状态。

## 4. 保存不变量

1. `items` 为空时，原样保留调用方提供的餐次 calories/protein/fat/carbs。
2. `items` 非空时，每个汇总指标分别计算：仅当所有分项该指标都非 nil 才求和；任一分项未知则父餐次该指标为 nil。不同指标互不连带。
3. 分项名称保存前 trim；trim 后为空则抛出显式错误。
4. 持久化 `sort_order` 必须严格等于输入数组下标；调用方不控制外键和顺序。
5. 新分项 `created_at` 使用输入的历史值或当前时钟；`updated_at` 始终使用本次时钟。
6. 更新已有餐次时，meal id 不变；不存在的 id 必须失败，不能静默插入新餐次。
7. 父记录更新、旧分项删除、新分项插入属于一个 SQLite 事务；任何分项失败后父记录和旧分项都保持原状。
8. `hk_sync_id`、照片路径、备注和餐次 created_at 除调用方显式输入外不被 Store 改写。

## 5. 删除边界

`delete(id:)` 返回删除前 `Snapshot`，供后续 UI 层清理照片与 HealthKit 样本。MealStore 本身只负责 SQLite；不得声称文件和 HealthKit 与数据库事务原子一致。

## 6. 允许与禁止范围

允许：

- 新增 `Core/Database/MealStore.swift`
- 为 `Sendable` 或小型映射做必要的模型调整
- 新增 `Tests/MealStoreTests.swift`
- xcodegen 生成的必要项目变化

禁止：

- 修改 v1-v5 迁移
- 修改 UI、照片存储、HealthKit/SyncEngine、AI 或导航
- 创建 protocol、食品目录、服务定位器或全局单例
- 修改 STAGE/ADR 文档、commit、tag、push

## 7. 自动化证据

至少覆盖：

1. 新建无分项餐次保留手工汇总，load 往返一致。
2. 有完整分项时，按输入顺序保存并正确投影四项汇总；meal_id、sort_order 与时间正确。
3. 某个指标只要一个分项未知，父级该指标为 nil；其他完整指标仍正常求和。
4. 编辑会替换旧分项、保持 meal id，并保留传入的历史 item createdAt。
5. 替换中一个分项违反数据库约束时，父记录和旧分项完整回滚。
6. 更新不存在 id 抛出显式错误。
7. delete 返回删除前快照，此后 load 为 nil。

## 8. 完成标准与验证边界

- `MealStoreTests` 全部通过。
- 全量 `HealthManagerTests` 通过。
- Simulator build 成功。
- diff 无迁移/UI/HealthKit 越界，`git diff --check` 通过。
- 本阶段不验证编辑界面、照片清理、HealthKit 写回或真机。

## 9. 正式结果

> 由主架构师填写。

- 状态：PENDING
- 验收日期：—
- 验收 commit：—
- 证据：—
- 残余风险：—
