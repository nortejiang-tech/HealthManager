# Scheduling update

# Latest update: daily nutrition and energy balance query contract

2026-09-20: `health_daily_summary` now returns deterministic `nutrition` and `energyBalance` sections from already-synced meal and daily activity projections. `health_metric_history` and `health_compare` support `calorie_intake` and `calorie_deficit`. The deficit preserves the existing App formula `basal_energy_kcal + active_energy_kcal - calorie_intake_kcal`; no meal, partial meal calories, missing/invalid basal or active energy, and overflow remain null rather than zero. Source export tables, iCloud transport, migrations, HealthKit writeback and the receiver were unchanged. Package tests 15/15, release build and iOS Simulator build PASS; release CLI atomically deployed and checked against the available real replica without logging record contents. Source/installed health-agent Skill copies match and its workspace now requires query evidence for actual-record questions. No-delivery agent runs did not produce a tool-call trajectory event, so actual health-agent tool invocation remains PENDING; its response text is not accepted as evidence. S3C report: `reports/S3C-CODER-REPORT.{md,json}`.

User requested standalone scheduled observation. Existing healthbridge-48 is now a project cron using gpt-5.6-luna / max, every2 hours, no thread heartbeat binding. Configuration readback verified. Historical heartbeat references below are superseded; do not recreate thread follow-up.

# Health-agent nightly receive configured

`healthbridge-nightly-receive` (`a3d738c6-3e93-4a72-9db5-c878a0f705fa`) is an enabled, agent-owned OpenClaw command cron. It runs exactly daily at 02:00 Asia/Shanghai, invokes the existing local HealthBridge receiver with the selected iCloud root, has a 120-second limit, and has delivery mode `none`. It has no model payload and does not send a Feishu message. Its manual acceptance run completed successfully with zero newly imported batches because the receiver was already current. This checks and imports batches that iOS/iCloud have already made available; it cannot wake the iPhone or guarantee that iOS has exported a day's data.

# OpenClaw health-agent CLI integration accepted

The `acl-rehab-assistant` skill allowlist now includes `healthbridge-read`; OpenClaw readback reports the skill eligible and model-visible. A no-delivery local agent turn used the skill and successfully ran the local HealthBridge status query. It verified a complete, available replica with no pending receiver batches or current receiver error. No Gateway restart, external message, native MCP registration, or sensitive record export occurred. Native MCP and wider business-query acceptance remain separate pending stages.

# Health-agent route refresh repair

The first user-facing Feishu turn after installation used an old skill snapshot and incorrectly said that no Apple Health path existed. The health-agent workspace AGENTS.md now explicitly declares HealthBridge as the primary Apple Health route, and the model-visible Skill was updated so OpenClaw’s skills watcher refreshes on the next turn. A fresh no-delivery local verification turn read the updated instructions, executed the status command, and correctly described the available local read-only bridge without asking for a path, URL, token, or export file. Do not restart or compact the existing Feishu session merely to refresh it; ask the health agent again after this change. The next response should use the bridge or return its actual command error.

# First complete physical snapshot received

FIRST_COMPLETE_SNAPSHOT VERIFIED: 2026-09-19T23:25:25.235196+08:00.401 snapshot batches including final401, plus delta402 committed.402 continuous receipts(1..402),402 receipt files,400995 normalized records queryable. Pending0,last_errorNULL. Final snapshot manifest/receipt hash match verified.48-hour observation starts here; earliest end 2026-09-21T23:25:25.235196+08:00. Phone UI readback, offline recovery, sleep/wake, historical edit/delete and actual Agent invocation remain PENDING. No raw health values inspected.

Current OpenClaw npm version is2026.7.1-2 (externally changed); re-establish runtime integration assumptions before registration.

# Latest update: 0.8.1 (16) snapshot memory hotfix

2026-09-19 23:18: user reported repeat foreground crash while generating snapshot. Device Jetsam confirms per-process-limit (~3.30GiB). Actual export stress test failed at60000 records before fix and passes after per-record autoreleasepool;600000-record stress also passes. No migration/data reset. iOS331/331 and Mac12/12 PASS. Device overlay installed and version read back0.8.1(16); device launched successfully and remained running across probes; real iCloud batches now arriving, complete snapshot still pending. See STAGE-FIX-snapshot-memory.md and reports/HOTFIX-CODER-REPORT.json. Original48h baseline is not acceptance; wait for successful real snapshot.

# HealthBridge 交接 — 2026-09-19

总体 **PENDING**：软件与合成链路通过；真机文件夹授权、首次 iCloud 交接、真实 Agent 调用、48 小时观察尚未完成。

## 已交付
- HealthManager 0.8.0 (15)，新增 v12 变更日志/outbox 及 v13 恢复暂停迁移，旧迁移未改；已覆盖安装到现有 iPhone，未卸载、未清数据。设备锁定导致远程启动被拒，需用户解锁打开。
- 独立 Mac Swift Package，官方 MCP SDK 0.12.1、GRDB 6.29.3 和传递依赖锁定。iOS 只编译共享 BridgeCore，不引入 MCP。
- 事务内捕获编辑/删除，一致快照，1000 行分批，SHA-256，顺序入库，幂等重放，回执、七天已确认批次清理、新世代重建。恢复失败暂停导出，避免发布部分恢复状态。
- 九类健康数据、饮食/分项、用药计划/日志、日汇总与质量；只读 9 工具，分页、未知值、覆盖/新鲜度和来源；睡眠主来源及重叠处理、DST 日历边界。
- 默认关闭的设置页、目录书签、前后台机会同步、立即同步、回补/重建入口。
- 本机已安装接收器 LaunchAgent com.norte.healthbridge.receiver，启动+目录变化+60 秒补扫；连续运行读回 last exit code=0。当前 pending_initial_snapshot，无合成数据写入真实副本。

## 验证证据
- reports/ios-tests.json：331 单元测试 + 1 新 UI 测试 = **332/332 PASS**；模拟器 iPhone 17 Pro iOS 26.5。截图 settings-disabled.png 已检查。
- Swift package **11/11 PASS**，包含快照发布、连续序号、校验、幂等、删除/回滚、数据源/世代、未知值、睡眠重叠和 DST。
- scripts/smoke.py 对真实 stdio MCP 初始化、列表、九个工具、数值读回、未知工具拒绝：PASS，仅合成临时数据。
- 真机签名构建与覆盖安装成功；远程启动被 Locked 拒绝。此项不是用户验收。
- Coder 的三个监督器结果均失败，代码经 Planner 独立审查采用；详见 reports/EVO-CODER-REPORT.md 和 JSON。

## OpenClaw
兼容运行时为已有 ChatGPT.app 内 Node 24.21.0；默认 Node 24.15.0 被 OpenClaw 拒绝。只读识别健康管家 agent id acl-rehab-assistant。mcp list 受另一个进程持有 state-lifecycle 及插件迁移阻塞；未抢锁、未 doctor --fix、未重启 Gateway、未修改全局 Node。

原生 MCP 未注册，真实 Agent 调用 PENDING。独立 stdio 已通过。已向该 agent 的 skills/healthbridge-read/SKILL.md 安装同一只读 CLI 的使用说明，仓库副本在 openclaw/；文件存在不等于运行中的 Agent 已加载或调用。没有向飞书发送测试消息。

## 下一步真机验收
1. 解锁 iPhone，打开 HealthManager → 更多 → 设置 → 健康管家同步（iCloud）。
2. 选择 iCloud Drive / Health manager，开启“同步给健康管家”。首次保持 App 前台等待历史采集。
3. 等 Mac 入库后，点“立即同步 / 检查 Mac 回执”，应从等待变为 Mac 已入库；记录真实耗时和批次，不记录原始健康明细到仓库。
4. 抽样核对睡眠、体重、餐次/用药数量与来源；修改一个历史记录并核对增量；由用户安排离线/休眠再恢复。
5. 待 OpenClaw 迁移锁正常释放后注册 MCP并进行不带 --deliver 的健康管家实际调用。不能用 codex.agents 字段假定能限制所有其他运行时 Agent。
6. 首份真实回执后启动48小时观察。真实占位下载、磁盘不足、书签失效、强制退出、休眠/离线尚无设备证据，保持 PENDING。

## 路径与回滚
传输：iCloud Drive/Health manager/HealthBridgeSync。数据库：~/Library/Application Support/HealthManagerBridge/health.sqlite；binary 在同目录 bin/healthbridge。LaunchAgent：~/Library/LaunchAgents/com.norte.healthbridge.receiver.plist。

停用 App 开关，执行 launchctl bootout gui/$(id -u)/com.norte.healthbridge.receiver 即停止新链路。保留数据库、iCloud 文件和所有用户记录。不要回退已应用迁移或卸载 App。若要换数据源，先明确备份/新建接收库，再显式重建快照；没有自动破坏性重新绑定。

已知限制：大量首次快照占用一个源数据库写事务，真机耗时待测；世代排序依赖源设备时间，明显时钟回退需人工恢复；当前日汇总沿用 App 原口径，原始样本数未知处不补造。首次快照前无法推断读权限。所有健康回答应包含数据更新时间和范围。

## 工作树
基线1479db9，无提交/push。保留原有 Codex 图片和替尔泊肽记录两个未跟踪文件，不归因本任务。详细开发/部署和调用证据在本目录。

Heartbeat healthbridge-48 已设每2小时跟进；首份真实回执前不启动48小时计时，仅实质变化提醒。Skill quick_validate.py 因两个已有 Python 环境均无 PyYAML 未运行，已做无依赖 frontmatter/内容/副本哈希检查；不能标为该验证器 PASS。
