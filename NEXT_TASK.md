# NEXT_TASK

> 当前状态（2026-08-22）：v0.5.1（build 11）已发布；修复体重等多来源原始样本重复记录（v7/v8 去重迁移）。详见 `docs/releases/v0.5.1.md` 与 `WORKLOG.md` 末尾。

## 当前没有必须自动继续的任务

- v0.5.0 四波次（证据语义色 / 趋势页加速 / SyncJobRecorder / 备份导出与恢复）已交付并真机验证。
- v0.5.1 修复：两个数据源 App（小米体重秤/米家 与 小米运动/Zepp）把同一次称重写入 Apple 健康时，会因 float 表示噪声（如 82.84999847 vs 82.85）产生重复条目；新增 v7/v8 迁移（`ROUND(value,3)` 容差 + 部分唯一索引），已折叠历史重复并从源头阻止再次记录。真机 8 月 22 日当日测量由 4 次降为 2 次。
- 测试：单元 297/297 通过、Debug/Release 构建 0 错误；真机（iPhone Air）安装启动后迁移自动执行、重复折叠验证通过。

## 待办（后续可选）

- [ ] 架构体检报告剩余候选按需排队：DayKey 下沉 Core（`DashboardLoader.dateKey` 被 Core 反向引用的分层问题）、MealHealthKitSync 合并（餐食→HealthKit 副作用双实现）、同步编排器采样 seam（三个 coordinator 零单测）、SyncStateMachine 去浅化。
- [ ] `MetricPresentation` 扩展：`lowerIsBetter` 中文标题开关改 metric enum 驱动、bmiCaption 分档收进模块。
- [ ] 备份包增量导出（目前全量重写，数据量大后可考虑 delta）。
- [ ] 如需多设备读取场景，评估备份包加密选项（当前明文，用户已知情同意）。

## 稳定边界（不变）

- 没有修改已应用的迁移（v6 为新增）；没有改 HealthKit、同步状态机、营养/能量算法或既有持久化合同。
- 备份包契约 formatVersion 1：字段只增不改；未知格式版本拒绝导入；投影表覆盖导入、用户表只补缺。
- 备份不包含照片、原始样本、API Key 与运维表（sync_jobs / backfill_report / sync_anchors）。
- 社区、排行、挑战、电商、广告、课程、自动目标、健康评分和未经验证的健康结论继续明确排除。
- Simulator 证据不能外推真实 iPhone 的系统文件选择器、iCloud Drive 书签与后台导出行为（本版本已真机验证）。
