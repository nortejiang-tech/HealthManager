# NEXT_TASK

> 当前状态（2026-07-15）：v0.3.0（build 8）发布门已 PASS；正式发布版本包含 v0.3 全部可信记录基础、真机收口修复，以及历史备注餐次在复用列表中的内容展示修复。

## 唯一下一任务：定义 v0.4 的首个可验证探索

下一轮先做产品与技术决策，不直接进入实现。主架构师需基于现有用户需求边界和 [竞品研究](docs/research/2026-07-13-health-app-competitor-primary-research.md)，从以下候选中选择一个最有价值、最小可验证的方向：

1. FoodDataSource seam、数据许可、离线策略和版本化。
2. 许可清晰的食品候选与个人食品；只有该基础成立后，才评估营养标签 OCR、条码和份量换算。
3. 本地个人纠正记忆、App Intent / Shortcut / 可选 Watch 快捷动作。
4. 一条来源可追溯、可忽略的今日简报。
5. 能量消耗 shadow mode；只做影子比较，不自动改变用户目标。

## 进入 Coder 前的硬门

- 先明确用户问题、非目标、证据来源、隐私边界和成功指标。
- 涉及新数据模型、第三方数据集或同步语义时，先建立 ADR；未经接受不得改 schema 或引入依赖。
- 先用原型、只读数据分析或小范围技术探针验证价值，再生成唯一 STAGE 的 Coder 提示词。
- 不因薄荷健康、Elevate 或其他竞品已有某功能就直接复制；竞品只提供实现证据和体验参考，产品取舍继续以本产品需求为主。

## v0.3 稳定边界

- 版本：`v0.3.0` / build `8`。
- 数据库迁移：v1～v5；不得原地修改，新增 schema 只能追加 v6。
- 最终自动化：HealthManagerTests 251/251、HealthManagerUITests 7/7。
- 最终构建：Simulator Release 与真实 iPhone Release 均为 0 error / 0 warning。
- 真机覆盖安装：Bundle ID `com.norte.HealthManager`、Team `K8RVJSC4NU`；升级后数据库完整性 `ok`，115 条餐次、43 条历史备注餐次、0 条测试餐次、0 个孤儿分项。
- 发布说明：[v0.3.0](docs/releases/v0.3.0.md)。

社区、排行、挑战、电商、广告、课程、自动减重目标和未经验证的健康评分继续明确排除。
