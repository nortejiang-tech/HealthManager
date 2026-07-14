# NEXT_TASK

> 当前状态（2026-07-14）：分支 `codex/health-planning-20260713` 已完成并推送 STAGE-001～006 与 STAGE-008；当前已验收的软件实现基线为 `ff67ca1`。STAGE-007A 已接受方案 1「按时间展开的健康证据线」。

## 当前执行阶段

STAGE-007B 先修正 Today 会使用的饮食与热量缺口数据合同：

- 任务书：`docs/stages/STAGE-007B-trustworthy-diet-energy-contract.md`
- Coder 提示词：`docs/coder-prompts/STAGE-007B-trustworthy-diet-energy-contract.md`
- 核心要求：未知营养不变成 0；active、basal、完整 intake 三者齐备才计算缺口；合法 0 仍是已知。

STAGE-007B PASS 后再根据 accepted diff 生成 STAGE-007C Today evidence loader 提示词；STAGE-007C PASS 后才生成 STAGE-007D 时间线与五栏导航提示词。

## 随后的发布门

STAGE-009 已完成迁移预检，但最终门必须等待 STAGE-007D PASS：

- 任务书：`docs/stages/STAGE-009-v03-release-gate.md`
- 最终 HEAD 重跑全量 unit、全量 UI、独立 build、截图与实际 Simulator 数据库审计。
- 软件 / Simulator 可以独立判 PASS；未执行的真实 HealthKit、照片、可访问性、后台同步和 sleepAnalysis 组合必须逐项写 INCOMPLETE。
- 本轮不 merge `main`、不打 tag、不发布正式版本。

## v0.4 候选（不得提前实施）

1. 食品来源 seam、许可、版本和离线策略的新 ADR。
2. 许可清晰的食品候选与个人食品；之后才考虑营养标签 OCR、条码和份量换算。
3. 本地个人纠正记忆、App Intent / Shortcut / 可选 Watch 快捷动作。
4. 一条来源可追溯的今日简报。
5. 能量消耗 shadow mode；只做影子比较，不自动改目标。

社区、排行、挑战、电商、广告、课程、自动减重目标和未经验证的健康评分继续明确排除。

## 工程提醒

- 永远不要原地修改 v1～v5 已应用迁移；新增 schema 只能追加 v6。
- 新增源文件或修改 `project.yml` 后必须跑 `xcodegen generate`。
- 当前依赖只有 GRDB；引入新依赖前先评估必要性、包大小与维护成本。
- API key 绝不进 repo；LLM 配置走 Keychain，Simulator Keychain 失败时才按既有逻辑 fallback。
- 每个阶段必须保留实际 xcresult、区分 PASS / FAIL / INCOMPLETE，并由主架构师检查真实 diff、全量回归与运行数据库副作用。
