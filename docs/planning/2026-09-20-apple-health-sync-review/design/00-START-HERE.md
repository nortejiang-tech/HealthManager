# Apple Health 同步与冷启动重构：执行入口

本设计包把两个用户问题分别闭环：**冷启动尽快展示已有数据**；**新健康数据无需手动同步也能可靠更新**。

设计完成于 2026-09-20；当前状态 **ACCEPTANCE_PENDING**。S01–S12 已完成实现与 Planner 软件验收，S10B 仍有未签名测试宿主的 Keychain `-34018` 环境门；S13 的 Simulator build、418 条可运行单测、20 条 HealthBridge 测试和 3 条相关 UI 测试已通过。真机冷启动、后台/解锁追新、数据保全和有签名 Keychain round-trip 尚未执行，因此这不是最终 PASS 或手机部署授权。

## 交给执行 Agent 的最短入口

当前不需要再把实现阶段交给 Coder。先读 [S13 晚间真机验收清单](S13-DEVICE-ACCEPTANCE-RUNBOOK.md)、[阶段验收记录](STAGE-RESULTS.md) 的 S13 和 [验证矩阵](04-VERIFICATION.md) V05，晚间只执行其中列出的真机操作门；不要重置、重做历史回补、清记录或把 Simulator 结果当作真机结论。

各阶段 prompt 已更新为 PASS/PENDING，机器状态见 `PROMPT-MANIFEST.json`。S10B 和 S13 的 PENDING 原因均已写入 `STAGE-RESULTS.md`。

## 读什么、何时读

| 文件 | 使用时机 |
|---|---|
| [上轮诊断](../ASSESSMENT.md) | 需要了解真机数据规模、已复现问题与未确认原因时 |
| [01-DESIGN.md](01-DESIGN.md) | Planner 总体设计、模块边界、方案取舍 |
| [02-CONTRACTS.md](02-CONTRACTS.md) | 调度/取消/事务/日期/显示语义的唯一合同；各提示词指向相关条款 |
| [03-STAGES.md](03-STAGES.md) | 阶段依赖、文件范围、风险路由与完成门 |
| [04-VERIFICATION.md](04-VERIFICATION.md) | 基线、测试命令、可控时序与真实设备验收 |
| [05-EXECUTION-RULES.md](05-EXECUTION-RULES.md) | 写入范围、凭据、已有改动、失败处理、输出格式 |
| [prompts/](prompts/) | 每次只读取当前阶段提示词与其指定资料 |
| [PROMPT-MANIFEST.json](PROMPT-MANIFEST.json) | 机器可读阶段状态、依赖、允许路径、验证清单 |
| [BASELINE.json](BASELINE.json) | 文档生成时工作区源文件哈希与工具环境快照 |
| [EVO-CODER-REPORT.md](EVO-CODER-REPORT.md) / [JSON](EVO-CODER-REPORT.json) | 三次受控 EVO guard failure、Planner 接管与逐阶段验收 |

## 开始前五项检查

1. 实际工作目录必须是 `/Users/nortepro/HealthManager`，或 Planner 明确准备并重新生成提示词的隔离目录。
2. 读取当前适用的 AGENTS.md。`/Users/nortepro/.codex/AGENTS.md` 为本机路由来源；用户当前指令优先。旧协作文档里的历史版本号、当晚 push/发布授权不继承。
3. 对比 `BASELINE.json` 与当前目标文件；保留已有 dirty changes。HEAD 相同不代表工作区相同。初始评估后若有其他任务改过相同文件，先由 Planner 合并基线。
4. 确认当前 STAGE 获准、前置项已独立验收，准确到测试存在、候选文件存在与最新哈希。
5. 核对离线依赖、模拟器和执行命令。文档生成时只确认了项目/工具元信息，未运行本方案未来单元测试。

## 第一批交付的含义

S01 可单独改善首屏，S02 建立测量。S03–S09 才闭环调度、锁屏恢复与历史投影，不能用纯 reducer 测试代替真实接线。S10–S12 收敛手动同步、导出与状态。S13 真机验收给最终结论。全过程保留既有健康记录、anchor、来源归因、营养 unknown/zero 语义和 HealthBridge 回执合同。
