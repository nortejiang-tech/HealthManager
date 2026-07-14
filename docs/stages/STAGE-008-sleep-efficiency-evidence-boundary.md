# STAGE-008：睡眠效率证据边界

> 状态：PASS（软件与 Simulator 范围；与等待用户选择的 STAGE-007A 解耦）
>
> 执行者：Coder；主架构师验收

## 1. 唯一目标

在现有数据不足以证明睡眠效率算法正确时，明确停止消费和传播 `sleep_efficiency`，并确保每次日聚合都会清除该保留列中的历史非空脏值；保留已验证的 Asleep 时长展示，不生成、猜测或补零睡眠效率。

本阶段不计算新指标。未来只有在真实 HealthKit 数据证明 inBed/asleep 配对、跨午夜归属、阶段重叠与来源选择规则后，才可以通过新的 ADR 重新启用效率计算。

## 2. 当前证据与决策

2026-07-14 主架构师核对当前代码与实际 iPhone 17 Simulator 数据：

- `DailyAggregator` 对 `sleep_efficiency` 的 INSERT 固定写 NULL，但 `ON CONFLICT` 没有更新该列，历史非空值可能残留。
- `DashboardLoader` 仍 SELECT 并装入 `lastNightEfficiency`，但 `SleepCard` 与其他 View 完全不显示该值；这是无效且容易被未来误用的隐式数据路径。
- `sleepDuration` 只按样本 `start_at` 所在日、单一 dominant source 和 Asleep category 汇总。它不建立 inBed/asleep 成对夜间窗口，也不合并重叠区间。
- 当前 Simulator 主库有 98 条 `activity_metrics_daily`，其中 `sleep_seconds` 非空 0 条、`sleep_efficiency` 非空 0 条；`health_samples_raw` 没有睡眠样本。Simulator 无法验证真实设备的 Apple Watch/iPhone/第三方睡眠阶段组合。

睡眠效率通常需要“实际睡眠时长 / 在床时长”，但当前证据无法回答：

1. 跨午夜的一晚归属哪一天；
2. inBed 与详细 asleep stages 是否来自同一来源、是否完整覆盖；
3. asleepUnspecified 与 core/deep/REM 是否重叠；
4. 多来源同晚记录如何选取，unknown bundle 是否会错误合并；
5. 缺少 inBed 时是否应展示（本阶段答案是不得展示）。

因此采用保守方案：**隐藏并清除，暂不计算**。这比给出未经真机数据验证的百分比更符合 HealthManager 的可信数据边界。

## 3. 数据合同

- 数据库 schema 不变；不删除或重命名 `activity_metrics_daily.sleep_efficiency`。
- `DailyAggregator` 每次 rebuild 的 INSERT 与 UPSERT 结果都必须让 `sleep_efficiency` 为 NULL，包括覆盖既有非空值。
- `sleep_seconds` 继续保持现有 Asleep-only 语义，不在本阶段改变 dominant-source、日边界或阶段求和算法。
- `ActivityMetricsDaily.sleepEfficiency` 可保留为 schema 对应的 optional 保留字段，但注释必须明确：当前聚合会主动清空，任何读取方不得把它当成已实现指标。
- 不用 0、`—%`、默认 100%、已有 sleep hours 或任意推断替代未知效率。

## 4. UI 与读取合同

- 从 `SleepCardData` 删除 `lastNightEfficiency`，`DashboardLoader` 不再 SELECT/读取 `sleep_efficiency`。
- `SleepCard` 继续只显示昨晚 Asleep 时长与近 7 日时长，不新增效率行、百分号、异常颜色或解释。
- 睡眠详情页继续明确“汇总每晚 Asleep 状态时长（不含 inBed）”。
- 不改变 dashboard 布局、导航、图表、同步、HealthKit 请求类型或权限。

## 5. 自动化证据

新增聚焦 `DailyAggregatorSleepTests`，至少覆盖：

1. 既有 daily row 含非空 `sleep_efficiency` 时，rebuild 后该列变回 NULL。
2. 同一次 rebuild 仍正确写入当前既有语义的 `sleep_seconds`，证明清除效率没有破坏睡眠时长。
3. inBed (`value=0`) 与 awake (`value=2`) 不进入 Asleep 时长；至少一个 Asleep stage 仍进入。
4. `DashboardLoader` 能从 rebuild 后的 row 得到小时数；不再存在效率展示字段或读取 SQL。

测试只能通过 in-memory GRDB 写 fixture；不修改生产 schema，不依赖真实 HealthKit 或系统时间以外的外部状态。

## 6. 允许与禁止范围

允许：

- `Core/Aggregate/DailyAggregator.swift`
- `Core/Database/Models/ActivityMetricsDaily.swift`
- `UI/Dashboard/DashboardData.swift`
- 新增 `Tests/DailyAggregatorSleepTests.swift`
- xcodegen 必要生成结果

禁止：

- 修改既有 migration、增加/删除表列、直接改用户数据库
- 修改 `SampleMapper`、HealthKit 类型目录、同步 coordinator、source priority 或 `sleepDuration` 算法
- 修改 `SleepCard`、Metric detail、dashboard 布局、导航或 STAGE-007 原型
- 新增睡眠目标、评分、建议、诊断、颜色等级或通知
- 用 inBed/asleep 比值实现未经真机数据审计的效率算法
- 修改 docs、commit、tag、push

## 7. 完成标准与验证边界

- 新增睡眠聚合测试和现有 `DailyAggregatorEnergyTests` 通过。
- 全量 `HealthManagerTests`、全量 `HealthManagerUITests` 与独立 build 由主架构师运行。
- `git diff --check` 通过且 diff 只含白名单文件。
- 静态搜索证明生产 UI/loader 不再引用 `lastNightEfficiency` 或 SELECT `sleep_efficiency`；聚合 UPSERT 明确覆盖该列。
- Simulator 只证明 NULL 清理、Asleep 时长未回归和 UI 编译/现有截图不变；真实睡眠阶段分布与未来可计算性保持 INCOMPLETE，进入 STAGE-009 次日真机清单。

## 8. 正式结果

- 状态：PASS（软件与 Simulator 范围）
- 验收日期：2026-07-14
- 验收 commit：本文件所在 STAGE-008 checkpoint
- 决策结果：继续保留 schema 中的 optional `sleep_efficiency`，但停止从 Dashboard data payload 与 loader 消费该列；聚合 INSERT 写 NULL，UPSERT 用 `sleep_efficiency = excluded.sleep_efficiency` 主动覆盖历史非空值。未新增百分比、默认值、目标、评分或诊断，也未改变既有 Asleep 时长算法
- Coder 定向证据：`DailyAggregatorSleepTests` 与既有 `DailyAggregatorEnergyTests` 共 7/7；结果包 `/tmp/healthmanager-stage008-coder-unit-20260714.xcresult`。Coder build succeeded，0 error、0 warning；结果包 `/tmp/healthmanager-stage008-coder-build-20260714.xcresult`
- 主架构师定向复验：同一 7/7 测试在候选最终逻辑上独立通过；结果包 `/tmp/healthmanager-stage008-architect-targeted-20260714-01.xcresult`。测试预置历史非空效率，证明 rebuild 后为 NULL；同批 inBed=0、awake=2 不计入，而 Asleep=1 分别得到 1,800 秒与 3,600 秒；`DashboardLoader` 仍得到 1 小时和一条近 7 日值
- 全量证据：最终代码上的 `HealthManagerTests` 186/186；结果包 `/tmp/healthmanager-stage008-architect-full-unit-20260714-01.xcresult`。最终代码上的 `HealthManagerUITests` 6/6；结果包 `/tmp/healthmanager-stage008-architect-full-ui-20260714-01.xcresult`。独立 iPhone 17 / iOS 26.5 Simulator build succeeded，0 error、0 warning；结果包 `/tmp/healthmanager-stage008-architect-build-20260714-01.xcresult`
- 实际 Simulator 数据审计：只读查询运行中 app container 的 `health.sqlite`，`activity_metrics_daily` 为 `98|0|0`（总行数 | `sleep_seconds` 非空 | `sleep_efficiency` 非空），原始 sleepAnalysis 样本为 0。该库能证明当前没有可用于效率验证的数据，不能证明真实设备的阶段组合
- 静态边界：生产代码已无 `lastNightEfficiency`；Dashboard 查询只读取 `sleep_seconds`。Coder 实现候选仅修改 `DailyAggregator.swift`、`ActivityMetricsDaily.swift`、`DashboardData.swift` 并新增 `DailyAggregatorSleepTests.swift`；最终 staged checkpoint 另含主架构师填写的本验收文档。schema、migration、`sleepDuration`、HealthKit、同步、来源优先级、`SleepCard`、详情页、布局与导航均未改变，`git diff --check` 通过
- 双轴审查：以 `ac4c9f5` 为固定点审查 staged candidate。Spec 轴 PASS，0 阻断、0 非阻断；Standards 轴代码 PASS、无新增 smell，但发现 Coder 把“修改前理论上会失败”写成 red 证据而没有真实 red 结果。正式验收不采纳该推断，TDD red 明确记为 INCOMPLETE；green、全量测试、构建和数据库断言均有可复现结果包
- 执行记录：Coder 一次候选完成全部四个白名单文件，定向测试与 build 通过，主架构师未发现需要接管的技术实现缺陷；主架构师只修正一处未被数据证明的注释措辞，并独立完成全量验收、双轴审查与证据记录
- 残余风险：真实 Apple Watch/iPhone/第三方 sleepAnalysis 阶段分布、跨午夜归属、inBed/asleep 配对、阶段重叠、来源选择及未来效率可计算性均为 INCOMPLETE，进入 STAGE-009 次日真机清单。TDD red 未捕获，亦为 INCOMPLETE；本阶段不据此宣称 test-first 过程，只宣称最终合同已由自动化与静态证据验证
