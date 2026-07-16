# NEXT_TASK

> 当前状态（2026-07-16）：v0.4.0（build 9）发布候选已完成全量回归、Release 构建、真实 iPhone 覆盖安装、启动与数据保持验证；用户已明确授权发布，Git / GitHub 收尾正在执行。

## 当前唯一任务：完成 v0.4.0 发布收尾

本轮已完成根状态、五个一级页面、记录与计划编辑、趋势 / 证据 / 运维详情、设置 / AI / 权限、卡片编辑、全 App 深色与 Dynamic Type / Reduce Motion 审计，以及最终双轴审查和 258 / 258 全量回归。最终人工反馈也已纳入：趋势页把来源轨道移至底部，饮食页移除重复的大型新增 / 复用按钮。

- [最终实施交接](docs/handoffs/UI-REDESIGN-IMPLEMENTATION-HANDOFF-20260716.md)
- [STAGE-010H：最终回归、审查与交接](docs/stages/STAGE-010H-final-regression-and-handoff.md)
- [STAGE-011：v0.4.0 UI 发布](docs/stages/STAGE-011-v040-ui-release.md)
- [v0.4.0 发布说明](docs/releases/v0.4.0.md)
- [全页面设计合同](docs/design/2026-07-16-ui-redesign-design-contract.md)
- [ADR-002：证据型功能视觉语言](docs/adr/ADR-002-evidence-led-functional-ui-language.md)

## 已授权且正在执行的收尾

1. 创建 v0.4.0 产品提交与 annotated tag。
2. push `main` 与 `v0.4.0`，创建私有仓库 GitHub Release。
3. 回填 STAGE-011、交接和协作总图，确保仓库状态与外部发布结果一致。

## 稳定边界

- 真实 iPhone 已覆盖安装 `0.4.0 (9)` 并验证启动与数据库保持；GitHub Release 在本任务收尾前仍是 pending。
- 本轮没有修改 `Core/`、数据库 schema、HealthKit、同步、通知、营养 / 能量算法或持久化合同。
- Simulator 证据不能外推真实 iPhone VoiceOver 操作手感、触觉、系统权限面板、第三方 App 或长期升级行为。
- 社区、排行、挑战、电商、广告、课程、自动目标、健康评分和未经验证的健康结论继续明确排除。
