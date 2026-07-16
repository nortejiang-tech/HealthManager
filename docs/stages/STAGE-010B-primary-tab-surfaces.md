# STAGE-010B：五个一级页面的证据型界面

> 状态：PASS
>
> 执行者：内部 Coder（`gpt-5.3-codex-spark`）；主架构师独立验收
>
> 依赖：STAGE-010A PASS

## 1. 唯一目标

在不改变任何数据、写入、导航目的地或业务状态机的前提下，把五个一级页面的 loaded / empty 主表面统一到已验收的“基线叙事 + 局部决策透镜”视觉语言：

1. 今日；
2. 饮食；
3. 用药；
4. 趋势；
5. 更多。

本阶段只改一级页面，不进入餐食编辑、餐食证据、复用、用药计划编辑、指标详情、同步、设置或 AI 下钻。

## 2. 必须保持的产品事实

- 未知值不是 `0`；没有样本、加载失败和成功空白保持不同。
- 不推断漏餐，不生成早餐 / 午餐 / 晚餐任务。
- 用药计划时间与实际动作时间分开；通知权限不是服药状态。
- 热量缺口缺任一输入就停止，不补零。
- 来源、确认、估算、需要处理分别使用现有语义 tone，并同时有图标 / 文字。
- 不添加评分、目标环、连续打卡、诊断、教练、社区、商业入口或新数据能力。

## 3. 允许修改

- `UI/Today/TodayView.swift`：只改 loaded 内容和为 loaded 服务的纯视觉组件 / Preview；不得触碰 reload、generation、cancel、loading、failure。
- `UI/Diet/DietView.swift`：只改 `DietView`、`MealRow` 与一级页纯展示组件；不得改 `MealEditView` 及其后续编辑逻辑。
- `UI/Medication/MedicationView.swift`：只改 `MedicationView`、`PlanRow`、`LogRow` 与一级页纯展示组件；不得改 `MedicationPlanEditView` 及其后续编辑逻辑。
- `UI/Dashboard/DashboardView.swift`、`UI/Dashboard/Cards/*.swift`：只改主页面组合和卡片视觉；不得改 loader、snapshot、route 或计算。
- `UI/More/MoreView.swift`：可改主页面视觉，全部既有入口与 identifier 必须保留。
- `UI/DesignSystem/HMDesignSystem.swift`：只增加至少被两个一级页面立即使用的最小共享组件。
- `App/RootView.swift`：仅在系统 `TabView` 的视觉标签确有必要时做最小修改；五栏、名称和目的地不变。
- 与上述纯展示 seam 直接相关的最小 Preview / UI 断言。

## 4. 禁止修改

- `Core/`、migration、database query、HealthKit、同步、通知调度、LLM、持久化、删除与写回逻辑；
- 任一编辑器、详情页、复用流程、设置或 AI 页面；
- `TodayEvidenceLoader`、`TodayEvidencePresentation`、`DashboardLoader`、`DashboardSnapshot`；
- 五栏顺序、名称、目的地、sheet / push 路由；
- 新 ViewModel / repository / router、第三方 UI 包、自绘 TabBar、运行时 fixture / debug router；
- 提交、tag、push。

## 5. 页面完成标准

### 今日

- 保留现有 evidence presentation 的全部真实字段、identifier 和点击目的地；
- 用编辑型标题、本地日期、质量入口、证据基线、一个决策透镜、安静时间线与来源尾部组织内容；
- 不新增任何漏餐、漏服、健康正常或因果判断。

### 饮食

- 一级页不再是默认系统 `List + Section` 拼装感；
- 顶部先解释今日营养证据是否完整，未知仍显示 `—`；
- “新增餐次”为唯一主动作，“复用历史”为次动作；
- 今日无记录只表示成功空白，不写“漏记”；近期餐次保留编辑、滑动删除与 identifier。

### 用药

- 计划、下一步动作和最近日志分层；“记一次”仍调用原 closure；
- 空计划提供真实添加动作；通知未授权只作为提醒能力状态；
- `taken / skipped / deferred` 仍来自日志原值，不重新推断。

### 趋势

- 保留编辑卡片、卡片顺序 / 隐藏、全部 metric route、质量与运动入口；
- 一个主叙事区域，指标卡更安静；不新增健康评分、目标、区间结论；
- `CardTheme` 继续只表达指标家族，语义状态使用 010A tone。

### 更多

- 顶部用简短数据去向 / 可信度路径解释“Apple 健康 → 本机 → 可选分析”；不得声称永不外发；
- 数据与同步、分析与记录、应用三组层级清楚；
- `more-sources`、`more-sync-center`、`more-data-quality`、`more-alerts`、`more-summary`、`more-workouts`、`more-settings` 和 `more-screen` 全部保留。

## 6. 视觉与无障碍门

- 参考：`01-today-master-structure-only.png`、`02-diet-main-structure-only.png`、`03-medication-main.png`、`04-trends-main.png`、`05-more-main.png`、`27-diet-empty.png`。
- 使用 010A 已验收 token；暖象牙背景、少量独立表面、排版和分隔线优先。
- 每页最多一个表达性功能视觉，不使用装饰渐变、玻璃堆叠或卡片套卡片。
- 系统 Dynamic Type；长文本无固定高度；主动作 44 pt；颜色不是唯一信号；dark mode 可读。
- 五个一级页面都提供不会触发真实写入的默认 / dark / accessibility-large 纯展示 Preview，或等价可复核展示 seam。

## 7. 验收与测试

Coder 必须：

1. `xcodegen generate`；
2. 新 DerivedData build；
3. 新 `.xcresult` 全量 test；
4. 返回文件清单、状态 / identifier 不变量、测试计数、warning / error 和未验证视觉边界。

主架构师另行：

- 逐文件 diff 与事实边界审查；
- 五个一级页面 light / dark / accessibility-large，外加 Diet empty，共至少 18 张运行态；
- 五张参考 / runtime 同屏对照；
- 重新读取 `.xcresult`，不接受尾行结论。

只有代码、视觉、无障碍、导航和全量测试全部通过，STAGE-010B 才能标为 PASS。

## 8. 结果

### 实现与边界

- 内部 Coder 的第一版因编译失败、重复入口和过量技术文案未被接受；主架构师按升级规则接管并完成修正。
- 最终修改范围为 `UI/DesignSystem/HMDesignSystem.swift`、五个一级页面和与“摘要”改名为“趋势”直接对应的一条 UI 断言；`Core/`、schema、loader、snapshot、写入和通知调度均未修改。
- `MealEditView` 至餐食 Preview seam、`MedicationPlanEditView` 至用药 Preview seam 与阶段起点逐字节等价（忽略文件分隔空行）；编辑器业务逻辑未进入 010B。
- 饮食页保留 `diet-add-meal`、`diet-reuse-meal`、餐次 identifier、编辑与原生侧滑删除；用药“记一次”、编辑和删除仍调用原 closure；趋势卡片、隐藏指标、质量、告警、运动和全部 metric route 可达；More 的八个既有 identifier 各保留一次。

### 主架构师返工与回归

首轮全量 UI 暴露自定义餐次容器在部分场景不能生成原生侧滑删除按钮。主架构师没有把它归为偶发测试，而是把有记录餐次改回支持 `.swipeActions` 的原生 `List` 容器，并在有记录时把餐次区提到首屏。原失败的三个 MealReuse 用例在独立结果包中 3 / 3 通过：

```text
/tmp/healthmanager-stage010b-diet-regression-attempt02.xcresult
```

### 视觉证据

- iPhone 17 / iOS 26.5（23F77）/ 简体中文 / portrait。
- Today、Diet、Medication、Trends、More 各有 light-large、dark-large、light-accessibility-large，另保留 Diet empty 三组，共 18 张：

```text
/tmp/healthmanager-stage010b-acceptance-20260716/screenshots/
```

- 五张 reference / runtime 同屏对照均已实际打开复核：

```text
/tmp/healthmanager-stage010b-acceptance-20260716/comparisons/
```

Diet 使用 `27-diet-empty.png` 与相同空白状态对照；Today、Medication、Trends 的参考图包含示例数据，而验收 Simulator 保持真实成功空白，因此对照只判定布局、信息层级、色彩和功能入口，不伪造数据或宣称像素等价。

### 最终自动化

```text
/tmp/healthmanager-stage010b-architect-final-20260716-attempt02.xcresult
```

- 258 / 258 passed；0 failed；0 skipped。
- HealthManagerTests 251 / 251；HealthManagerUITests 7 / 7。
- 0 编译错误。
- 已知 warning：`Tests/MealItemMigrationTests.swift:16` 的 `migrator` 未修改；另有三条无 AppIntents 依赖时跳过 metadata extraction 的工具链提示。本阶段未扩大范围清理它们。

主架构师结论：代码边界、一级页视觉、dark mode、accessibility-large、导航、侧滑删除和全量测试全部通过，STAGE-010B 正式 PASS。
