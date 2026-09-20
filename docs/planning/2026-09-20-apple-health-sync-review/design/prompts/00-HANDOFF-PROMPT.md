你负责 HealthManager 的一个受限实现阶段。先读取：

/Users/nortepro/HealthManager/docs/planning/2026-09-20-apple-health-sync-review/design/00-START-HERE.md

然后读取 design/05-EXECUTION-RULES.md、design/04-VERIFICATION.md 和 design/prompts/S01.md，只实现 S01「首屏移除无用 raw 全表读取」。用户已通过本条消息把 S01 交给你实施；不要把文档中的整条路线当成本次全部实现范围。

工作目录是 /Users/nortepro/HealthManager。开始前核对实际 AGENTS.md、HEAD、工作区状态、BASELINE.json 中目标文件哈希与离线测试环境。保留所有已有 dirty/untracked 修改，不提交、不push、不部署、不操作手机健康数据。不需要重新征求 S01 范围内的普通修改许可；目标文件已被其他任务改过、缺少依赖或需要越过白名单时，保留现状并报告具体缺口。

S01 唯一允许修改：
- UI/Dashboard/DashboardData.swift
- Tests/DashboardIndexMigrationTests.swift

目标：删除趋势首屏没有使用的 rawSampleCount/lastIngest 字段及其COUNT/MAX大表查询，保持所有已展示卡片、质量数据、营养unknown/zero语义。按S01提示词建立真实DashboardLoader回归并运行完整定向测试，不能通过给loader塞假返回值或只检查源码字符串自证通过。

你只承担Coder职责，不自动启动其他Agent、不自行变更模型路由、不宣布整个重构PASS。云端直接实现按本阶段完成；若通过EVO路由，先由Planner完成工作树输入信任门与受限fixture/验证命令准备，不直接把未准入完整工作树传给本地模型。

完成后按05文档的结构报告真实修改路径、diff摘要、命令/退出码/测试数、结果路径、失败项和未验证边界，状态写CODER_DONE_PENDING_REVIEW，然后停止本阶段。后续阶段由独立Planner基于真实accepted diff激活。
