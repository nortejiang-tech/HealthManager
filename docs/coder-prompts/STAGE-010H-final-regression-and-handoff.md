# 给内部 Coder：STAGE-010H 最终回归、审查与交接

你只执行 `/Users/nortepro/HealthManager/docs/stages/STAGE-010H-final-regression-and-handoff.md`。这是 UI 改版最后一个阶段，不是新一轮实现。

## 必须先读

1. `docs/design/2026-07-16-ui-redesign-design-contract.md`
2. `docs/adr/ADR-002-evidence-led-functional-ui-language.md`
3. `docs/stages/STAGE-010A-ui-foundation-and-root-states.md` 至 `STAGE-010G-accessibility-dark-and-visual-regression.md`
4. `NEXT_TASK.md`
5. `docs/planning/HEALTHMANAGER-ARCHITECT-CODER-WORKFLOW.md`

## 唯一目标

以 `main @ 3e657fa` 为固定点，审计当前未提交 tracked diff 与全部 untracked 交付文件；完成正式构建、定向、全量 258 项、临时 seam 扫描和文档状态统一，生成最终 UI 改版 handoff。

## 允许范围

- 010H 任务 / 提示词、设计合同、工作流、`NEXT_TASK.md`、`design-qa.md` 和最终 handoff；
- 只有双轴审查发现阻断交付的既有 UI / accessibility 缺陷时，才允许最小修改对应 `UI/` 与永久测试。

## 禁止范围

- 不得修改 `Core/`、store / loader、数据库、schema、HealthKit、同步、通知、LLM、计算、持久化、版本或发布合同；
- 不得新增页面、功能、假数据、production QA route、截图专用 seam 或装饰性视觉；
- 不得 commit、tag、push、发布或安装真机。

## 必须验证

1. `git rev-parse 3e657fa`、`git status --short`、`git diff 3e657fa --`、`git diff --check`。
2. 独立 Standards / Spec 双轴审查；报告阻断发现并收敛到 0。
3. 扫描临时视觉测试、QA route、fixture、debug flag、硬编码截图状态；不得保留仅为验收存在的生产 seam。
4. `xcodegen generate`。
5. iPhone 17 / iOS 26.5 Simulator 正式构建、定向测试与完整 `xcodebuild test`；以 `xcresulttool` 报告计数为准。
6. 检查 010A～010H、设计合同、`NEXT_TASK.md`、工作流、Design QA 与最终 handoff 状态、链接和边界一致。

## 输出

返回实际 diff、双轴审查结果、构建与测试计数、xcresult 路径、临时 seam 扫描、未验证边界和最终 handoff 路径。任何子项证据不足时必须写 `INCOMPLETE`，不能用其他通过项掩盖；不得自行宣布发布完成。
