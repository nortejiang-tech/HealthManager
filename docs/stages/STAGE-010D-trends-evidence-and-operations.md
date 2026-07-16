# STAGE-010D 趋势、证据与运维详情

## 状态

`PASS`

## 目标

在 STAGE-010A～010C 已验收的证据型 UI 上，统一九类详情与运维页面的视觉层级：通用指标详情、活动详情、数据质量、数据来源、同步中心、告警、日报 / 周报、运动记录和补录活动。

本阶段只重组现有事实、状态、图表、来源和动作，不改变查询、聚合、状态机、对账、告警确认、报告生成、活动估算或保存语义。

## 已验证起点

- STAGE-010A～010C：PASS；最近全量自动化 258 / 258。
- 共享设计系统已有 accepted 的标题、证据标签、决策透镜、阶段轨道、恢复、空白和加载组件。
- 通用指标详情已有真实周 / 月 / 年、可滚动图表、粘滞选中、可视窗口统计和来源明细。
- 活动详情已有严格 `基础代谢 + 活动能量 = 总消耗`、完整饮食证据后才计算缺口的合同。
- 同步、质量、来源、告警、总结、运动和补录均已有真实 Store / query / state machine；视觉层不得重算或复制这些规则。

## 设计依据

- `docs/adr/ADR-002-evidence-led-functional-ui-language.md`
- `docs/design/2026-07-16-ui-redesign-design-contract.md`
- `08-metric-detail-sleep.png`、`09-data-quality.png`、`10-sync-center-success.png`
- `11-data-sources.png`、`12-alerts.png`、`13-summary-structure-only.png`
- `14-workouts.png`、`15-manual-activity-entry.png`
- `24-activity-detail-corrected.png`、`26-sync-failure.png`

以上 PNG 均位于 `docs/design/assets/ui-redesign-2026-07-16/`。`25-apple-health-permission-scope.png` 只作为后续 010E / 010F 权限下钻的边界参考，本阶段不得虚构当前代码没有的逐类型授权状态页。

参考图规定信息层级、语义色和状态组织，不是数据 fixture。示例值、App 图标、来源、日期、权限判断和健康结论若与真实代码冲突，必须删除或替换为真实状态。

## 允许修改

- `UI/Dashboard/Detail/MetricDetailView.swift`
- `UI/Dashboard/Detail/ActivityDetailView.swift`
- `UI/Dashboard/Detail/DataQualityDetailView.swift`
- `UI/Sources/SourcesView.swift`
- `UI/SyncCenter/SyncCenterView.swift`
- `UI/Alerts/AlertsView.swift`
- `UI/Summary/SummaryView.swift`
- `UI/Workouts/WorkoutsView.swift`
- `UI/Workouts/ManualActivityEntryView.swift`
- `UI/DesignSystem/HMDesignSystem.swift`，仅限至少两个本阶段页面立即复用的轻量补充；
- 与本阶段直接相关的 Preview、测试和文档。

## 禁止修改

- `Core/`、schema、迁移、Store、query、HealthKit、同步引擎 / 状态机、对账器、告警模型、总结生成器、LLM、通知或活动保存算法；
- STAGE-010A～010C accepted 页面、设置 / AI、Dashboard 卡片编辑器和权限下钻；
- 图表数值、平均规则、来源归因、缺口、质量分、同步阶段、告警状态或 MET 估算的计算来源；
- 新健康结论、评分、目标、诊断、直接第三方连接、云同步或设置深链；
- 假数据、第三方 UI 包、自绘图片 / SVG、运行时 QA 路由；
- commit、tag、push。

## 事实与交互合同

### 指标与活动

- `MetricDetailView` 的加载、可视窗口、图表滚动 / 选中、统计、deficit breakdown 和 raw sample 明细语义不变；选中点必须同时有可读文本。
- 缺失点不进入平均；未知显示 `—`，合法 0 仍显示 0。
- 活动公式只能是 `基础代谢 + 活动能量 = 总消耗`；饮食不完整或任一燃烧输入未知时，缺口停止计算，不能按 0 补齐。
- Apple 健康实测与手工估算必须有文字、图标和来源区别。

### 质量、来源、同步与告警

- 质量分只评价数据覆盖 / 新鲜 / 冲突，不评价健康；缺失原因、原始样本和最近同步均来自现有查询。
- 来源页只展示 raw sample metadata 归因；Garmin / 米家经 Apple 健康进入，不写成 App 直连；未知来源显式。
- 同步中心的等待外部 App 不是失败；失败、soft skip、未执行和成功必须分开。重试不删除上次成功数据。
- 告警“标为已知”只确认 / 隐藏提醒，不补数据、不触发同步、不修改健康事实。

### 总结、运动与补录

- 本地确定性摘要始终在 AI 前；AI 仍是可选、次级、显示模型 / 时间和外发边界，不改生成流程。
- 运动记录缺字段时保持未知；手工补录必须继续标估算。
- 补录活动的 MET、体重、时长和结果只消费现有计算；75 kg fallback 必须可见，已保存记录不因未来体重变化改写。
- `Form` / `List`、Chart、Picker、DatePicker、sheet、refresh、导航和所有现有 identifier 保持。

## 完成标准

- [x] 九类页面进入同一证据型视觉语言，主叙事、来源、状态、动作层级清楚，且没有卡片堆砌。
- [x] 指标图表的周期、选中点、统计、来源和缺失规则仍可读、可操作。
- [x] 活动计算链、同步阶段链、质量 / 告警和 AI 次级边界均由图标 + 文字表达，颜色不是唯一信号。
- [x] 所有既有导航、刷新、重试、确认、补录、生成、保存和失败恢复路径保持。
- [x] light、dark、accessibility-large 无关键裁切、水平溢出、图表不可读或不可达动作。
- [x] 参考图与运行态使用相同视口组合对照，示例数据与真实运行状态差异有事实说明。
- [x] 定向测试、全量测试和 `git diff --check` 通过。

## 验证矩阵

1. 构建：iPhone 17 / iOS 26.5 Simulator，独立 DerivedData。
2. 定向单元：`DailyAggregatorEnergyTests`、`DailyAggregatorSleepTests`、`DashboardNutritionEvidenceTests`、`DailyReconcilerTests`、`SourceAttributionTests`、`SummaryGeneratorTests`、`SyncStateMachineTests`、`SyncJobRecoveryTests`、`WorkoutsViewTests`。
3. UI：正式 `SmokeTests`；必要时只增加 test-only 导航 / 截图审计，不增加 production 路由。
4. 全量：`HealthManager` scheme 全测试，用 `xcresulttool` 记录统计。
5. 视觉：至少覆盖指标详情、活动详情、质量、来源、同步成功 / 失败、告警、总结、运动、补录活动的 light；核心密集页另覆盖 dark 和 accessibility-large，并生成 reference / runtime 同屏对照。

## 验证边界

- Simulator 不证明真实 Apple 健康权限、真实外部 App 刷新或后台同步时序。
- 不发送真实 AI 请求，不把视觉稿示例 AI 评注写入数据库。
- 不进入 STAGE-010E～010H，不以静态 Preview 代替 Simulator 运行证据。

## 结果

主架构师结论：`PASS`。

### Accepted 实现

- 指标与活动详情继续消费既有查询、可视窗口、图表选中和统计结果；未知与合法 0 分离。活动页只显示既有 `基础代谢 + 活动能量 = 总消耗`，并在燃烧输入或饮食证据不完整时明确停止热量缺口。
- 数据质量、来源、同步和告警统一使用证据标签、恢复状态与原生列表。质量分明确只评价覆盖 / 新鲜 / 冲突；Garmin / 米家明确为经 Apple 健康进入；等待外部 App 与失败分开；确认告警不再暗示修复数据。
- 日报 / 周报以本地确定性摘要为主结果，AI 评注维持可选次级内容，并显示模型 / 时间和“只外发聚合摘要文本”的边界；运动与补录继续区分 Apple 健康实测和手工 MET 估算，75 kg 兜底及公式可见。
- 共享主动作在 accessibility size 下允许多行显示；没有新增业务 query、Store、状态机、运行时 QA 路由、图片资产或第三方 UI 包。

### 自动化证据

- 构建：`/tmp/healthmanager-stage010d-architect-build-20260716-attempt03`，exit 0，`BUILD SUCCEEDED`。
- 定向：73 / 73 passed，0 failed，0 skipped；`/tmp/healthmanager-stage010d-architect-targeted-20260716-attempt02.xcresult`。
- 全量：258 / 258 passed，0 failed，0 skipped；`/tmp/healthmanager-stage010d-architect-full-20260716-attempt01.xcresult`。
- 设备：iPhone 17 / iOS 26.5（23F77）Simulator；统计均由 `xcresulttool` 读取。
- `git diff --check`：PASS；临时视觉审计 test 已从正式工程删除并重新执行 `xcodegen generate`。

### 运行时视觉证据

- light 的九张真实运行态：`/tmp/healthmanager-stage010d-acceptance-20260716/light/`；对应九张 reference / runtime 组合图：`/tmp/healthmanager-stage010d-acceptance-20260716/comparisons/`，均已逐张作为组合输入复核。
- dark 核心密集页 6 / 6：`/tmp/healthmanager-stage010d-visual-dark-20260716-attempt01.xcresult`；导出目录 `/tmp/healthmanager-stage010d-acceptance-20260716/dark/`。
- accessibility-extra-large 核心密集页最终 6 / 6：`/tmp/healthmanager-stage010d-visual-accessibility-20260716-attempt05.xcresult`；主动作截断经真实截图发现并修复，最终导出目录 `/tmp/healthmanager-stage010d-acceptance-20260716/accessibility-final2/`。
- 运行态通过正式补录、保存、对账和本地总结生成路径产生数据，没有把参考图示例值写入数据库。模拟器本轮只自然产生同步完成态，没有伪造同步失败 fixture；失败分支仍由既有状态机与定向测试覆盖，本结果不外推真实 HealthKit 授权、外部 App 刷新或后台同步时序。

没有 commit、tag 或 push。
