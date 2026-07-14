# STAGE-007D：Today 证据时间线与五栏导航

> 状态：PASS（2026-07-14；实现基线 `a76d958`）
>
> 执行者：Coder 分两步实现；主架构师逐步验收并负责最终视觉 QA

## 1. 唯一目标

把用户已选择的“按时间展开的健康证据线”落成可用的 SwiftUI Today 首屏，并把一级导航收敛为「今日 / 饮食 / 用药 / 趋势 / 更多」五栏；Today 只消费 `TodayEvidenceLoader`，不得在 View 中重新拼 SQL、推断缺餐/漏服、伪造睡眠或活动发生时间。所有现有记录、趋势、来源、同步、数据质量、告警、总结、运动和设置能力必须仍可到达。

本阶段不增加健康算法、schema、同步、HealthKit、通知、LLM、饮食保存或用药写入能力。视觉参考只决定层级、留白、圆角卡片、图标与时间线语言；事实内容继续受 STAGE-007B/C/008 约束。

## 2. 视觉基线与明确纠偏

参考图：

```text
/Users/nortepro/.codex/generated_images/019f5b92-8926-7d51-af2d-50fac3a30f9f/exec-fb6ed132-cfec-404c-9f9b-9808108439f4.png
```

沿用：

- 大标题“今日”与本地日期；右上数据质量状态入口；
- 一张主要圆角证据卡，清晰区分日汇总、真实记录时间线与来源覆盖；
- 现有 `CardTheme` 色系、系统语义背景和 SF Symbols；不另造品牌色或图标资产；
- 五栏标签和图标层级接近参考图，但使用系统 TabView，不复制图片中的自绘底栏。

必须纠正：

- `sleep_seconds` 只能叫“当天睡眠汇总”或等价事实，不得写“昨夜”，不得显示 23:41–07:05、07:05 等无法证明的起止/发生时间；
- 活动日聚合不得放到 09:33 等具体时刻，也不得把 `computedAt` 当活动发生时间；
- 没有持久化餐次时不得生成“午餐待记录”，没有用药日志时不得生成“漏服”；
- `scheduledFallback` 只能显示“计划 HH:mm”并明确“动作时刻未记录”，不得伪装为实际服药/跳过/延后时间；
- 能量缺口是当日派生证据，只放在日汇总，不进入有时刻的记录时间线；
- source coverage 只能称“当日原始样本覆盖”，不得写成某个 sleep/activity 字段的确定来源；餐次来源只在餐次行表达；
- 不展示食品数据库、健康评分、自动目标、建议、诊断或因果关系。

## 3. 两步实现顺序

### 3.1 STAGE-007D1：Today 页面（先不接 Root）

只允许新增：

```text
UI/Today/TodayEvidencePresentation.swift
UI/Today/TodayView.swift
Tests/TodayEvidencePresentationTests.swift
```

完成纯展示映射、Today 加载状态、日汇总、真实记录时间线、来源 footer、交互回调与 previews。不得改 RootView、现有 Tab、已有页面或 UITests。主架构师验收 D1 后才生成/执行 D2。

### 3.2 STAGE-007D2：五栏接线与“更多”能力映射

只允许：

```text
App/RootView.swift
UI/More/MoreView.swift
UI/SyncCenter/SyncCenterView.swift
UITests/SmokeTests.swift
```

接入 Today，调整五栏，把 SyncCenter 从自带根 NavigationStack 改成可嵌入 More 的 destination，并更新真实 UI smoke。不得在 D2 修改 D1 已验收的展示语义；若必须修改，先停下报告。

### 3.3 主架构师视觉 QA

Coder 不宣布视觉 PASS。主架构师必须使用 architect-only disposable Simulator，不能在用户或既有验收 Simulator 上准备视觉数据：

1. 用 `simctl create` 新建独立 iPhone 17 / iOS 26.5 设备，安装候选 App，并以第 5 项固定参数启动一次，让 App 自己跑真实 migration；
2. 等待首次 Today loaded 后继续等待自动 incremental sync 完全静止：轮询 disposable DB，直到 `sync_jobs` 不存在 `pending/running`，同时确认 `SyncEngine` UI 不再 busy；记录 migration、sync job 与各表计数。此后保持同一 App 进程在前台，不 terminate、不 relaunch、不再次触发 scene active；
3. 用 `simctl get_app_container` 定位这个一次性设备的 App 容器；仅在确认 quiescent 后，用带 `PRAGMA busy_timeout=5000` 和显式 transaction 的 `sqlite3` 向该 disposable WAL DB 插入文档化的 meal/meal_item、medication plan/log、activity aggregate、quality/alert 和 raw coverage fixture。提交事务后只在仍运行的 Today 页面执行一次 pull-to-refresh并等待 loaded-only identifiers；不得通过 relaunch/前后台切换刷新。不得把 seeder、fixture 或 DB 切换代码提交进 App，也不得连接用户/既有 Simulator 数据库；
4. 保存 fixture SQL、迁移列表、`integrity_check`、`foreign_key_check`、sync quiescent 证据与插入前后各表计数；这个一次性设备可在全部截图与审计结束后删除；
5. 固定矩阵为 iPhone 17 / iOS 26.5、portrait、light、`zh-Hans` / `zh_CN`、`Asia/Shanghai`；系统默认 Dynamic Type `large` 用于参考对照，另以 accessibility-large 验证不裁切。`design-qa.md` 必须记录并执行等价命令：`simctl ui <UDID> appearance light`、`simctl ui <UDID> content_size large`、`simctl status_bar <UDID> override --time 09:41 --dataNetwork wifi --wifiBars 3 --batteryState charged --batteryLevel 100`；启动 App 时使用 `SIMCTL_CHILD_TZ=Asia/Shanghai simctl launch ... -HM_DEBUG_BYPASS_ONBOARDING -AppleLanguages '(zh-Hans)' -AppleLocale zh_CN`。大字号轮次只改用 `simctl ui <UDID> content_size accessibility-large`，不 relaunch App；
6. fixture 固定为 App 进程在 `Asia/Shanghai` 得到的请求日本地日；fixture SQL 先记录 `dayKey/dayStart/dayEndExclusive`，全部 epoch 由同一时区计算。数据为：睡眠汇总 7h24m、steps 2340、active 98 kcal、basal 1500 kcal、distance 1.6 km、exercise 20 min；08:12 一条奥美拉唑 taken/actionTime/log dosage 20 mg；20:00 再有一条 `action_at = NULL` 的 deferred/scheduledFallback 用药日志；11:28 一条早餐 412 kcal/P23/F14/C46 且分项 provenance manual；2 条当日未确认 alert；Apple origin 的当日 raw coverage。它只用于视觉密度，不改变产品合同；
7. pull-to-refresh 后等待 loaded-only `today-summary-sleep` / `today-timeline` / `today-source-coverage`，导出 Today 与 More 截图到 `/tmp/healthmanager-stage007d-visual-20260714/`，同时保留 fixture SQL 与审计文本；核对 fallback 行可见“计划 20:00 / 动作时刻未记录”，并通过可访问性树证明 label 没把计划时刻读成动作时刻；
8. 把参考图和同一 iPhone 17 视口、上述映射状态的 Simulator 截图放在一张对照图中检查；
9. 核对字体层级、圆角、卡片边距、图标、分隔线、截断、底栏与动态内容；
10. 对可见偏差做有界修正并重新对照；
11. 截图后再次读取 disposable DB，复核 fixture payload、migration/integrity/foreign-key、sync job state 与各表计数没有在插入后变化；在仓库根写 `design-qa.md`，记录 disposable UDID、系统/语言/时区/字号、fixture 前后审计、截图与对照图。只有关键交互和证据纠偏全部满足才写 PASS。

### 3.4 执行中取证修订

第 3.3 节的同进程轮次完成了视觉对照和 Dynamic Type 截图，但独立规格复核发现，最终设备的原始 pre/post 数据库输出与 accessibility tree 没有一并归档；因此不把未归档的 PID、刷新过程或数据库陈述继续作为正式证据。

主架构师随后在全新 disposable Simulator `ABE5E729-5935-4076-A7FF-C022833BFB85` 上执行 accepted archival audit：

1. 正式 App 首次启动完成 migration、incremental sync 与 projection backfill 后终止；在 App 不运行时连续三轮记录 migration、projection version、sync quiescence、表计数、`MAX(computed_at)`、integrity 与 FK；
2. 应用原 guarded base fixture，再应用 guarded supplemental raw fixture。补充 raw fixture 为 steps / active / basal / distance / exercise / sleep 提供同一 Apple source 的最小原始样本，使下一次正式冷启动的正常 incremental aggregation 能重建相同日聚合；
3. 用临时 architect-only XCUITest 启动未修改的生产 App，等待 loaded-only identifiers，断言 sleep 与 scheduled fallback 的精确 accessibility label，并从 xcresult 导出原始 tree 与 screenshot；
4. 测试后重新定位 Xcode 重装产生的新容器，复核业务 payload invariant `PASS`、migration v1…v5、integrity ok、FK 0、active sync job 0。允许并记录启动产生的 succeeded sync job 与 `computed_at` 更新，不把它们误报为“字节级完全无差异”；
5. 导出证据后删除临时 audit test、重新生成工程，并以正式 production smoke 1/1 证明提交候选不含取证入口。

这是一项有依据的取证方法修订：它保留真实 App 冷启动和聚合生命周期，并以原始样本让 fixture 对该生命周期闭合；没有向产品提交 seeder、reload seam、debug database 或同步绕过。完整索引见：

```text
/tmp/healthmanager-stage007d-visual-audit-accepted-20260714/README.md
/tmp/healthmanager-stage007d-visual-audit-accepted-20260714/pre-fixture-audit.txt
/tmp/healthmanager-stage007d-visual-audit-accepted-20260714/post-fixture-pre-launch-audit.txt
/tmp/healthmanager-stage007d-visual-audit-accepted-20260714/post-screenshot-audit.txt
/tmp/healthmanager-stage007d-visual-audit-accepted-20260714/runtime-audit.xcresult
```

## 4. Today 状态与数据流

`TodayView` 使用项目现有 `@EnvironmentObject AppEnvironment/SyncEngine`，feature-local 状态保持值类型，不新增 ViewModel、repository、protocol 或全局 router。

至少有互斥状态：

- loading：保留主要布局节奏的简洁 placeholder 或单一 ProgressView；
- loaded：保存一个 `TodayEvidenceSnapshot`；
- failed：显示“加载失败”与真实重试按钮，不能伪装成成功空日；取消任务不显示错误；
- 成功空日属于 loaded，不与 failed 混淆。

加载要求：

- `TodayEvidenceLoader(database: environment.database).load(forLocalDay: Date(), calendar: .current)` 是唯一事实入口；
- 使用 `.task`、`.refreshable`，并在 `environment.localDataTick`、`sync.aggregationTick`、`sync.lastResult` 改变时刷新；
- 所有触发统一进入一个 reload seam；新请求必须取消或以单调 generation 失效旧请求，每个 completion 在写 state 前检查 cancellation 与 generation，较早快照不得覆盖较新结果。首次加载才显示全屏 loading；后续刷新在请求期间可保留已有 content；取消保持当前状态且不显示错误；
- 不在 `body` 发起读取，不复制 SQL/营养/能量/来源算法，不写库；
- `TodayView` 自己拥有 NavigationStack；跨一级功能使用一个显式 `TodayDestination` 回调让 `MainTabView` 切 Tab，不引入共享全局 path。

## 5. Today 内容合同

### 5.1 Header 与质量入口

- 标题“今日”，副标题是调用方本地 Calendar/Locale 的日期；不可硬编码 7 月 14 日；
- quality pill：当日未确认 alerts > 0 时显示“n 项待确认”；无 alert 且已对账显示“暂无待确认”；未对账显示“尚未对账”；
- pill 可点击：有 alerts 进入 `AlertsView`，否则进入 `DataQualityDetailView`；不得把“没有 alert”写成“数据完整/健康正常”。

### 5.2 日汇总（无发生时刻）

三类 compact row，均可切到「趋势」：

1. 当天睡眠汇总：有限非负 `asleepSeconds` 格式化为小时/分钟；nil 为“暂无睡眠汇总”；合法 0 显示 0 分钟。不得显示起止时间、效率或单一来源。
2. 当天活动汇总：展示已知 steps；可在次行组合已知 distance、active kcal、exercise minutes；全部未知时显示“暂无活动汇总”。合法 0 保留。
3. 当日能量证据：只使用 snapshot 的 `energyBalance`；完整时可显示消耗、摄入、缺口/盈余事实。noMeals、incomplete、burn 未齐时显示对应“尚无餐次证据 / 餐次热量不完整 / 消耗数据不足”，不得用 0 继续计算。

`computedAt` 如展示只能标成“计算于”，本阶段默认不放首屏，避免误读。

### 5.3 真实记录时间线

只遍历 `snapshot.timelineEntries`，稳定 ID 使用 entry.id：

- meal：左侧 `HH:mm`，标题来自 meal kind；主值是保守 calories 或“热量未完整记录”；次行只组合已知 P/F/C；来源只来自 `provenanceKinds`，空集合显示“来源未记录”，不得默认 manual；点击切换「饮食」Tab；
- medication actionTime：左侧实际 `HH:mm`，标题使用 planName 或“用药记录”，展示 action 与合法 log dosage；
- medication scheduledFallback：左侧明确“计划 HH:mm”，正文必须出现“动作时刻未记录”；仍可展示持久化 action，但不得把计划时间描述为动作时间；点击切换「用药」Tab。

无真实 meal/medication 日志时，不画虚构节点；显示“今天还没有餐食或用药记录”及“记录餐食 / 查看用药”两个真实入口。这个空状态不等于缺餐或漏服结论。

### 5.4 原始来源覆盖

- footer 标题“当日原始样本覆盖”；列出 `sourceCoverage` 的 Today origin label 与可选 sourceName，允许展示样本数；
- 无覆盖时写“当日暂无原始样本来源记录”；
- 点击进入 `SourcesView`；不得把餐次 provenance 混进 HealthKit raw coverage，也不得声称 aggregate dominant source。

## 6. 展示 seam、组件与可访问性

新增一个纯值 `TodayEvidencePresentation`（或等价深模块），只负责本地化日期/时间、单位、meal/action/origin/provenance label 和 unknown 文案；不得重新判定 nutrition、energy 或日期归属。它必须可由 unit tests 直接调用。

视图拆成小组件，避免一个 giant body。建议层级：

```text
TodayView
└── TodayScreenContent
    ├── TodayHeader
    ├── TodayEvidenceCard
    │   ├── TodayDailySummarySection
    │   ├── TodayTimelineSection
    │   └── TodaySourceCoverageFooter
    └── loading / failed overlays
```

要求：

- 小规模固定内容用 `ScrollView + VStack`；不嵌套同轴滚动；
- 使用现有 `CardTheme`、系统语义色、Dynamic Type 和 SF Symbols；不创建手工 SVG/emoji/占位资产；
- 不用 `AnyView`，不以数组 index 作为可变 timeline identity；
- 点击区域至少 44pt；长文案允许换行，不固定卡片高度，不用会裁切辅助功能字号的 `lineLimit(1)`；
- 交互元素有稳定 identifier：`today-screen`、`today-quality-pill`、`today-summary-sleep`、`today-summary-activity`、`today-summary-energy`、`today-timeline`、`today-timeline-<entry.id>`、`today-source-coverage`、`today-load-error`、`today-retry`；其中 summary/timeline/source identifiers 只挂在 loaded content，不能让 loading/error placeholder 伪装成 loaded；
- previews 只挂载不含 EnvironmentObject、loader task 或数据库读取的纯值 `TodayScreenContent`（或等价 content seam），至少覆盖 loaded、成功空日、loading、failed 和一个 accessibility 大字号状态；loaded fixture 必须同时包含 `.actionTime` 与 `.scheduledFallback` 用药行，后者可见文案与 accessibility label 都明确“计划时间 / 动作时刻未记录”。fixture 是明确展示数据，不连接真实 DB/网络/HealthKit。D1 Coder 只证明 preview 声明可编译；主架构师必须在 D1 验收时实际 render 五个 preview 状态并导出截图，任一缺环境崩溃、时基误读或裁切都不能写 D1 PASS。

## 7. 五栏与 More 能力映射

`MainTabView` 用一个稳定 `MainTab: Hashable` 和 `TabView(selection:)`：

| Tab | 标签 | 系统图标 | 根内容 |
|---|---|---|---|
| today | 今日 | `calendar` | `TodayView` |
| diet | 饮食 | `fork.knife` | `DietView` |
| medication | 用药 | `pills` | `MedicationView` |
| trends | 趋势 | `chart.bar.fill` | 现有 `DashboardView` |
| more | 更多 | `ellipsis` | `MoreView` |

More 使用自己的 NavigationStack 与 List，至少包含：

| 分组 | 入口 | 目标 |
|---|---|---|
| 数据与同步 | 数据来源 | `SourcesView` |
| 数据与同步 | 同步中心 | `SyncCenterView` |
| 数据与同步 | 数据质量 | `DataQualityDetailView` |
| 数据与同步 | 告警 | `AlertsView` |
| 分析与记录 | 日报 / 周报 | `SummaryView` |
| 分析与记录 | 运动记录 | `WorkoutsView` |
| 应用 | 设置 | `SettingsView` |

Dashboard 内原有下钻可保留；More 的显式入口证明能力没有因 Tab 调整而丢失。不得删除或重命名现有目标 View。

## 8. 自动化证据

### 8.1 D1 unit

`Tests/TodayEvidencePresentationTests.swift` 至少覆盖前八类展示合同；第九项由静态门执行：

1. 本地日期与 24 小时时间，不硬编码固定日期；
2. sleep nil / 0 / 7h24m，且任何输出不含“昨夜”或起止推断；
3. activity 全未知、合法 0、已知 steps/distance/energy/minutes；
4. energy complete deficit、surplus、noMeals、incomplete、burn 不齐；
5. meal type、known 0 calories、incomplete calories、部分 macros 与空 provenance；
6. medication 三种 action、actionTime 与 scheduledFallback 文案严格区分、plan/log dosage 不混淆；
7. quality absent / reconciled-no-alert / n alerts；
8. 七种 source origin 与空 source coverage；
9. 静态扫描 previews/production 文案不包含“昨夜”“尚未记录午餐”“食物数据库”等越界词。

### 8.2 D2 UI smoke

更新 `SmokeTests.test_tabsAndCommonFlows_rendered`：

- 启动后先看到“今日”和 `today-screen`；随后必须等待 loaded-only 的 `today-summary-sleep`、`today-timeline` 与 `today-source-coverage`，并断言 `today-load-error` 不存在，不能让永久 spinner/error 假通过。若当时没有真实 timeline entry，还必须出现 loaded-empty 文案“今天还没有餐食或用药记录”；保存 Today screenshot attachment；
- 五个 Tab 标签完整且旧“来源/同步中心”不再是一级 Tab；
- 饮食添加、用药计划编辑原 smoke 继续工作；
- 「趋势」进入现有“摘要”；
- 「更多」进入 More，并依次证明数据来源、同步中心、设置可导航和返回，同时保存 More screenshot；
- 不使用 debug seed、SQLite 旁路或网络；已有 meal persistence/reuse UI tests 不修改、不降级。

### 8.3 主架构师全量门

- D1/D2 每步先有真实 red 再 green；
- 最终 `TodayEvidencePresentationTests`、`TodayEvidenceLoaderTests`、相关营养/睡眠定向测试 PASS；
- 全量 `HealthManagerTests` 0 failed/0 skipped；
- 全量 `HealthManagerUITests` 0 failed/0 skipped；
- iPhone 17 / iOS 26.5 Simulator build 0 error/0 warning；
- `git diff --check`，生成的 xcodeproj ignored；
- D1 五个纯值 preview 状态均有实际 render 截图且无缺环境崩溃/裁切；visual comparison 与 `design-qa.md` PASS；
- 只读审计常规验收 Simulator 主库，证明导航/浏览没有新增 meal/log/alert/raw sample 或修改既有记录；视觉 fixture 只能存在于已记录 UDID 的 disposable Simulator，不能混入该副作用结论。

## 9. 禁止范围

- schema/migration、DatabaseManager、TodayEvidenceLoader、MealStore、Aggregator、Reconciler、HealthKit、同步算法、通知、LLM、饮食/用药写入语义；
- debug seed、生产 fixture、App 内测试数据库切换、清库或删除用户/既有 Simulator 数据；唯一例外是第 3.3 节由主架构师在 disposable Simulator 的真实 migrated App 容器中准备外部 fixture，且不得进入产品代码或常规自动化结论；
- 新健康指标、评分、目标、建议、缺餐/漏服、因果、诊断、社区、广告、电商或内容流；
- 把 Dashboard 删除或重写成 Today；“趋势”只复用现有 Dashboard；
- 自绘底栏、手工 SVG、emoji 图标、新图片资产、网络或第三方依赖；
- Coder 修改 docs、commit、tag、push。

若严格实现需要越界，停止并报告，不自行扩大范围。

## 10. 正式结果

- 状态：PASS
- D1：PASS。展示合同、并发 generation/cancellation seam、五类纯值 preview 与 locale 修正均验收；最终展示定向单测 12/12。
- D2：PASS。五栏为「今日 / 饮食 / 用药 / 趋势 / 更多」，More 七个能力入口完整；独立 Coder 与主架构师 UI green 均为 1/1。
- 视觉 QA：PASS；原始截图/对照与补充 accepted archival audit 均已复核，详见仓库根 `design-qa.md`。
- 验收日期：2026-07-14（Asia/Shanghai）
- 验收 commit：本文件所在 STAGE-007D checkpoint。
- 自动化证据：
  - 最终定向合同 41/41：`/tmp/healthmanager-stage007d-final-targeted-20260714-attempt01.xcresult`
  - 全量 unit 242/242，0 failed / 0 skipped：`/tmp/healthmanager-stage007d-final-unit-20260714-attempt01.xcresult`
  - 全量 UI 6/6，0 failed / 0 skipped：`/tmp/healthmanager-stage007d-final-ui-20260714-attempt01.xcresult`
  - 独立 iPhone 17 / iOS 26.5 build 0 error / 0 warning：`/tmp/healthmanager-stage007d-final-build-20260714-attempt01.xcresult`
  - 导航副作用 smoke 1/1，测试后常规验收库 meal / item / medication plan / log / alert / raw sample 均为 0：`/tmp/healthmanager-stage007d-side-effect-smoke-20260714-attempt01.xcresult`
  - accepted archival runtime audit 1/1：`/tmp/healthmanager-stage007d-visual-audit-accepted-20260714/runtime-audit.xcresult`
  - 删除临时 audit test 后的正式 production smoke 1/1：`/tmp/healthmanager-stage007d-post-audit-production-smoke-20260714-attempt01.xcresult`
  - 原 P1 归档缺口独立复核：PASS；复核后 disposable audit Simulator 已删除，原始证据包保留。
- 截图与对照图：`/tmp/healthmanager-stage007d-visual-20260714/`；D1 preview 为 `/tmp/healthmanager-stage007d1-previews-20260714/`。
- 原始归档：`/tmp/healthmanager-stage007d-visual-audit-accepted-20260714/`；disposable Simulator `ABE5E729-5935-4076-A7FF-C022833BFB85`；base fixture SHA-256 `7beba9f61c70b148d8132b5ed3938fc8d9d3a4be0e7990320fcb194e4fb33b27`；supplemental raw fixture SHA-256 `e1349365a6127d37ecfb480ef59e72297b650035ead871116c1ab7ce3cefb268`；截图后业务 payload invariant `PASS`、migration v1…v5、integrity ok、FK 0、active sync job 0。
- Accessibility tree：精确包含“当天睡眠汇总，7 小时 24 分钟”和“奥美拉唑，计划时间 20:00，已延后，动作时刻未记录”，且不包含“动作时间 20:00”。
- 残余风险：fixture 只证明视觉密度和证据措辞；真实 HealthKit、真实用户升级、VoiceOver 与真机后台同步不由 Simulator 证明，继续由 STAGE-009 标记 INCOMPLETE。
