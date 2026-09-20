# EVO-Coder 调用报告

## 汇总

- 监督器通过率：`0/5`
- 首次独立验收通过率：`0/5`
- 有用产出采纳率：`4/5`
- 直接接受：`0`
- 部分接受并补改：`4`
- 拒绝：`1`
- 待审：`0`

## 2026-09-20 后续根因与恢复

前三次历史调用的失败状态保持不变，但工具层根因已由 Planner 在
`Local Network Manager/evo-x2-prep/stages/STAGE-036-EVO-CODER-PROMPT-CONTRACT-RECOVERY-2026-09-20.md`
修复并重新准入：

1. S02/S03 使用了依赖提示词文件位置的“上级目录”描述，而 Pi 实际 cwd 是仓库根，
   模型据此尝试了逃逸路径；S04A 改成明确仓库根相对路径后该错误消失。
2. guard 曾逐项过滤验证命令。Xcode 命令中的外部 DerivedData 路径使第二项被删除，
   但模型仍按原始两项列表调用索引 1，因此得到 `VERIFY_INDEX_NOT_ALLOWED`。
3. 现在验证列表按原索引原子解析，合同在 Pi/模型启动前检查；无效合同以固定代码、
   0 turns/0 tools/0 writes 失败。Xcode DerivedData 仅对 Planner 精确声明的 verify
   命令开放，文件工具仍限制在仓库内。
4. 生产负向 preflight 和真实 EVO canary 均通过；真实调用 run_id
   `24c2495e-b24c-4c4c-b026-89275cf24309` 为 `PASS`、2/2 验证、无 guard violation，
   并通过 Planner 独立复核。

该修复恢复后续合格窄阶段的 EVO 路由，不追溯性地把前三次调用改写成成功，也不改变
S02–S04A 当时需要 Planner 补改的代码质量结论。S13 真机验收发现新缺陷后又启动了两次
受控调用：第一次暴露提示词读取白名单仍不完整，第二次避开路径门禁但撞到工具上限；两次
都没有取得监督器 PASS。

## S02 — 首屏阶段计时

- run_id：`a97074a7-85db-4c48-841e-277269d3940a`
- 模型：`halogen-qwen3.8-flash-next`（EVO-X2）
- 可核实参数：temperature `0`、top_p `1`、max output `4096`；`max_context_tokens=16012` 是监督器记录的上下文高水位，不作为总 token 消耗。
- 提示词 SHA256：`5c33a5c2501e9823242a811e14c0fd61432cccf144df294033bdfad31eac1f1b`
- 工作树基线：HEAD `1479db9e8aec80db1c557130315bcd0cb9e74949`，直接在保留既有 dirty 内容的当前工作树运行。
- 写入白名单：`Core/Diagnostics/StartupMetrics.swift`、`App/AppEnvironment.swift`、`UI/Dashboard/DashboardView.swift`
- 实际修改：`Core/Diagnostics/StartupMetrics.swift`
- 耗时：`72.361s`；回合：`12`；工具调用：`16`
- Coder 验证：`0/2` 次声明验证通过，实际未运行验证。
- 停止：Planner 在监督器报告 `PATH_ESCAPE_DENIED` 后发送 SIGINT；最终 `status=FAIL`、`classification=LOCAL_POSTWRITE_FAILURE`、`failure_reason=INTERRUPTED`，账本同时记录 guard code `PATH_ESCAPE_DENIED`。
- 采纳判断：`部分接受并补改`。StartupMetrics 主体保留；Planner 补上 Hashable 合同、修复日志编译失败，并完成 AppEnvironment/Dashboard 接线。
- 首次独立验收：失败，编译器不能在合理时间内类型检查 Coder 的拼接日志表达式。
- 最终 Planner 验收：声明聚焦测试 `5/5` 通过，`git diff --check` 通过，Bridge 与恢复顺序检查通过。
- 返工原因：Coder 在 guard violation 后仍只完成单一源文件；源文件未自行编译，且没有完成两个接线文件。
- 路由结论：该次 guard violation 不自动重试或切换模型；由 Planner 接管 S02。后续阶段重新建立信任门，但不把本次失败视为模型长期能力结论。

## S03 — 纯请求合并与公平调度状态

- run_id：`717fb03d-315f-48fe-b81f-23a5baf76a96`
- 模型：`halogen-qwen3.8-flash-next`（EVO-X2）
- 可核实参数：temperature `0`、top_p `1`、max output `4096`；`max_context_tokens=16201` 仅是监督器上下文高水位。
- 提示词 SHA256：`85cb85158140fe114223db235ae99b93c7df5ca3343cb3925fdcf7597e3376bb`
- 写入白名单：`Core/Sync/SyncDemand.swift`、`Core/Sync/SyncSchedulingState.swift`
- 实际修改：`Core/Sync/SyncDemand.swift`
- 耗时：`68.835s`；回合：`11`；工具调用：`17`
- Coder 验证：`0/2`，实际未运行。
- 停止：读取阶段再次出现 `PATH_ESCAPE_DENIED`，Planner 发送 SIGINT；最终 `status=FAIL`、`classification=LOCAL_POSTWRITE_FAILURE`、`failure_reason=INTERRUPTED`。
- 采纳判断：`部分接受并补改`。保留 demand/reason/claim/error 值类型；Planner 增加无 active worker 错误并实现完整 reducer。
- 首次独立验收：失败，Coder 未创建 `SyncSchedulingState.swift`，锁定测试无法编译。
- 最终 Planner 验收：聚焦测试 `9/9` 通过，纯状态依赖审计与 `git diff --check` 通过。
- 返工原因：连续第二次路径 guard violation；Coder 未进入 reducer 实现和验证。
- 路由结论：不重试 S03。后续本地 Coder 提示词必须去掉父路径/绝对读取表达，明确只用仓库根相对路径；若受控准入仍复现，后续阶段全部由 Planner 接管。

## S04A — HealthKit 错误分类

- run_id：`5cdc697f-99a4-4db0-bdbc-323fba02c34d`
- 模型：`halogen-qwen3.8-flash-next`（EVO-X2）
- 可核实参数：temperature `0`、top_p `1`、max output `4096`；`max_context_tokens=16322` 仅是监督器上下文高水位。
- 提示词 SHA256：`6b7d52f8a79bb67ac1f5ec9d4e65a6c736dd0ffd48e8cb3a951df9ff0b4c04f3`
- 写入白名单与实际修改：`Core/Sync/SyncFailurePolicy.swift`
- 耗时：`70.172s`；回合：`11`；工具调用：`13`
- Coder 验证：监督器记录 4 次 verify 调用、`0/2` 通过；两次 `VERIFY_INDEX_NOT_ALLOWED`。
- 停止：Planner 在重复未授权 verify index 后发送 SIGINT；最终 `status=FAIL`、`classification=LOCAL_POSTWRITE_FAILURE`、`failure_reason=INTERRUPTED`。
- 采纳判断：`部分接受并补改`。分类器主体保留；Planner 修复未知 Objective-C enum raw value 被 default 误判为 failure 的问题。
- 首次独立验收：失败，`test_unknownHealthKitCodeIsPreserved` 未通过。
- 最终 Planner 验收：聚焦测试 `9/9` 通过，消息匹配审计与 `git diff --check` 通过。
- 路由结论：受控重新准入消除了当次 PATH_ESCAPE，但仍触发验证门禁。S04B–S12 和 S13 初始验收由 Planner 直接接管；S13 真机暴露新缺陷后按已恢复的路由再试两次，结果单独记录如下。

## S04B — 未调用 EVO

- 原因：查询取消、deadline 与 continuation 竞争属于设计中明确的 `PLANNER_OWNED` 并发边界；前三次 EVO 调用又连续触发监督器 guard violation。
- 执行：Planner 直接实现并验收；不计入三项 Coder 比率的分母。
- 验收：聚焦测试 `14/14` 通过。

## S05 — 未调用 EVO

- 原因：持久代次、restore barrier 与样本/删除/anchor/dirty 的单事务提交属于设计中明确的 `PLANNER_OWNED` 数据一致性边界；此前 EVO 已连续三次触发监督器 guard violation。
- 执行：Planner 直接实现并验收；不计入三项 Coder 比率的分母。
- 验收：迁移、故障注入、进程重开、恢复兼容与备份边界合计 `12/12` 通过。

## S06 — 未调用 EVO

- 原因：HealthKit anchor 解码、分页预算和页级事务推进属于 `PLANNER_OWNED` 一致性边界；此前 EVO 已连续三次触发监督器 guard violation。
- 执行：Planner 直接实现并验收；不计入三项 Coder 比率的分母。
- 验收：分页、删除-only、续跑、重复、失败保留 anchor 与损坏 anchor 证据合计 `15/15` 通过。

## S07 — 未调用 EVO

- 原因：唯一 worker 所有权、durable generation 与取消语义属于 `PLANNER_OWNED` 并发边界；此前 EVO 已连续三次触发监督器 guard violation。
- 执行：Planner 直接实现并验收；不计入三项 Coder 比率的分母。
- 验收：忙时再请求、1000 observer 合并、取消/失败释放与 startup gate 合计 `13/13` 通过。

## S08A — 未调用 EVO

- 原因：App launch、恢复门、授权门与 observer 启动顺序属于 `PLANNER_OWNED` 生命周期边界；此前 EVO 已连续三次触发监督器 guard violation。
- 执行：Planner 直接实现并验收；不计入三项 Coder 比率的分母。
- 验收：全部事件排列、失败恢复、前台 epoch 与旧用户本地首屏合计 `7/7` 通过。

## S08B — 未调用 EVO

- 原因：Observer/BG completion、expiration 竞争和系统 delivery 语义属于 `PLANNER_OWNED` 生命周期边界；此前 EVO 已连续三次触发监督器 guard violation。
- 执行：Planner 直接实现并验收；不计入三项 Coder 比率的分母。
- 验收：durable handoff、一次性 completion、有限重试与锁屏 fan-out 合计 `9/9` 通过。

## S09 — 未调用 EVO

- 原因：dirty generation、恢复数据证据保全和投影发布事务属于 `PLANNER_OWNED` 数据一致性边界；此前 EVO 已连续三次触发监督器 guard violation。
- 执行：Planner 直接实现并验收；不计入三项 Coder 比率的分母。
- 验收：增量日期、历史删除、DST/时区、代次竞争和既有聚合口径合计 `32/32` 通过。

## S10 — 未调用 EVO

- 原因：在前三次监督器 guard violation 后，用户授权 Planner 连续执行；该阶段又跨共享 runner、两次子作业与可取消用户等待 seam，Planner 直接接管。
- 执行：重构手动双 pass 合并和 one-shot waiter；没有再次启动本地 Coder，不计入三项比率分母。
- 验收：聚焦回归 `17/17` 通过，采纳状态 `直接由 Planner 实现并接受`。

## S10B — 未调用 EVO

- 原因：备份导入前的 writer 排空、durable restore marker 和失败后保持暂停属于 `PLANNER_OWNED` 恢复一致性边界。
- 执行：Planner 直接实现；没有再次启动本地 Coder。
- 验收：新增恢复集成断言均通过；声明组合 `18 passed, 1 failed`，唯一失败是未签名测试宿主 Keychain `-34018`，阶段保持 `PENDING`。

## S11A — 未调用 EVO

- 原因：receipt 校验、同字节重放、7 天保留和跨进程公平 cursor 属于协议/数据保全边界，且此前监督器已连续触发 guard violation。
- 执行：Planner 直接实现 metadata/payload 分离与双 lane 有界维护；没有再次启动本地 Coder。
- 验收：聚焦 `5/5`、HealthBridge 完整 package `20/20` 通过。

## S11B — 未调用 EVO

- 原因：App scene、首轮 snapshot、后台无页面机会与 projection version 提交跨多个生命周期 seam；Planner 直接接管，避免在 dirty worktree 中再次触发监督器 guard。
- 执行：增加纯 startup maintenance gate，并补充 `runCatchUpAggregation -> Bool` 的必要接口扩展。
- 验收：聚焦 `16/16` 通过。

## S12 — 未调用 EVO

- 原因：该阶段依赖 S08B/S09/S10 的最终 durable 状态语义；Planner 直接建立纯显示映射和只读 runtime evidence，避免便宜 Coder 重新解释业务成功条件。
- 执行：没有再次启动本地 Coder。
- 验收：聚焦 `14/14` 通过。

## S13 — 真机缺陷修复调用 1

- run_id：`471d6f95-5cc3-49ad-a2bf-e0df68f4d6da`
- 模型：`halogen-qwen3.8-flash-next`（EVO-X2）。
- 可核实参数：temperature `0`、top_p `1`、max output `4096`；`max_context_tokens=26718` 是监督器记录的上下文高水位，不能作为总 token 消耗。
- 提示词 SHA256：`553c956f4cc345c45e0abafb06e68d097207ef400802898aad2d7332c7bef7e2`；配置哈希由 secret-free 账本保留。
- 工作树基线：HEAD `1479db9e8aec80db1c557130315bcd0cb9e74949`，直接在保留既有 dirty 内容的当前工作树运行。精确写入白名单没有进入 secret-free 账本，记为 `unavailable`；实际修改路径为空。
- 耗时 `72.714s`；回合 `15`；工具调用 `17`；验证 `0` 次。
- 停止：模型在写文件前尝试读取提示词未明确列入可读依赖的路径，监督器记录 `OTHER_GUARD_VIOLATION` 和 `PATH_ESCAPE_DENIED`；Planner 发送 SIGINT。最终 `status=FAIL`、`classification=LOCAL_PREWRITE_FAILURE`、`failure_reason=INTERRUPTED`。
- 采纳判断：`拒绝`。没有代码输出可采纳，首次独立验收失败。
- 路由结论：EVO 服务、模型加载和认证本身可用；失败根因是该次任务提示词的精确读取边界仍不完整。Planner 补全仓库根相对读取路径后，才启动第二次调用。

## S13 — 真机缺陷修复调用 2

- run_id：`34a2684d-52f4-40d8-90ff-26625992aa73`
- 模型：`halogen-qwen3.8-flash-next`（EVO-X2）。
- 可核实参数：temperature `0`、top_p `1`、max output `4096`；`max_context_tokens=33731` 仅是上下文高水位，总 token 消耗 `unavailable`。
- 提示词 SHA256：`f0770240607d647cee07f63b56e5381c88d00f2c647397b549e1e4929c25c4c8`；工作树与 HEAD 基线同上。精确写入白名单没有进入账本，记为 `unavailable`。
- 实际修改：`Core/Sync/HealthKitObserver.swift`、`Core/Sync/SyncEngine.swift`。
- 耗时 `131.429s`；回合 `19`；工具调用 `25`；验证 `0` 次。
- 停止：`status=FAIL`、`classification=LOCAL_POSTWRITE_FAILURE`、`failure_reason=TOOL_LIMIT_EXCEEDED`，无 guard violation；工具数超过 24 次硬限制后结构化终止。
- 采纳判断：`部分接受并补改`。Coder 生成的 `SyncEngine` 显式 type scope 思路被保留；`HealthKitObserver` 出现重复函数和未定义标识符，未通过编译审查，由 Planner 重写。Coder 也没有处理 coordinator 重复 request、runner idle race 和启动首 observer delivery 重叠。
- 首次独立验收：失败；输出未运行声明验证且不能直接编译。
- 最终 Planner 验收：重写 observer、删除重复 request、修复 runner 空闲竞争并增加 startup 首投递覆盖；最终相关测试 `21/21`，真机连续四次启动后 durable queue 均 `pending=0`。

## S13 — 总体评价

本轮两个 S13 调用的监督器通过率 `0/2`、首次独立验收通过率 `0/2`、有用产出采纳率 `1/2`。第一次失败属于提示词合同问题；第二次证明路径合同修正有效，但模型在小范围集成修复上工具使用过多，达到硬上限前仍留下编译错误和三个关键竞态未处理。它提供了一个可用的 API 方向，不能独立完成或验收该真机缺陷修复。最终实现、风险判断和设备验收均由 Planner 接管。

真机验收随后确认旧备份包因后台导出中断而出现数据文件与 manifest 不一致。备份发布属于恢复一致性边界，Planner 未再调用 EVO，直接改为 staging 完整生成后同卷替换发布；提交前中断、成功重导和既有 round-trip `3/3` 通过。最终全量单测 `426/427`，唯一失败仍是未签名 Simulator 宿主的 Keychain `-34018`。

S13 终态仍为 `PENDING`：内部 snapshot p95、最终签名二进制 20 次冷启动、升级数据保全和 durable queue 收敛已有真机证据；三类自动恢复各 3 轮、精确视觉 p95、隔离备份以及有签名 Keychain round-trip 尚未完成。

## S13 — 餐次保存卡死修复未调用 EVO

- 原因：现场证据定位到 `ProjectionWorker` 的全库扫描、SQLite writer transaction 和交互 `MealStore.save` 之间的数据一致性/并发边界，命中 `PLANNER_OWNED`；同时需要在 2 GB 真机数据库副本上做只读性能验证。该阶段不适合交给窄写入 Coder，也没有改变 EVO 的生产 wrapper、参数或路由。
- 执行：Planner 将 354 万条 raw 证据扫描移到 WAL reader，改用 cursor 和复用 formatter，仅在短 writer transaction 发布去重日期，并新增“扫描暂停期间餐次仍能在 1 秒内保存”的并发回归。
- 独立验收：聚焦 `9/9`；有签名完整套件 `437/437`（单元 `428/428`、UI `9/9`）；签名真机构建和覆盖安装通过，锁屏数据库 `quick_check=ok` 且餐次/raw/item 数保持。设备锁定导致真实点按重放 `PENDING`。
- 报表影响：本阶段为 Planner-only，不计入 Coder 比率分母；累计监督器通过率仍为 `0/5`、首次独立验收通过率 `0/5`、有用产出采纳率 `4/5`。

本轮 EVO-Coder 评价保持不变：它在 S13 前两次调用中给出过一个可用 API 方向，但没有生成可直接编译和独立验收的完整修复；餐次卡死属于其风险边界外的数据库并发问题，由 Planner 接管更合适。

## S13 — 受保护数据解锁恢复修复未调用 EVO

- 原因：现场问题跨 HealthKit 受保护数据错误、durable deferral、前后台执行机会和 UI 状态真值，属于 `PLANNER_OWNED` 生命周期/数据一致性边界。修复还需要直接对 2 GB 真机数据库的前后副本做 ledger 取证，因此未把该阶段路由给窄写入 Coder。
- 执行：Planner 让 foreground/background/manual/retry 新机会只恢复 `waitForUnlock`，保留 observer parked 及 authorization/repair/failure deferral；在真实 HealthKit probe 仍失败时继续由既有路径重新挂起。
- 独立验收：聚焦 `24/24`；完整套件 `440/440`（单元 `431/431`、UI `9/9`）；真机签名构建、覆盖安装和启动通过。修复前 28/28 类型 pending 且等待解锁，修复后 `pending=0`、`waitForUnlock=0`、全部 generation 收敛，05:55:50 app 自动作业成功，数据库 `quick_check=ok`。
- 报表影响：本阶段为 Planner-only，不计入 Coder 比率分母；累计监督器通过率仍为 `0/5`、首次独立验收通过率 `0/5`、有用产出采纳率 `4/5`。

本轮 EVO-Coder 评价仍不变：没有新增样本可以改变此前比率。当前修复命中 EVO 风险边界，由 Planner 直接诊断、实现和真机验收是合适路由；EVO 在 S13 早期提供过一个可用 API 方向，但仍没有产出可直接编译并独立验收的完整修复。
