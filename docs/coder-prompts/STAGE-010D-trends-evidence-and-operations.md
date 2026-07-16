# 给内部 Coder：只实现 STAGE-010D

你在共享工作区 `/Users/nortepro/HealthManager` 工作。主会话是架构师和最终验收者。工作区故意保留 STAGE-010A～010C 已验收但未提交的 diff；必须在其上增量实现，禁止删除、覆盖或回退。

## 唯一目标

只实现 `docs/stages/STAGE-010D-trends-evidence-and-operations.md`：把指标详情、活动详情、数据质量、数据来源、同步中心、告警、日报 / 周报、运动记录和补录活动统一到 accepted 的“基线叙事 + 局部决策透镜”语言；不改变任何数据或副作用合同。

## 必须先读并实际查看

完整阅读：

```text
AGENTS.md（若存在）
docs/adr/ADR-002-evidence-led-functional-ui-language.md
docs/design/2026-07-16-ui-redesign-design-contract.md
docs/stages/STAGE-010C-record-and-plan-editors.md
docs/stages/STAGE-010D-trends-evidence-and-operations.md
UI/DesignSystem/HMDesignSystem.swift
```

逐个阅读任务书白名单内的现有 View，并实际查看 010D 列出的 10 张参考 PNG。参考只规定层级和语义；真实函数、状态与数据合同优先。

## 范围硬门

只修改任务书白名单。禁止修改 `Core/`、数据库、query、Store、SyncEngine、DailyReconciler、SummaryGenerator、LLM、HealthKit、设置 / AI、DashboardCardEditor 或 010A～010C 页面。

开始前先写出预计触碰的文件 / struct 和纯视图理由。如果需要改业务函数、查询、状态机、identifier 语义或 010E+ 页面，立即停止并报告。

## 实现要求

1. 复用 accepted token / component；新共享组件必须至少有两个本阶段真实使用点。
2. 保留所有 load / refresh / save / acknowledge / generation / sync / chart selection 函数的行为与调用关系；不要把数据库查询搬进新组件。
3. `nil`、0、empty、failure、soft skip、waiting external app、estimate、confirmed 分开；不得从参考图制造值或结论。
4. 使用 SF Symbols 和系统控件，不用 emoji、文本符号、ASCII、自绘 SVG 或新图片资产。
5. 保留原生 Form / List / Chart / Picker / DatePicker / sheet / navigation / refresh 行为。
6. Dynamic Type 下优先自适应堆叠；禁止固定文本高度；关键动作至少 44 pt；颜色同时配文字 / 图标。
7. 不为取证加入 production launch argument、router、fixture 或假数据。

重点复核：指标可视窗口与统计；活动缺口停止条件；同步 waiting external app；Garmin / 米家经 Apple 健康；告警确认不等于修复；AI 总结次于本地摘要；手工活动始终标估算。

## 最低验证

```bash
xcodegen generate
xcodebuild -project HealthManager.xcodeproj -scheme HealthManager -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -derivedDataPath /tmp/healthmanager-stage010d-coder-build-20260716 build

xcodebuild \
  -project HealthManager.xcodeproj \
  -scheme HealthManager \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -only-testing:HealthManagerTests/DailyAggregatorEnergyTests \
  -only-testing:HealthManagerTests/DailyAggregatorSleepTests \
  -only-testing:HealthManagerTests/DashboardNutritionEvidenceTests \
  -only-testing:HealthManagerTests/DailyReconcilerTests \
  -only-testing:HealthManagerTests/SourceAttributionTests \
  -only-testing:HealthManagerTests/SummaryGeneratorTests \
  -only-testing:HealthManagerTests/SyncStateMachineTests \
  -only-testing:HealthManagerTests/SyncJobRecoveryTests \
  -only-testing:HealthManagerTests/WorkoutsViewTests \
  -only-testing:HealthManagerUITests/SmokeTests \
  -resultBundlePath /tmp/healthmanager-stage010d-coder-targeted-20260716-attempt01.xcresult \
  test
```

结果路径若存在，使用新 attempt，禁止覆盖。用 `xcresulttool` 读取真实统计。不要自行把阶段写成 PASS；主架构师会独立做全量和运行态视觉验收。

## 最终输出

只报告：修改文件 / 结构及范围理由；业务函数、状态、identifier 如何保持；`git diff --check`；build / 定向统计和 xcresult；未验证的视觉 / 外部边界；明确没有 commit / tag / push。完成后停止，不进入 STAGE-010E。
