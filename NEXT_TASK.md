# Latest: Apple Health 锁屏后 stale deferral 已修复并装入真机

2026-09-21：真实后台任务在锁屏期收到 HealthKit code 6 后把 28 类任务挂起；旧实现解锁后只增加 requested generation，没有恢复 `waitForUnlock`，因此同步中心持续显示已经过期的等待解锁状态。现已让新的 foreground/background/manual/retry 执行机会恢复该类 deferral，observer 仍保持 parked，其他授权/修复/失败状态不会被误清除。最终完整回归 `440/440`，签名真机覆盖安装后 app 自动作业成功，数据库 `quick_check=ok`、`pending=0`、`waitForUnlock=0`、全部 generation 收敛；修复前后证据见 `STAGE-RESULTS.md`。

下次解锁后只需执行四类操作：

1. 同一真机对基线/候选各做至少 20 次进程冷启动，记录首批有效卡片、snapshotAvailable、首次新数据可见，计算 p50/p95/max。
2. 外部来源写入后的前台追新和后台预算中断后前台恢复各 3 轮；锁屏失败后解锁恢复已完成真实 `1/3`，再做 2 轮。全程不点击手动同步。
3. 对照升级前后 raw UUID 摘要、anchor、饮食 syncID、历史删除、Bridge acknowledged sequence 和备份恢复结果。
4. 真机当前已从 338 条餐次增长到 339 条、item 从 664 增至 666；仍需在界面确认最新餐次可打开，再在隔离目录完成 backup bookmark save/load/clear round-trip。

详细操作见 `docs/planning/2026-09-20-apple-health-sync-review/design/S13-DEVICE-ACCEPTANCE-RUNBOOK.md`，证据见同目录 `STAGE-RESULTS.md` 的 S13。不要重新回补、reset Bridge、删除记录或把一次成功当整体 PASS。

# Previous: 0.8.1 (16) snapshot crash hotfix installed

Read docs/healthbridge/STAGE-FIX-snapshot-memory.md first. Snapshot autoreleased JSON objects exceeded iPhone memory limit; actual60000-record failing regression fixed,600000 pressure PASS.331 iOS/12 Mac tests PASS. Device successfully launched, same PID survived repeated checks and real batches are being ingested. Do not re-backfill/reset records. Full snapshot receipt and sustained stability PENDING.

# 当前交接：HealthBridge 0.8.0 (15)

2026-09-19：软件和合成测试已通过，设备首次 iCloud 同步、OpenClaw 实际调用及48小时观察 **PENDING**。继续前先读 [HealthBridge HANDOFF](docs/healthbridge/HANDOFF.md)。已安装 Mac 接收器和 iPhone 新版；需用户解锁、选择 iCloud 文件夹并开启同步。不要重复部署、抢 OpenClaw 迁移锁或把安装成功当端到端通过。

---

以下保留上轮0.7.1交接，属于历史状态：

# NEXT_TASK

> 当前状态（2026-09-18）：**v0.7.1（build 14）已完成真机安装与用户验收**——在 v0.7.0 基础上追加「USDA 每份总营养」（官方 foodPortions 显示与记录预填，v11 迁移）；v0.7.0/0.7.1 交付内容：参考食材增删、USDA 可信检索添加、可编辑推测配方。——参考食材增删、USDA 可信检索添加、可编辑推测配方三项全部交付；用户已在手机配置 USDA key 并试用通过。tag `v0.7.0` 已打；正式分发按用户既有流程执行。
> 本轮依据 `docs/planning/2026-09-18-营养表增删与配方推测.md` 与 ADR-005；验证记录见 `WORKLOG.md` 末尾与 `docs/releases/v0.7.0.md`。

## 当前没有必须自动继续的任务

- 模拟器验证：`HealthManagerTests` 329/329、SmokeTests 通过（iPhone 17 Pro / iOS 26.5）。
- 真机（NortePro的iPhone）：0.7.0（13）Release 覆盖安装并启动；v10 迁移/种子/快照回填自动执行；用户完成 USDA key 配置与黑巧克力等流程试用。
- 真实官方检索取证：`docs/food-catalog/usda-evidence/`（foods/search + food/170273，2026-09-18）。

## 待办（后续可选）

- [ ] 词典扩充：真机使用中发现查不到的常见中文食物词，追加进 `food_search_dictionary_v1.json`（随下一版本发布）。
- [ ] 资料新版本提示：数据层已支持成员版本指针 + 新版本行，可做「有新版本，显式采用」UI 入口。
- [ ] 体重卡升级为近 7/30 天可切换主趋势图（2026-09-17 方案 §6.2 下一阶段）。
- [ ] USDA 品牌标签类数据：需先定义「每份→每100g」的换算依据，再开检索。
- [ ] 交互指标本地聚合页（需真实使用证据后再评估）。
- [ ] 架构体检遗留项：DayKey 下沉 Core、MealHealthKitSync 合并、同步编排器采样 seam。

## 稳定边界（不变）

- 未修改已应用迁移 v1~v9（新增 v10）；未改 HealthKit 同步、同步状态机、既有持久化合同。
- 备份包契约 formatVersion 3：字段只增不改；旧 App 遇更高版本拒绝导入；新 App 兼容导入 v1/v2。
- 历史餐次快照不随目录/资料/参考表变化重算（配方原料带完整营养快照）；AI 估算未批量升级；未知值/生熟/来源版本全部保留。
- 备份不含照片、原始样本、API Key（LLM 与 USDA key 均在 Keychain）与运维表。
- 模型在推测配方中只建议原料与用量（最高「估计」状态），不输出营养值、不写历史；社区、排行、电商、健康评分等继续明确排除。
