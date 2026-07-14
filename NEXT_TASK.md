# NEXT_TASK

> 当前状态（2026-07-15）：分支 `codex/health-planning-20260713` 的 v0.3 软件 / Simulator 验收已 PASS；被测产品 commit 为 `2e3b038c4d5722d507874feaea90002fc2379e66`。真机清单中 `item3`（已同步餐次清空营养样本删除）已完成 PASS；剩余项待执行，发布就绪继续 INCOMPLETE。

## 唯一下一任务：v0.3 真机验收

下一会话不再实现 STAGE-007C/007D，也不生成“让 Coder 再跑一遍”的提示词。主架构师必须按以下文档在真实 iPhone 上逐项取证：

- 发布门与七项真机清单：`docs/stages/STAGE-009-v03-release-gate.md`
- 真机 item4-7 逐项动作与证据：`docs/stages/STAGE-009-item4-7-real-device-checklist.md`
- 次日交接：`docs/handoffs/V0.3-SOFTWARE-SIMULATOR-HANDOFF-20260714.md`
- Today 视觉与可访问性边界：`design-qa.md`
- 餐食 schema 决策：`docs/adr/ADR-001-normalized-meal-item-snapshots.md`

执行顺序：

1. 不卸载现有 App、不清库；先记录设备、系统、现有版本与当前关键数据快照。安装前必须同时证明：近期备份已成功完成且恢复凭据/路径可用；候选配置的 Bundle ID 为 `com.norte.HealthManager`、签名 Team 为 `K8RVJSC4NU`，且候选签名的 `application-identifier` 前缀与设备上既有 App 一致，能够形成同一覆盖升级身份。任一项无法证明，标为 INCOMPLETE 并在安装前停止。
2. 在保留既有用户数据的前提下安装候选，验证启动与 v1～v5 追加迁移后餐次、分项、照片路径、备注、`hk_sync_id` 和其他健康数据无损。
3. （已完成）验证 HealthKit 授权、餐次营养写入、编辑更新、删除，以及“已同步餐次清空全部营养”后的旧样本删除与错误反馈。
4. 验证 PhotosPicker / 相机导入、替换、保存、取消、删除后的真实文件生命周期。
5. 验证 VoiceOver 读序与操作、最大 Dynamic Type、44pt 点击区、Today planned/action time 区分和复用 sheet。
6. 用真实 Apple Watch / iPhone / 第三方 sleepAnalysis 数据验证跨午夜、inBed/asleep、详细阶段重叠与来源组合。
7. 验证真实 HealthKit 样本变化后的后台 observer / 增量同步。

任何未执行项只写 INCOMPLETE。备份不可确认可恢复，或候选与既有 App 的 Bundle/签名身份不能证明为同一路径时，不得开始覆盖安装。出现迁移崩溃、数据丢失、HealthKit 重复/误删、照片孤儿、权限异常或可访问性阻断时立即停止，不通过卸载重装、清库或手工补数据掩盖问题；保留证据并建立唯一目标的修复 STAGE。

## 当前验收基线

- migration：6/6，`/tmp/healthmanager-stage009-final-migrations-20260714-attempt01.xcresult`
- unit：242/242，`/tmp/healthmanager-stage009-final-unit-20260714-attempt01.xcresult`
- UI：6/6，`/tmp/healthmanager-stage009-final-ui-20260714-attempt01.xcresult`
- independent build：0 error / 0 warning，`/tmp/healthmanager-stage009-final-build-20260714-attempt01.xcresult`
- UI attachments：`/tmp/healthmanager-stage009-final-ui-attachments-20260714/`
- Simulator 主库审计：`/tmp/healthmanager-stage009-final-db-audit-20260714.txt`

只有七项真机清单全部有真实 PASS，才能另行评估发布；其中 `item3` 当前已 PASS，后续目标为 `item4-7`。本轮授权不包含 merge `main`、tag、GitHub Release 或正式发布。

## 若真机发现缺陷

- 先由主架构师定位到 migration、HealthKit、照片、可访问性、睡眠聚合或后台同步中的唯一责任域。
- 建立独立修复 STAGE、允许文件、失败后置条件与 Coder 提示词；不得直接在 STAGE-009 文档中顺手改产品代码。
- 数据迁移、HealthKit 幂等、跨进程恢复或真实数据丢失风险由主架构师接管；低风险 UI/文案修复才交给低成本 Coder。

## v0.4 候选（不得提前实施）

1. FoodDataSource seam、数据许可、离线策略和版本化的新 ADR。
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
- PASS / FAIL / INCOMPLETE 必须与真实设备、xcresult、数据库或文件生命周期证据一一对应。
