# HealthManager 全页面 UI 改版设计合同

> 设计状态：PASS（页面、关键状态、视觉方向和实现边界已齐）
>
> 实现状态：STAGE-010A～010H PASS
>
> 设计基线：`main` @ `3e657fa`
>
> 目标平台：iPhone / iOS 17+，竖屏；参考矩阵为 iPhone 17 / iOS 26.5 / 简体中文 / Asia/Shanghai / 浅色

## 1. 交付目标

把现有 HealthManager 从“系统列表 + 分散卡片”升级为一套有辨识度但克制的证据型 UI：

- 首先说明发生了什么、数据来自哪里、哪些仍未知；
- 需要用户理解或选择时，使用一个局部“决策透镜”解释依据、停止条件或下一步；
- 不为视觉效果新增健康算法、目标、诊断、社区或商业能力；
- 保留现有五栏导航和全部真实功能；
- 所有页面使用同一套语义色、排版、状态和来源表达。

本合同是实现与验收的书面依据。视觉资产见：

- [视觉参考索引](assets/ui-redesign-2026-07-16/README.md)
- [ADR-002](../adr/ADR-002-evidence-led-functional-ui-language.md)

## 2. 不可协商的事实边界

1. `nil`、缺少字段、没有样本和加载失败必须保持不同状态，不能统一显示成 `0` 或空白成功页。
2. 没有餐次计划合同，不得生成“早餐 / 午餐 / 晚餐漏记”或把某一餐当成必须完成的目标。
3. 用药计划时间和实际动作时间是两个事实。只有动作日志可写成已服 / 跳过 / 延后；计划兜底必须写“计划 HH:mm / 动作时刻未记录”。
4. 当日热量缺口只有在基础代谢、活动能量和完整饮食热量证据都存在时才计算。缺一个输入就停止，不按 `0` 补齐。
5. 手工活动消耗使用现有 `MET × 体重 × 小时` 合同。最近体重缺失时可用 75 kg，但必须标明兜底；保存后的历史活动不因未来体重变化自动改写。
6. AI 估算、手工估算、营养数据库和包装标签是不同来源。人工修订不会自动把估算升级为已验证事实。
7. 日报 / 周报先展示本地确定性摘要；AI 评注必须是可选、次级、显示模型与时间，并且不得把“适中 / 正常 / 与基线一致”写成无依据结论。
8. 默认本地保存不等于“永不外发”：AI 评注会向配置的文本服务发送聚合摘要；餐食照片分析会向配置的视觉服务发送用户选择的图片。
9. Apple 不提供完整读取授权清单。读取状态只能来自真实查询结果；没有样本不等于没有权限。写回授权可按系统可观察状态表达。
10. Garmin、米家等来源只通过它们写入 Apple 健康的数据进入本 App；本 App 不直接登录这些第三方账户。
11. 告警“标为已知”只隐藏 / 确认告警，不修复原始数据。
12. 不增加健康评分、自动目标、下一餐教练、诊断、因果关系、社区、电商、广告、课程、云同步、食品库、OCR 或条码能力。

## 3. 视觉系统

### 3.1 色彩角色

浅色模式建议 token：

| Token | 建议值 | 用途 | 禁止用途 |
|---|---:|---|---|
| `background` | `#FCFAF7` | 暖象牙页面底 | 不作为卡片边框 |
| `surface` | `#FFFFFF` | 表单、少量独立对象 | 不把每个区块都做成白卡 |
| `textPrimary` | `#101114` | 标题、正文 | — |
| `textSecondary` | `#666B73` | 解释、来源、时间 | 不承载唯一关键状态 |
| `separator` | `#E2DFDA` | 轻分隔线 | 不做重描边 |
| `comparison` | `#0A63E8` | 已观测比较、选中点、周期 | 不代表“健康良好” |
| `confirmed` | `#007F7B` | 本地事实、已保存、真实查询成功 | 不代表所有健康数据正常 |
| `actionStrong` | `#C93F16` | 缺失、失败、需要处理的文字与可访问按钮填充 | 不用于普通设置提交 |
| `actionAccent` | `#FF6A2A` | 小面积动作图标、线条、柔和强调 | 不直接承载小号白字 |
| `estimate` | `#6444DC` | AI / 手工估算、假设、外部可选能力 | 不代表确认事实 |

`comparison`、`confirmed`、`estimate` 与 `actionStrong` 在暖象牙 / 白色背景上的普通文字对比度均应达到 4.5:1。`actionAccent` 只作大图标、描边或配合深色文字；普通白字按钮使用 `actionStrong`。

深色模式不得简单反转浅色。建议以 `#121316` 背景、`#1A1C1F` 表面、`#F5F4F2` 主文字、`#B7BAC0` 次文字为起点，并为四个语义色提供更亮的动态值；最终以真实对比度和 Simulator 视觉 QA 为准。

现有 `CardTheme`：

- 保留为指标家族色：活动、心率、睡眠、体成分、饮食、缺口；
- 只用于指标图标、图表和轻量标识；
- 不得用 `CardTheme.activity` 的红色表达通用加载失败；
- 同时出现指标身份与证据状态时，证据状态必须有文字 / 图标，不能只靠颜色。

### 3.2 排版

只使用系统字体（SF Pro / PingFang SC），不引入自定义字体包。

| 层级 | SwiftUI 语义起点 | 说明 |
|---|---|---|
| 一级页标题 | `.largeTitle.weight(.bold)` | “今日 / 饮食 / 用药 / 趋势 / 更多” |
| 关键叙事标题 | `.system(.title, design: .default).weight(.bold)` | 允许 2 行，避免固定高度 |
| 页面内段标题 | `.title3.weight(.semibold)` | 20–22 pt 视觉量级 |
| 正文 | `.body` | 16–17 pt 视觉量级 |
| 次正文 | `.subheadline` | 来源、日期、解释 |
| 说明 | `.footnote` / `.caption` | 不低于系统可读下限 |
| 数值 | 系统圆体或默认体 + `.monospacedDigit()` | 只对真正数字使用 |

所有字号从 Dynamic Type 文本样式派生。禁止把 34 pt、17 pt 等视觉稿数值硬编码成不可缩放字体。

### 3.3 间距、圆角、表面

- 基础间距：4 / 8 / 12 / 16 / 24 / 32 / 40；
- 一级内容左右边距：20–24；列表内边距：16；
- 小控件圆角：10–12；普通独立表面：16–18；大范围透镜：22–24；胶囊只用于状态 / 筛选；
- 先用排版、空白和分隔线，再用浅色面，最后才用边框；
- 阴影只允许在拖动中的卡片行、模态层或确实需要层级的浮层出现；
- 不使用大面积玻璃、霓虹、3D、装饰渐变或卡片套卡片。

### 3.4 动效

- 页面状态切换：180–240 ms ease-in-out，内容交叉淡入；
- 列表插入 / 隐藏：保持系统默认克制动画；
- Today 基线只允许轻微路径 / 节点过渡，不持续漂浮；
- 加载骨架可使用低对比度 shimmer，但 Reduce Motion 下变为静态；
- 不使用弹性过强、粒子、庆祝或游戏化反馈。

## 4. 共享组件合同

实现只建立会被至少两个页面立即使用的组件，避免先造一套空设计系统。

| 组件 | 责任 | 必须支持 |
|---|---|---|
| `HMEditorialHeader` | 大标题、本地日期、可选状态入口 | Dynamic Type；长标题换行；无固定高度 |
| `HMEvidenceTag` | 来源 / 状态短标签 | tone + 图标 + 文字；颜色不是唯一信号 |
| `HMProvenanceRail` | 来源、阶段或计算链 | 完成 / 失败 / 未执行 / 估算；VoiceOver 顺序摘要 |
| `HMDecisionLens` | 一个页面的核心依据、停止条件和动作 | 一个主动作，最多两个次动作；不可嵌套 |
| `HMInlineRecovery` | 可恢复错误和部分成功 | 已保留内容、失败范围、重试、技术详情 |
| `HMEmptyState` | 成功但无记录 | 不与加载 / 失败混淆；真实主动作 |
| `HMLoadingSkeleton` | 保留最终布局节奏 | 无虚假数值；Reduce Motion；可访问进度文案 |
| `HMSettingsGroup` | 设置行分组 | 行分隔优先；不为每行造卡 |
| `HMMetricSelection` | 图表选中日 / 时点 | 选中值、比较基准、来源、VoiceOver 描述 |

## 5. 页面与参考映射

### 5.1 根流程与一级页面

| 页面 | 现有入口 / 文件 | 参考 | 页面核心验收 |
|---|---|---|---|
| 首次授权 | `UI/Onboarding/OnboardingView.swift` | `20-onboarding.png` | 读取、按需写回、第三方经 Apple 健康、此步不调用 AI 全部明确。 |
| Apple 健康不可用 | `AuthorizationDeniedView` in `App/RootView.swift` | `21-health-unavailable.png` | 改为不可用 / 连接未建立语义，不归咎用户；本地数据不会清除。 |
| 今日 | `UI/Today/TodayView.swift` | `01-today-master-structure-only.png` | 保留真实 Today evidence 合同；一处决策透镜；不推断缺餐 / 漏服。 |
| 今日加载 | 同上 | `28-today-loading.png` | 中性骨架、无虚假值、说明读取本机；底栏可用。 |
| 今日失败 | 同上 | 共享恢复组件 | 保留真实错误与重试；不显示成功空日；取消请求不报错。 |
| 饮食 | `UI/Diet/DietView.swift` | `02-diet-main-structure-only.png` | 记录汇总、来源和真实餐次；没有餐次计划占位。 |
| 饮食空白 | 同上 | `27-diet-empty.png` | 空白不是漏记；新增 / 历史复用；今日无记录与历史无记录分别处理。 |
| 用药 | `UI/Medication/MedicationView.swift` | `03-medication-main.png` | 计划、实际动作、下一计划、日志分层；通知状态不冒充服药状态。 |
| 趋势 | `UI/Dashboard/DashboardView.swift` | `04-trends-main.png` | 一个主叙事图、安静指标列表、无目标环 / 健康分。 |
| 编辑趋势卡片 | `UI/Dashboard/DashboardCardEditor.swift` | `17-dashboard-card-editor.png` | 拖动、隐藏、恢复可理解；隐藏不删数据；恢复默认非危险操作。 |
| 更多 | `UI/More/MoreView.swift` | `05-more-main.png` | 可信度路径 + 数据 / 分析 / 设置分组；全部既有功能可达。 |

### 5.2 记录与编辑

| 页面 | 现有入口 / 文件 | 参考 | 页面核心验收 |
|---|---|---|---|
| 餐食编辑 | `MealEditView` in `UI/Diet/DietView.swift` | `06-meal-editor.png` | 照片 / 文字 / AI / 手工分项可编辑；保存不被 AI 绑定；外发说明准确。 |
| 餐食证据展开 | `UI/Diet/MealItemEvidenceView.swift` | `22-meal-item-evidence.png` | 来源、输入、模型、置信、修订、备餐状态、覆盖和未知字段可读。 |
| AI 部分失败 | `MealEditView` | `29-ai-partial-failure.png` | 成功输入保留；失败输入单独重试；手工继续与保存可用；原始错误折叠。 |
| 复用餐次列表 | `UI/Diet/MealReuseView.swift` | `16-meal-reuse.png` | 整餐复用与选择菜品两条路径；创建新草稿；原记录不变。 |
| 复用菜品选择 | 同上 | 使用同一列表 / 选择组件 | 选中计数、全不选禁用、失败不丢选择；无效 item id 不可选。 |
| 用药计划编辑 | `MedicationPlanEditView` | `07-medication-plan-editor.png` | 频率、星期、时间、提醒和保存明确；通知失败不误删计划。 |
| 系统照片 / 相机选择 | `CameraPicker` / `PhotosPicker` | 系统 UI | 不自绘替代；权限文案来自 Info.plist；取消不改草稿。 |

### 5.3 趋势、证据与运维详情

| 页面 | 现有入口 / 文件 | 参考 | 页面核心验收 |
|---|---|---|---|
| 通用指标详情 | `UI/Dashboard/Detail/MetricDetailView.swift` | `08-metric-detail-sleep.png` | 周 / 月 / 年、比较基准、选中点、统计和来源明确；缺失日不计平均。 |
| 活动详情 | `UI/Dashboard/Detail/ActivityDetailView.swift` | `24-activity-detail-corrected.png` | 公式严格为 `基础 + 活动 = 消耗`，再减摄入；未知时停止；实测 / 手工估算分开。 |
| 数据质量 | `UI/Dashboard/Detail/DataQualityDetailView.swift` | `09-data-quality.png` | 显示证据覆盖和对账事实，不显示无依据“良好 / 正常”。 |
| 数据来源 | `UI/Sources/SourcesView.swift` | `11-data-sources.png` | 基于真实 raw sample metadata；第三方来源不是直接连接；未知来源显式。 |
| 同步中心（成功 / 空闲） | `UI/SyncCenter/SyncCenterView.swift` | `10-sync-center-success.png` | 真实状态机、上次结果、回补 / 对账入口；等待外部 App 非失败。 |
| 同步中心（失败） | 同上 | `26-sync-failure.png` | 已完成 / 失败 / 未执行；job 失败与权限 soft-skip 分开；重试不删上次成功数据。 |
| Apple 健康权限范围 | Settings / Sync diagnostic 下钻 | `25-apple-health-permission-scope.png` | 最近真实查询作为证据；没有样本不等于未授权；写回状态独立。 |
| 告警 | `UI/Alerts/AlertsView.swift` | `12-alerts.png` | 原因、范围、来源、时间明确；标为已知不修复数据。 |
| 日报 / 周报 | `UI/Summary/SummaryView.swift` | `13-summary-structure-only.png` | 本地确定性摘要在前；AI 次级、可选、可追溯；无健康结论越权。 |
| 运动记录 | `UI/Workouts/WorkoutsView.swift` | `14-workouts.png` | Apple 健康实测、手工补录和缺字段有不同视觉 / 文案。 |
| 补录活动 | `UI/Workouts/ManualActivityEntryView.swift` | `15-manual-activity-entry.png` | 类型、时间、时长 / 距离、体重和公式透明；75 kg 兜底显式。 |

### 5.4 设置与 AI

| 页面 | 现有入口 / 文件 | 参考 | 页面核心验收 |
|---|---|---|---|
| 设置 | `UI/Settings/SettingsView.swift` | `18-settings-data-ledger.png` | 顶部数据去向总账；默认本地与可选外发不矛盾；技术项下沉。 |
| AI 功能 | `UI/Settings/LLMSettingsView.swift` | `19-ai-config.png` | 文本评注 / 照片分析双通道；分别启停、测试和编辑；Keychain 说明准确。 |
| 添加兼容接口 | `AddProviderView` | `23-add-ai-provider-structure-only.png` | 只存名称 / URL / 建议模型；不存 Key；添加后不自动启用或发送数据。 |
| 编辑文本 / 照片通道 | AI 功能下钻 | 复用设置表单模板 | Base URL、模型、Key、测试结果和应用范围清楚；失败不覆盖已保存配置。 |
| 保存当前配置 | `saveProfileSheet` | 复用中型 sheet 模板 | 配置名必填；保存项预览；Key 不进入 Profile；取消无副作用。 |

## 6. 状态合同

| 状态 | 视觉 | 文案与行为 |
|---|---|---|
| 首次加载 | 中性骨架 + 单一进度说明 | 不显示任何值 / 来源 / 语义色；完成后交叉淡入。 |
| 后台刷新 | 保留现有内容，局部进度 | 旧内容可继续读；旧请求不得覆盖新请求。 |
| 成功空白 | 空白说明 + 真实主动作 | 不与失败混淆；不把空白推断成漏记或异常。 |
| 页面失败 | 珊瑚状态 + 钴蓝 / 青绿重试 | 显示可理解原因；原始技术详情折叠；不清空仍有效内容。 |
| 部分成功 | 成功项青绿，失败项珊瑚 | 明确已保留与待重试范围；只重试未完成项。 |
| 权限不完整 | 每类型文字 + 图标 + 最近查询时间 | 不显示综合百分比；不把“无样本”当“未授权”。 |
| HealthKit 不可用 | 连接未建立 + 重试 / 设备要求 | 不写“用户拒绝”；本地数据不清除。 |
| 未知值 | `—` + 原因或“未提供” | 合法 `0` 仍显示 `0`；未知不参与平均 / 公式。 |
| 估算 | 紫色 + 方法 / 模型 / 输入 | 人工修订后仍保留估算标签；可改为手工来源。 |
| 已确认 / 已保存 | 青绿 + 明确来源 | 只代表事实状态，不代表健康正常。 |

## 7. 导航与交互

- 保留系统 `TabView`：今日 / 饮食 / 用药 / 趋势 / 更多；不自绘整套 TabBar。
- 一级页面使用大标题；详情页使用系统 push；记录 / 编辑使用 sheet。
- sheet 内不显示底部 TabBar；push 页面是否保留 TabBar 以系统导航上下文为准。
- 主动作每屏最多一个；次动作最多两个，且视觉权重明显降低。
- 所有点击区至少 44 × 44 pt；图标按钮必须有 accessibility label。
- 破坏性红 / 橙只用于删除、失败或需要处理；隐藏卡片、恢复布局、普通保存不是危险动作。
- 技术详情默认折叠；用户可复制错误、引用、版本和 Base URL。
- 图表选中点必须同时更新可读文本，不能只靠悬浮线 / 颜色表达。

## 8. 无障碍与本地化门

实现完成前必须证明：

1. 默认 Dynamic Type 与 accessibility-large 均无关键内容裁切、重叠或不可达；
2. VoiceOver 能按“标题 → 结果 → 来源 → 状态 → 动作”顺序读取决策透镜和阶段轨道；
3. 色盲用户不靠颜色也能区分确认、缺失、估算和比较；
4. 所有图表有整体摘要、选中点描述和来源；
5. Reduce Motion 下无 shimmer 和路径持续动画；
6. 简体中文为本轮文案基线；日期、数字和单位从 Locale / Calendar 生成，不硬编码视觉稿日期；
7. 深色模式有真实动态颜色与对比度验证，不能强制浅色。

## 9. 实施阶段图

| 阶段 | 唯一目标 | 依赖 | 主验收面 |
|---|---|---|---|
| STAGE-010A | 建立轻量 token / 共享状态组件，并改造首次授权、HealthKit 不可用、Today 加载 / 失败 | 本合同 Accepted | 设计系统不会与 `CardTheme` 冲突；根状态真实可用 |
| STAGE-010B | 改造五个一级页面与导航壳，不改数据合同 | 010A PASS | 五栏一致性、主动作、空状态、功能入口无丢失 |
| STAGE-010C | 改造餐食、复用、证据、用药计划等记录编辑流程 | 010B PASS | 保存 / 取消 / 失败无损；来源与估算透明 |
| STAGE-010D | 改造趋势、指标详情、来源、同步、质量、告警、总结、运动 | 010C PASS | 图表、计算链、状态机与来源真实 |
| STAGE-010E | 改造设置、AI 双通道、接口 / Profile、权限下钻 | 010D PASS | 数据去向、Keychain、外发与权限边界准确 |
| STAGE-010F | 补齐卡片编辑、权限下钻和跨页 loading / empty / failure 等剩余状态 | 010E PASS | 未覆盖页面与状态全部进入同一视觉语言 |
| STAGE-010G | 全量无障碍、深色、Dynamic Type、UI 流程与视觉回归修正 | 010F PASS | 固定截图矩阵、真实交互与可访问性边界 |
| STAGE-010H | 最终全 App 回归、文档审计与改版收尾 | 010G PASS | 全量 unit / UI / build、diff 审计、无临时 seam、最终 handoff |

后续 Coder 提示词不提前冻结。只有前一阶段由主架构师验收 PASS 后，才根据真实 accepted diff 生成下一条最终提示词。

## 10. 设计完成审计

| 要求 | 证据 | 状态 |
|---|---|---|
| 竞品与产品边界有依据 | `docs/research/2026-07-13-health-app-competitor-primary-research.md`、STAGE-007A | PASS |
| 用户选定方向被固化 | ADR-002、本合同、29 张稳定参考 | PASS |
| 五个一级页面均有目标 | 第 5.1 节与 01–05 参考 | PASS |
| 关键记录 / 编辑页有目标 | 第 5.2 节与 06–07、16、22、29 参考 | PASS |
| 趋势 / 来源 / 同步 / 质量 / 报告有目标 | 第 5.3 节与 08–15、24–26 参考 | PASS |
| 设置 / AI / 权限有目标 | 第 5.4 节与 18–23、25 参考 | PASS |
| 空白 / 加载 / 权限 / 失败 / 部分成功 / 未知 / 估算有合同 | 第 6 节与 21、25–29 参考 | PASS |
| 错误稿与误导文案已排除 | 资产 README“明确排除”与各图使用边界 | PASS |
| 实现与运行时视觉已完成 | 010A 根状态完成 12 张运行态与 3 张同屏对照；010B 五个一级页完成 18 张运行态、5 张同屏对照；010C 四组编辑流程完成 12 张运行态、4 张同屏对照；010D 九类详情完成 light 9 张、dark 6 张、accessibility 6 张和 9 张同屏对照；010E 设置 / AI / 权限完成 light 6 张、dark 4 张、accessibility 4 张和 4 张同屏对照；010F 卡片编辑完成 light / dark default + changed、accessibility top + bottom 和 1 张同屏对照；010G 完成 dark / accessibility-extra-large 各 8 张高密度页矩阵、dark 与 Reduce Motion 永久流程；010H 双轴审查归零、视觉复验 1 / 1、定向 87 / 87、清理后全量 258 / 258；最终实施交接见 `docs/handoffs/UI-REDESIGN-IMPLEMENTATION-HANDOFF-20260716.md` | PASS |

设计与实现均已闭环；STAGE-010A～010H 已依次验收 PASS。真实 iPhone VoiceOver、触觉、系统 HealthKit 权限面板与真实 AI 请求仍是明确的未外推边界，不影响本轮 Simulator UI 改版完成判定。
