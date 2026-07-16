# 给内部 Coder：STAGE-010G 全量无障碍、深色与视觉回归

你只执行 `/Users/nortepro/HealthManager/docs/stages/STAGE-010G-accessibility-dark-and-visual-regression.md`，不得进入 010H。主会话是架构师与最终验收者。

开始前必须读取任务书、全页面设计合同、ADR-002、`UI/DesignSystem/HMDesignSystem.swift`、永久 `UITests/SmokeTests.swift`，并复用 010A～010F 已归档视觉证据。不得从示例图硬编码数据。

只修固定运行矩阵真实捕获的纯视图 / accessibility 问题。禁止修改 Core、store / loader / manager、数据库、HealthKit、同步、通知、LLM、计算、持久化和副作用调用关系；若问题需要业务状态才能修复，停止该项并报告。

先处理两个已观察问题：accessibility-extra-large 下长 `HMEvidenceTag` 的夸张胶囊形态，以及带 trailing 状态 / 时间的 `HMInformationRow` 可能挤压正文。正文必须继续使用 Dynamic Type，只允许调整容器形状、自适应轴、间距和非文本图标视觉尺寸。

随后按任务书固定矩阵运行 light / dark / accessibility-extra-large / Reduce Motion 的真实 UI 流程；每个修复保留前后运行证据。临时视觉 / accessibility audit test 结束前删除并重新生成工程。运行独立 build、定向测试、永久 Smoke、全量测试与 `git diff --check`。

只报告修改范围、合同保持、矩阵证据和未验证边界；不要自行宣布 PASS，不 commit / tag / push，完成后停止，不进入 010H。
