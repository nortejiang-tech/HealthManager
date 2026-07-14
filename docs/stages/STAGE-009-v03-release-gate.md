# STAGE-009：v0.3 软件验收门与次日真机交接

> 状态：IN_PROGRESS（迁移预检 PASS；最终门等待 STAGE-007D PASS）
>
> 执行者：主架构师；本阶段不直接交给 Coder

## 1. 唯一目标

在最终 v0.3 候选 HEAD 上，证明追加迁移、全部自动化测试、Simulator 交互、数据库副作用和独立构建满足已接受的 STAGE/ADR；把 Simulator 无法证明的真实 HealthKit、照片、可访问性和睡眠数据项目逐项标为 INCOMPLETE，并形成下一会话无需重放聊天即可执行的 HANDOFF。

本阶段是验收门，不增加产品能力。若发现代码缺陷，先将本阶段标为 FAIL，并另开有唯一目标、允许范围和 Coder 提示词的修复阶段；不得在验收文档中顺手改产品代码。

## 2. 前置状态

| 前置项 | 当前状态 | 进入最终门的要求 |
|---|---|---|
| ADR-001 | Accepted / VERIFIED | 保持不变 |
| STAGE-001～006 | PASS | 不重写既有结果；最终全量回归覆盖 |
| STAGE-007A | ACCEPTED（方案 1） | 保持产品与证据边界 |
| STAGE-007B | READY | 可信饮食/缺口合同 PASS |
| STAGE-007C | NOT STARTED | Today evidence snapshot/loader PASS |
| STAGE-007D | NOT STARTED | 方案 1 时间线与五栏导航 PASS |
| STAGE-008 | PASS，checkpoint `ff67ca1` | 睡眠真机数据仍为 INCOMPLETE |

STAGE-007D 未完成前，本阶段只能记录 PRELIMINARY/PASS 预检，不能宣称 v0.3 软件最终 PASS。

## 3. 迁移与实际数据库门

最终候选必须同时满足：

1. `MealItemMigrationTests` 从 `v4_meal_hk_sync_id` 升至 v5 后保留父餐次字段、照片路径、备注和 `hk_sync_id`，旧餐次保持 0 个分项。
2. v5 的字段约束、枚举/NULL 往返、唯一顺序与外键级联仍通过。
3. 不修改 v1～v5 已应用迁移；若以后需要 schema 变化，只能追加 v6。
4. 运行中 iPhone 17 Simulator 主库的 `grdb_migrations` 顺序与代码一致，`PRAGMA integrity_check` 为 `ok`，`PRAGMA foreign_key_check` 无结果。
5. 全量 UI 后，测试父餐、测试分项、孤儿分项与重复 `(meal_id, sort_order)` 均为 0；不得通过清库取得结果。

2026-07-14 预检证据：

- `MealItemMigrationTests` + `SourceOriginMigrationTests`：6/6，结果包 `/tmp/healthmanager-stage009-preflight-migrations-20260714-01.xcresult`。
- 实际 Simulator 主库只读审计：迁移为 v1、v2、v3、v4、v5；`integrity_check=ok`；外键检查无行；当前 `meal_records|meal_items|orphan|duplicate order` 为 `0|0|0|0`。

这些结果只证明 `ff67ca1` 预检；STAGE-007D 后仍需在最终 HEAD 重跑最终门。

## 4. 最终自动化与构建门

最终 HEAD 使用新的、不复用既有目录的 xcresult：

1. 全量 `HealthManagerTests`：0 failed、0 skipped；记录总数与结果包。
2. 全量 `HealthManagerUITests`：0 failed、0 skipped；记录总数、结果包与运行时工具提示。
3. 独立 iPhone 17 / iOS 26.5 Simulator build：0 error、0 warning。
4. `git diff --check` 通过；提交前 staged diff 与本阶段边界一致。
5. 用 `xcresulttool` 读取计数，不只根据 `xcodebuild` 尾行或退出码判断。

如 UI 运行遇到 LLDB/Simulator 启动异常，必须保留原始结果，区分工具失败与断言失败；没有完整 xcresult 就不得写 PASS。

## 5. Simulator 交互与视觉门

- 最终五栏导航与用户选定的“今日”方案一致；现有饮食、用药、趋势、来源、同步、设置、报告与诊断入口都可达。
- 餐食手工保存、重开、最近餐/常用克数复用、证据展开、取消与定向删除继续通过真实 UI，不增加 debug seed 或 SQLite 旁路。
- 目视核对关键截图：今日首屏、更多入口、餐食复用 sheet、餐食证据折叠/展开。记录截图导出目录。
- 不把原型中的示例数字或不存在的“食物数据库”当成已交付能力。
- 清理只删除测试自己创建的唯一 marker；不得删除用户或 Simulator 既有记录。

## 6. 真机清单与状态规则

以下项目必须在真实 iPhone 上逐项记录 PASS / FAIL / INCOMPLETE。未执行只能写 INCOMPLETE，不得由 Simulator 推断：

1. 既有用户数据库升级后，餐次、分项、照片路径、备注、`hk_sync_id` 和其他健康数据无损。
2. HealthKit 授权页、真实餐次营养样本写入、编辑更新和删除。
3. 已同步餐次清空全部营养后，旧 HealthKit 样本的真实删除结果与失败反馈。
4. PhotosPicker / 相机导入、替换、保存、取消、删除后的真实文件生命周期。
5. VoiceOver 读序与操作、最大 Dynamic Type、餐食证据 44pt 点击区和 sheet 可用性。
6. Apple Watch、iPhone 与第三方 sleepAnalysis 的跨午夜、inBed/asleep、详细阶段重叠和来源组合。
7. 后台 observer / 增量同步在真实 HealthKit 样本变化时的行为。

本轮已授权“软件与 Simulator 完成、真机次日执行”，因此允许最终写：**软件/Simulator PASS，真机 INCOMPLETE**。但整体发布就绪仍为 INCOMPLETE；不得 merge、tag 或 release。

## 7. HANDOFF 与文档门

最终验收需同步：

- 本文件的正式结果、结果包、截图目录和残余风险。
- `NEXT_TASK.md`：删除已完成的餐食持久化与睡眠效率旧待办，只保留真实下一阶段。
- `docs/planning/HEALTHMANAGER-ARCHITECT-CODER-WORKFLOW.md`：追加最终 checkpoint 与阶段状态，不篡改历史基线。
- v0.3 HANDOFF：只引用 ADR、STAGE、commit 与结果包，不复制已有长文；包含建议技能、次日真机顺序和失败时的停止条件。
- `git status` 必须干净，本地 HEAD 与 upstream 相同。

## 8. Coder 边界

STAGE-009 不生成“让 Coder 跑一遍看看”的实现提示词。主架构师负责读取真实结果并作发布门判断。若任何必需项失败，再根据失败证据生成独立修复 STAGE 与 Coder 提示词；高风险迁移、HealthKit 幂等或跨进程恢复问题由主架构师接管。

## 9. 正式结果

- 软件 / Simulator：PENDING
- 真机：INCOMPLETE（尚未执行）
- 发布就绪：INCOMPLETE
- 最终 commit：—
- 全量证据：—
- 视觉与数据库证据：—
- 残余风险：等待 STAGE-007D 与次日真机
