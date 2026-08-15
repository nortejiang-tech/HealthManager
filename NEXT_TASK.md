# NEXT_TASK

> 当前状态（2026-08-16）：v0.5.0（build 10）已发布；架构优化轮（波次 1-4）+ 数据备份/恢复全流程在真实 iPhone 上闭环验证。详见 `docs/releases/v0.5.0.md` 与 `WORKLOG.md` 末尾。

## 当前没有必须自动继续的任务

- 四波次（证据语义色 / 趋势页加速 / SyncJobRecorder / 备份导出与恢复）已交付并真机验证。
- 真机实测暴露的三个问题已全部修复：iOS 文件夹选择器（FolderPicker）、重装后空投影行遮挡 30–90 天数据（投影表覆盖导入 + 启动补算跳过无原始样本情形）、配置丢失（settings.json + Keychain 书签）。
- 测试：单元 290/290、UI 7/7、Debug/Release 构建 0 错误。

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
