# STAGE-007B：可信饮食与热量缺口数据合同

> 状态：READY（STAGE-007A 已选择方案 1；软件实现基线 `ff67ca1`）
>
> 执行者：Coder；主架构师独立验收

## 1. 唯一目标

修正 Dashboard 当前把未知餐次营养静默当成 0、并在摄入或消耗组成不完整时仍计算热量缺口的问题，为后续 Today 证据时间线提供可信 payload。

本阶段不实现 Today 页面或导航。只修正既有饮食卡片、热量缺口卡片与对应详情序列的 unknown/complete 语义。

## 2. 已确认的问题

当前 `DashboardLoader` 有四条会制造错误确定性的路径：

1. 今日餐次读取用 `row[... ] ?? 0` 累加 calories/protein/fat/carbs；任一餐次为 NULL 时，汇总看起来仍是完整数字。
2. `DietCardData.MealRow.kcal` 非 optional，单餐未知热量被显示成 0。
3. 日饮食序列与缺口序列使用 `SUM(COALESCE(calories_kcal, 0))`；不完整日被画成完整数据点。
4. 缺口用缺失组成的 0 替代值计算；缺少 active、basal 或完整摄入时仍可能显示 `burned - intake`。

这与 ADR-001 “未知值继续是未知值”、工作流验收协议“不得把 nil 静默变成 0”及本产品对活动能量/热量缺口可信度的优先级冲突。

## 3. 核心类型合同

在 `DashboardData.swift` 中建立最小值类型，不引入 ViewModel、protocol、repository 或新服务：

- `DietCardData` 使用现有 `MealNutritionTotals?` 保存今日四项保守汇总：
  - 无餐次时 totals 为 nil；
  - 有餐次时，每一营养字段只有在全部餐次该字段非 nil 且 finite 时才有总值；
  - 合法 0 是已知值，不得被改回 nil；
  - 复用现有 `MealNutritionProjection`，不得在 loader 再写第二套保守求和规则。
- `MealRow.kcal` 改为 `Double?`，逐餐保留未知。
- 新增 `DietCaloriesEvidence`（或同等小枚举）区分：无餐次、存在未知/非有限热量、完整且带数值。合法 0 属于完整。该枚举同时用于今日 snapshot、日序列内部判断和 deficit breakdown，不能在三处各造一套状态。
- `DeficitCardData` 保存 active、basal 与 intake evidence，`todayBurned`、`todayIntake`、`todayDeficit` 由这些事实计算：
  - active、basal、完整 intake 三者全部存在时才生成 deficit；
  - 任一缺失时 deficit 必须为 nil；
  - 不得以 0 代替缺失 active、basal、无餐次或不完整餐次。

类型必须是 `Equatable`、`Sendable`（与现有 snapshot 一致），状态命名要直接表达证据，不使用“正常/异常/准确”等结论词。

## 4. Loader 与序列合同

- 今日餐次先保留四项 raw optional，再用 `MealNutritionProjection.project` 生成 totals。
- 每餐展示 payload 保留 `calories_kcal` 的 nil。
- snapshot 的 `DietCardData.last7Days` 仍是不可选 `DatedDouble`，因此只保存完整记录日，并增加明确的近 7 日不完整标记；只要窗口内存在有餐次但 calories 不完整的日期，`DietCard` 就必须抑制趋势结论并显示“近 7 日记录不完整”或同等事实文案，不能把缺日压缩后继续比较首尾值。
- `loadDietSeries` 返回的 `MetricPoint` 必须把有餐次但 calories 不完整的日期保留为 nil gap；完整且总和为 0 的日期保留 0 点。
- `deficitSeries` 只为 active、basal 与完整 intake 同日齐备的日期生成点；只存在消耗或只存在摄入都不得生成缺口。
- `loadDeficitBreakdown` 保留 active、basal 与 `DietCaloriesEvidence`；对外可取得 optional intake，但必须能区分无餐次与不完整餐次。`deficit` 改为 optional，仅三项齐备时存在。
- 今日、近 7 日、周/月/年与 breakdown 共用“全部餐次该字段非 nil 且 finite”的规则。优先在索引限定的日期范围内读取 raw optional 行、按本地日期分组，并复用 `MealNutritionProjection` 或单一共享 helper；不得让 snapshot 用 Swift finite 规则而序列只用 SQL `COUNT`。SQL 不用 COALESCE 抹掉 NULL，也不得扫描窗口外餐次。
- 保持本地日边界、索引范围、日期排序和现有数据库 schema 不变。

## 5. 现有卡片与详情最小适配

`DietCard`：

- 无餐次继续显示“今天还没记录”。
- 有餐次但总热量未知时主值为“—”，并显示“存在未填写热量的餐次”或同等事实文案。
- 单餐未知显示“—”，合法 0 显示 0。
- P/F/C 每项分别显示保守总值或“—”；不因其他宏量已知而替未知补 0。
- 只有总热量已知时才绘制按餐 ProgressView，避免用不完整分母。
- 近 7 日存在不完整 calorie 记录时不显示 TrendChip 的涨跌结论，改为事实性不完整提示。

`DeficitCard` 与缺口详情：

- 缺口未知时根据事实说明缺少完整消耗、没有饮食记录或饮食热量不完整；不只固定写“待 basal 数据补充”。
- 明细中每项仍可显示已知值；总缺口只有三项齐备才显示，否则显示“—”和缺失说明。
- 饮食与缺口 footnote 明确“只在当日所需字段完整时纳入图表/计算”。
- 不新增颜色等级、目标、建议或诊断。

## 6. 自动化证据

新增 `Tests/DashboardNutritionEvidenceTests.swift`，至少覆盖：

1. 无餐次：totals nil、evidence 为无餐次、即使 active+basal 齐备也不计算 deficit。
2. 全部字段完整：多餐汇总正确；合法 0 保持已知；active+basal-intake 的 deficit 正确。
3. 任一餐次 calories 为 nil：今日 calorie total 与 deficit 为 nil；已知单餐值不被改成 0，未知单餐仍 nil。
4. 四个营养字段分别执行保守汇总：某字段任一 NULL 只使该字段 nil，不污染其他完整字段。
5. active 或 basal 任一缺失：完整 intake 也不生成 deficit。
6. snapshot 近 7 日：完整记录日保留数值；出现不完整 calorie 日时设置抑制趋势的标记，不继续给出首尾趋势结论。
7. 饮食周/月/年序列：完整日生成点，不完整日保持 nil gap，完整 0 日是 0 点。
8. 缺口序列：只生成三项齐备的日期；消耗-only、摄入-only、不完整摄入均为空。
9. `loadDeficitBreakdown` 的 deficit 只在三项齐备时存在，保留已知 0，并能区分无餐次与不完整餐次两种 intake evidence。
10. 至少一个可被 SQLite/GRDB 往返的非有限值（例如 infinity）在今日、序列与 breakdown 中都按不完整处理；若 NaN 被 SQLite 规范化为 NULL，测试应记录这一实际行为而不是伪造 round-trip。

现有 `DailyAggregatorEnergyTests` 必须继续通过，特别是完整 1,100 kcal 摄入下的 900 kcal 缺口。

## 7. 允许与禁止范围

允许：

- `UI/Dashboard/DashboardData.swift`
- `UI/Dashboard/Cards/DietCard.swift`
- `UI/Dashboard/Cards/DeficitCard.swift`
- `UI/Dashboard/Detail/MetricDetailView.swift`
- 新增 `Tests/DashboardNutritionEvidenceTests.swift`
- xcodegen 必要生成结果

禁止：

- 修改 schema、migration、`MealNutritionProjection`、`MealStore`、餐食编辑/复用/证据 UI 或 HealthKit 写入
- 修改 DailyAggregator 能量算法、来源优先级、同步、对账阈值或数据质量定义
- 实现 TodayView、时间线、Tab、更多页或 STAGE-007C/D
- 新增默认目标、自动建议、热量等级、诊断、食品库、OCR、条码或 AI 动作
- 用 0、空字符串或隐藏行伪装未知
- 修改 docs、commit、tag、push

若所需修复必须越界，停止并报告，不自行扩大范围。

## 8. 验收门

- 新测试与 `DailyAggregatorEnergyTests` 定向通过。
- 主架构师独立跑全量 unit、全量 UI 和 build。
- 静态检查生产 SQL 不再对 `meal_records.calories_kcal` 使用 `COALESCE(..., 0)` 生成饮食/缺口事实。
- `git diff --check` 通过，diff 只含白名单文件。
- Simulator 证明 optional 合同、卡片编译与既有交互未回归；它不证明用户是否完整记录真实饮食，该事实继续由 UI 明示。

## 9. 正式结果

- 状态：PENDING
- 验收日期：—
- 验收 commit：—
- 证据：—
- 残余风险：—
