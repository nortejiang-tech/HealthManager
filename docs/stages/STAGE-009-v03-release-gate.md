# STAGE-009：v0.3 软件验收门与次日真机交接

> 状态：SOFTWARE_SIMULATOR_PASS；真机 item4、item6、item7 PASS，item5 INCOMPLETE（2026-07-15；整体发布就绪仍为 INCOMPLETE）
>
> 执行者：主架构师；本阶段不直接交给 Coder

## 1. 唯一目标

在最终 v0.3 候选 HEAD 上，证明追加迁移、全部自动化测试、Simulator 交互、数据库副作用和独立构建满足已接受的 STAGE/ADR；把 Simulator 无法证明的真实 HealthKit、照片、可访问性和睡眠数据项目逐项标为 INCOMPLETE，并形成下一会话无需重放聊天即可执行的 HANDOFF。

本阶段是验收门，不扩展产品范围。若发现代码缺陷，必须保留原始失败证据并在唯一目标的修复范围内处理；本轮 Dynamic Type 真机审计发现并修复了 More 列表的文本裁切，修复后已重新执行真机审计。

## 2. 前置状态

| 前置项 | 当前状态 | 进入最终门的要求 |
|---|---|---|
| ADR-001 | Accepted / VERIFIED | 保持不变 |
| STAGE-001～006 | PASS | 不重写既有结果；最终全量回归覆盖 |
| STAGE-007A | ACCEPTED（方案 1） | 保持产品与证据边界 |
| STAGE-007B | PASS | 保持共享可信饮食/缺口证据合同；最终全量回归覆盖 |
| STAGE-007C | PASS（实现 `7df218f`；文档 `a76d958`） | Today evidence snapshot/loader 已验收 |
| STAGE-007D | PASS（`2e3b038`） | 方案 1 时间线、五栏导航与 raw visual audit 已验收 |
| STAGE-008 | PASS，checkpoint `ff67ca1` | 睡眠真机数据仍为 INCOMPLETE |

最终软件候选为 `2e3b038c4d5722d507874feaea90002fc2379e66`。STAGE-009 后续只修改验收、交接与下一任务文档，不再改变被测产品代码。

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

2026-07-14 最终证据：

- `MealItemMigrationTests` + `SourceOriginMigrationTests`：6/6，0 failed / 0 skipped，`/tmp/healthmanager-stage009-final-migrations-20260714-attempt01.xcresult`。
- 最终 UI 后的真实 iPhone 17 Simulator 主库审计：`/tmp/healthmanager-stage009-final-db-audit-20260714.txt`。
- 主库 migration 严格为 v1～v5，`integrity_check=ok`，FK 违规 0，active sync job 0。
- `meal_records / meal_items / orphan / duplicate order group = 0 / 0 / 0 / 0`；全部 UI marker、medication plan/log、alert、raw sample、summary 也为 0；没有通过清库得到结果。

## 4. 最终自动化与构建门

最终 HEAD 使用新的、不复用既有目录的 xcresult：

1. 全量 `HealthManagerTests`：0 failed、0 skipped；记录总数与结果包。
2. 全量 `HealthManagerUITests`：0 failed、0 skipped；记录总数、结果包与运行时工具提示。
3. 独立 iPhone 17 / iOS 26.5 Simulator build：0 error、0 warning。
4. `git diff --check` 通过；提交前 staged diff 与本阶段边界一致。
5. 用 `xcresulttool` 读取计数，不只根据 `xcodebuild` 尾行或退出码判断。

如 UI 运行遇到 LLDB/Simulator 启动异常，必须保留原始结果，区分工具失败与断言失败；没有完整 xcresult 就不得写 PASS。

最终门结果：

- 全量 `HealthManagerTests`：242/242，0 failed / 0 skipped，`/tmp/healthmanager-stage009-final-unit-20260714-attempt01.xcresult`。
- 全量 `HealthManagerUITests`：6/6，0 failed / 0 skipped，`/tmp/healthmanager-stage009-final-ui-20260714-attempt01.xcresult`。
- 独立冷构建：使用独立 DerivedData 从头解析 GRDB 6.29.3，iPhone 17 / iOS 26.5，status `succeeded`，0 error / 0 warning / 0 analyzer warning，`/tmp/healthmanager-stage009-final-build-20260714-attempt01.xcresult`。
- `xcresulttool` 已逐项读取上述计数；UI 运行出现 Xcode `no debugger version` 与系统 accessibility bundle 重复类提示，但没有断言失败或缺失 xcresult，不把工具提示误记为产品缺陷。

## 5. Simulator 交互与视觉门

- 最终五栏导航与用户选定的“今日”方案一致；现有饮食、用药、趋势、来源、同步、设置、报告与诊断入口都可达。
- 餐食手工保存、重开、最近餐/常用克数复用、证据展开、取消与定向删除继续通过真实 UI，不增加 debug seed 或 SQLite 旁路。
- 目视核对关键截图：今日首屏、更多入口、餐食复用 sheet、餐食证据折叠/展开。记录截图导出目录。
- 不把原型中的示例数字或不存在的“食物数据库”当成已交付能力。
- 清理只删除测试自己创建的唯一 marker；不得删除用户或 Simulator 既有记录。

最终交互与视觉证据：

- UI attachments 导出目录：`/tmp/healthmanager-stage009-final-ui-attachments-20260714/`，包含 Today、More、Dashboard、饮食/用药编辑器、分项证据展开、常用克数、整餐与选中分项复用共 12 张原始 attachment。
- 已目视复核 Today、More、分项证据展开、整餐复用与选中分项复用；没有裁切、黑屏或丢失五栏。原始大图在缩放预览前保持不变。
- Today 的参考对照、Dynamic Type 和 accessibility raw audit 继续引用 `design-qa.md` 与 `/tmp/healthmanager-stage007d-visual-audit-accepted-20260714/`；不把空验收库的“暂无”状态外推为用户健康事实。

## 6. 真机清单与状态规则

以下项目必须在真实 iPhone 上逐项记录 PASS / FAIL / INCOMPLETE。未执行只能写 INCOMPLETE，不得由 Simulator 推断：

覆盖安装前还有一个不可跳过的安全硬门：必须记录近期备份成功状态，并确认恢复凭据/路径可用；同时确认候选配置的 Bundle ID 为 `com.norte.HealthManager`、签名 Team 为 `K8RVJSC4NU`，且候选签名的 `application-identifier` 前缀与设备上既有 App 一致，能够形成同一覆盖升级身份。任一项不能证明时，在安装前停止并将真机门保持 INCOMPLETE，不能用卸载重装绕过。

1. 既有用户数据库升级后，餐次、分项、照片路径、备注、`hk_sync_id` 和其他健康数据无损。
2. HealthKit 授权页、真实餐次营养样本写入、编辑更新和删除。
3. 已同步餐次清空全部营养后，旧 HealthKit 样本的真实删除结果与失败反馈。
   - **2026-07-15：PASS**（单独恢复点）详见 `docs/stages/STAGE-009R2-healthkit-nutrition-clear-recovery.md`，结果包见 `/tmp/healthmanager-stage009r2-device-delete-test-meal-ui-20260715-attempt02.xcresult`。
4. PhotosPicker / 相机导入、替换、保存、取消、删除后的真实文件生命周期。**PASS（2026-07-15）**：详见 `docs/stages/STAGE-009-item45-real-device-review-20260715.md`；相机与 PhotosPicker 各 1/1 真机通过，attempt09 前后照片文件、`meal_records.photo_path`、餐次总数均无净变化，一次性 marker 为 0。
5. VoiceOver 读序与操作、最大 Dynamic Type、餐食证据 44pt 点击区和 sheet 可用性。**INCOMPLETE（2026-07-15）**：最大 Dynamic Type 与 accessibility audit 1/1 通过，已修复 More 文本裁切；VoiceOver/44pt 专项尚未形成证据。
6. Apple Watch、iPhone 与第三方 sleepAnalysis 的跨午夜、inBed/asleep、详细阶段重叠和来源组合。**PASS（2026-07-15）**：5 个真实跨午夜窗口逐项映射、来源/阶段/状态约束与 `activity_metrics_daily` 连接断言通过；睡眠详情 UI 的周汇总与 DB 平均/最高/最低四舍五入一致。机器报告见 `/tmp/healthmanager-stage009-item45-device-20260715-attempt09/reports/item6-final-verification.txt`。
7. 后台 observer / 增量同步在真实 HealthKit 样本变化时的行为。**PASS（2026-07-15，自然真机证据）**：设备快照记录 `trigger=observer` 的 845 个成功作业，其中 656 个有新增样本，多个最近作业在同一窗口写入 raw samples，且快照时 `active_sync_jobs=0`；报告见 `/tmp/healthmanager-stage009-item45-device-20260715-attempt09/reports/item7-observer-evidence.txt`。受控 Health App 手工 marker 探针因 macOS 锁屏钥匙串 `errSecInternalComponent` 未完成，不将自然事件证据表述为该受控探针。

item4-7 的执行标准与证据格式详见：
- `docs/stages/STAGE-009-item4-7-real-device-checklist.md`

补充（2026-07-15）：
- item4-7 标准化收口快照：`/tmp/healthmanager-stage009-item45-device-20260715-attempt09`。
- item4 前后差分：照片文件 `133 -> 133`、照片引用 `63 -> 63`、餐次 `114 -> 114`、一次性 marker `0`、`integrity_check=ok`。
- item6 快照报告：`reports/item6-cross-midnight-windows.txt`；睡眠 UI xcresult：`/tmp/healthmanager-stage009-item6-sleep-20260715.xcresult`。
- item6 逐窗口映射：`reports/item6-window-ui-crosscheck.csv`，周视图显示值与 DB 汇总值四舍五入一致。
- item5 Dynamic Type xcresult：`/tmp/healthmanager-stage009-item5-ax-fixed2-20260715.xcresult`。

本轮已授权“软件与 Simulator 完成、真机次日执行”，因此允许最终写：**软件/Simulator PASS，真机 INCOMPLETE**。但整体发布就绪仍为 INCOMPLETE；不得 merge、tag 或 release。

## 7. HANDOFF 与文档门

最终验收需同步：

- 本文件的正式结果、结果包、截图目录和残余风险。
- `NEXT_TASK.md`：删除已完成的餐食持久化与睡眠效率旧待办，只保留真实下一阶段。
- `docs/planning/HEALTHMANAGER-ARCHITECT-CODER-WORKFLOW.md`：追加最终 checkpoint 与阶段状态，不篡改历史基线。
- v0.3 HANDOFF：只引用 ADR、STAGE、commit 与结果包，不复制已有长文；包含建议技能、次日真机顺序和失败时的停止条件。
- `git status` 必须干净，本地 HEAD 与 upstream 相同。

Durable handoff：`docs/handoffs/V0.3-SOFTWARE-SIMULATOR-HANDOFF-20260714.md`。另按 handoff skill 在 `/tmp/healthmanager-v0.3-next-session-handoff-20260714.md` 保存一个只引用 durable artifacts 的短入口。

## 8. Coder 边界

STAGE-009 不生成“让 Coder 跑一遍看看”的实现提示词。主架构师负责读取真实结果并作发布门判断。若任何必需项失败，再根据失败证据生成独立修复 STAGE 与 Coder 提示词；高风险迁移、HealthKit 幂等或跨进程恢复问题由主架构师接管。

## 9. 正式结果

- 软件 / Simulator：PASS
- 真机：INCOMPLETE（`item3` HealthKit 清空营养 PASS；`item4`、`item6`、`item7` PASS；`item5` INCOMPLETE）
- 发布就绪：INCOMPLETE（真机 item5 仍未闭环）
- 被测产品 commit：当前分支 HEAD（More 动态字号裁切修复 + 本轮真机验收记录）
- 验收文档 checkpoint：本文件所在 commit
- 全量证据：migration 6/6、unit 242/242、UI 6/6、独立 build 0 error / 0 warning；结果包见第 3、4 节。
- 视觉与数据库证据：UI attachments、STAGE-007D raw audit、`/tmp/healthmanager-stage009-final-db-audit-20260714.txt`；真实验收库 v1～v5、integrity ok、FK 0、测试/用户内容表 0。
- 残余风险：VoiceOver/44pt 专项仍为 INCOMPLETE；sleepAnalysis 五窗口与 UI 汇总交叉验证已 PASS；observer 已有自然真机增量与收敛 PASS，但尚未形成受控 Health App 手工 marker 的前后因果探针。照片文件生命周期与最大 Dynamic Type 审计已在真机证据中通过；HealthKit 写删第 3 项已在 `STAGE-009R2` PASS。
- Git 边界：本轮不 merge `main`、不打 tag、不创建 GitHub Release、不发布正式版本。
