# EVO-Coder 调用报告 — 2026-09-19

基线 `1479db9`。同步事务、数据库恢复、权限和部署由 Planner 负责。普通纯函数阶段在已审查的隔离目录执行，不向 Coder 暴露用户数据库、凭据、完整工作树或未审查说明。原有两个未跟踪文件保留。

| 阶段 / run_id | 耗时 / 回合 / 工具 | 声明验证 / 尝试 / 通过 | 监督器结果 | Planner 独立验收 |
|---|---|---|---|---|
| S3A / bb913d6b-2a89-4467-863c-61e50fb89741 | 86.145 秒 / 9 / 9 | 1 / 4 / 0 | BLOCKED; LOCAL_POSTWRITE_FAILURE; GUARD_VIOLATION | 9 个契约及 7 项检查通过，4 处描述与实现不符，经补改部分采用 |
| S3B / 2aa6bb9d-0356-4733-96da-2d8da4a6b9ca | 43.647 秒 / 7 / 7 | 1 / 2 / 0 | BLOCKED; LOCAL_POSTWRITE_FAILURE; GUARD_VIOLATION | 24/23/25 小时、严格日期、时区及 UTC 端点验证通过，源码直接采用 |
| S3B 恢复 / a9d3679f-4eaf-4742-a1b9-9c6faf8376fa | 9.051 秒 / 4 / 3 | 1 / 1 / 0 | BLOCKED; LOCAL_PREWRITE_FAILURE; GUARD_VIOLATION | 无新代码；停止进一步调用 |

监督器通过率 **0/3**；产出调用的首次独立验收通过率 **1/2**；有用产物采纳率 **2/2**（一份补改、一份直接采用；无新产物的恢复调用不进该分母）。这些比例不代表长期质量，也不代表代码贡献比例。

三次模型均为 halogen-qwen3.8-flash-next，temperature=0、top_p=1、max_output_tokens=4096。配置、提示词哈希、允许与实际路径、停止原因见同名 JSON 的只读账本摘录。total tokens 和账本未提供的 thinking 字段标记 unavailable；不将 max_context_tokens 当总消耗。

S3B 的 Planner 提示词误把回执字段 commandIndex 当成输入字段，已记录为 Planner 缺陷。审查监督器声明后，以明确的 {index:0} 做一次受控恢复，仍触发 VERIFY_INDEX_NOT_ALLOWED。受控账本不含原始参数，不能断言模型实际调用参数或确切根因。S3A 另有 PATH_ESCAPE_DENIED；检查实际写入仅白名单路径，保留原 diff，无自动模型覆盖。没有修改 wrapper、门禁、模型参数或生产环境。

后续假设：单独对 Pi/verify 工具参数接口做无凭据、无生产写入的契约回归，区分提示词遵循与适配器参数传递。该工作不属于本次 HealthBridge 实施，不擅自修改生产监督器。

软件验收：Mac 包 11/11，iOS 332/332，真实 stdio MCP 的 9 工具合成数据读取与未知工具拒绝通过。真实 iCloud、Agent 和 48 小时仍 PENDING。最初详细阶段文档滞后于 Planner 编码的偏差见 STAGE-S1-S2-transaction-review.md，不追认其为 Coder 成功。
