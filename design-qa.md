# STAGE-007D Design QA

> 结论：PASS
>
> 验收日期：2026-07-14（Asia/Shanghai）
>
> 范围：Today 证据首屏、五栏导航、More 能力入口、Dynamic Type 与证据语义；本文件不替代真机 HealthKit、VoiceOver 或真实用户数据验收。

## 1. 参考与判定边界

视觉参考：

```text
/Users/nortepro/.codex/generated_images/019f5b92-8926-7d51-af2d-50fac3a30f9f/exec-fb6ed132-cfec-404c-9f9b-9808108439f4.png
```

对照图：

```text
/tmp/healthmanager-stage007d-visual-20260714/today-reference-comparison.png
```

对照图把参考图按比例缩放到与 Simulator 截图相同的 1206×2622 视口并排放置后再目视复核。验收保留参考图的大标题、本地日期、状态 pill、白色圆角主卡、SF Symbols、留白层级和五栏导航；没有复制参考图中无法由当前数据库证明的睡眠起止、活动时刻、午餐待记录、食品数据库或单一聚合来源。

## 2. 尝试记录与验收环境

前两轮均未计入最终 PASS：

1. `D706B6DD-0972-4CA8-B8FB-A0ACF4D80FF1`：发现日期仍以英文显示，且最初静止门不足以排除 bootstrap catch-up，拒绝验收。
2. `35D6D827-1077-4E80-AB41-6970675D97DF`：LLDB 证明 `Locale.current` / `Locale.autoupdatingCurrent` 为 `en_CN`，而 `Locale.preferredLanguages` 为 `zh-Hans`；据此增加“界面首选语言 + 环境 region”的 locale 解析并补单测，再次重建。

视觉对照轮次：

- Simulator：`HealthManager-STAGE007D-Visual-PASS-20260714`
- UDID：`639CA5AC-8E21-4A68-8421-3E0235D89963`
- 设备 / Runtime：iPhone 17 / iOS 26.5（23F77）
- 方向 / 外观：portrait / light
- 语言 / 区域 / 时区：`zh-Hans` / `zh_CN` / `Asia/Shanghai`
- 参考字号：`large`；额外可访问性轮次：`accessibility-large`
- 状态栏：09:41、Wi-Fi 3 格、充电 100%

该轮次生成了第 1 节对照图及第 4 节全部 `large` / `accessibility-large` 截图。后续独立规格复核确认：这些视觉产物有效，但当时没有把最终设备的原始 pre/post 数据库输出和 accessibility tree 一并归档，因此不再用未归档的 PID、同进程或前后数据库陈述作为 PASS 依据。

为补齐可复核取证链，重新执行了一轮 accepted archival audit：

- Simulator：`HealthManager-STAGE007D-Visual-Audit-Final-20260714`
- UDID：`ABE5E729-5935-4076-A7FF-C022833BFB85`
- 设备 / Runtime：iPhone 17 / iOS 26.5（23F77）
- 方向 / 外观 / 字号：portrait / light / `large`
- 语言 / 区域 / 时区：`zh-Hans` / `zh_CN` / `Asia/Shanghai`
- 状态栏：09:41、Wi-Fi 3 格、充电 100%
- 原始证据包：`/tmp/healthmanager-stage007d-visual-audit-accepted-20260714/`
- 运行时结果：`runtime-audit.xcresult`，1/1 PASS；原始 accessibility tree 与截图均由 xcresult attachment 导出。

accepted archival audit 的关键环境命令：

```bash
xcrun simctl ui ABE5E729-5935-4076-A7FF-C022833BFB85 appearance light
xcrun simctl ui ABE5E729-5935-4076-A7FF-C022833BFB85 content_size large
xcrun simctl status_bar ABE5E729-5935-4076-A7FF-C022833BFB85 override --time 09:41 --wifiBars 3 --batteryState charged --batteryLevel 100
xcodebuild test-without-building \
  -project HealthManager.xcodeproj \
  -scheme HealthManager \
  -destination 'platform=iOS Simulator,id=ABE5E729-5935-4076-A7FF-C022833BFB85' \
  -only-testing:HealthManagerUITests/SmokeTests/test_stage007DDisposableVisualAudit_captureAccessibilityTree \
  -resultBundlePath /tmp/healthmanager-stage007d-visual-audit-accepted-20260714/runtime-audit.xcresult
```

上面的 audit test 只存在于临时架构师取证构建中；导出证据后已从 `UITests/SmokeTests.swift` 删除，重新生成工程，并以正式 production smoke 1/1 复核，因此不会进入提交。视觉对照轮次的 `accessibility-large` 仍只改变 `content_size`，没有 relaunch App。

## 3. 静止门与 fixture

accepted archival audit 使用 disposable Simulator 的真实 migrated WAL 数据库。Xcode test runner 重装 App 时数据容器 UUID 会变化，因此证据不把随机容器路径当稳定身份；pre-fixture 文件记录初始容器，post-screenshot 文件记录测试后的实际容器内容，二者都由同一 UDID 与 bundle ID 定位。所有写入只发生在 App 已终止时，使用 busy timeout、guard 与 `BEGIN IMMEDIATE`；没有向 App 提交 seeder、fixture、reload seam 或测试数据库切换代码。

完整生命周期与原始文件索引：

```text
/tmp/healthmanager-stage007d-visual-audit-accepted-20260714/README.md
/tmp/healthmanager-stage007d-visual-audit-accepted-20260714/pre-fixture-audit.txt
/tmp/healthmanager-stage007d-visual-audit-accepted-20260714/post-fixture-pre-launch-audit.txt
/tmp/healthmanager-stage007d-visual-audit-accepted-20260714/post-screenshot-audit.txt
```

插入前硬门连续三轮（每轮间隔 1.2 秒）一致：

- migration 顺序严格为 v1、v2、v3、v4、v5；
- `sync_jobs` pending / running 为 0，最近一次 incremental job 为 succeeded；
- `aggregates.projectionVersion = 4`；
- `activity_metrics_daily` 与 `body_metrics_daily` 均为 90 行，`COUNT/MIN/MAX/MAX(computed_at)` 稳定；
- meal / item / medication plan / log / alert / raw sample / data-quality 行均为 0；
- `PRAGMA integrity_check = ok`，外键违规 0；App 进程已终止。

本地日边界由 Simulator 当前时间和与 Loader 相同的 Foundation/Asia-Shanghai 规则计算：

```text
dayKey             2026-07-14
dayStart           1783958400
08:12              1783987920
09:00              1783990800
11:28              1783999680
20:00              1784030400
dayEndExclusive    1784044800
```

base fixture：

```text
/tmp/healthmanager-stage007d-visual-20260714/fixture.sql
SHA-256 7beba9f61c70b148d8132b5ed3938fc8d9d3a4be0e7990320fcb194e4fb33b27
```

补充 raw fixture：

```text
/tmp/healthmanager-stage007d-visual-audit-accepted-20260714/supplemental-raw-fixture.sql
SHA-256 e1349365a6127d37ecfb480ef59e72297b650035ead871116c1ab7ce3cefb268
```

base 事务内含 migration、静止、日界、clean-user-content 与 clean-current-raw-window guard；补充事务再次验证 base payload 与静止状态，并为 steps、active、basal、distance、exercise、sleep 各保存一条 Apple raw sample。这样正式 App 在 audit test 冷启动时照常执行 incremental aggregation，也会从 raw 数据重建出同一组日聚合，而不是依赖外部注入后强制刷新或绕开生产生命周期。该补充是一次性 audit 数据，不改变产品合同，也不进入仓库。

post-fixture / pre-launch 与 post-screenshot 的业务载荷一致；允许且记录了正式启动产生的第二条 succeeded incremental job 与 `computed_at` 更新。截图后 invariant SQL 为 `PASS`：

| 项目 | 结果 |
|---|---:|
| activity / body daily | 90 / 90 |
| meal / meal item | 1 / 1 |
| medication plan / log | 1 / 2 |
| data quality / unacknowledged alert | 1 / 2 |
| raw sample | 6 |
| active sync job | 0 |
| integrity / foreign key | ok / 0 |

当日 payload 为：睡眠 26,640 秒、2,340 步、active 98 kcal、basal 1,500 kcal、1,600 m、运动 20 分钟；11:28 早餐 412 kcal / P23 / F14 / C46；08:12 taken/actionTime 且日志剂量 20 mg；20:00 deferred 且 `action_at` / 日志剂量为空；2 条未确认 warning；6 条 Apple Watch / Apple origin raw sample。餐次 `hk_sync_id` 使用 fixture tag，避免视觉餐次被写回 HealthKit。

以上均为一次性视觉密度 fixture，不代表用户真实健康事实，也不建立 raw sample、日聚合、餐次、用药与告警之间的因果关系。

## 4. 截图与可访问性核对

默认 `large`：

```text
/tmp/healthmanager-stage007d-visual-20260714/today-large-top.png
/tmp/healthmanager-stage007d-visual-20260714/today-large-lower.png
/tmp/healthmanager-stage007d-visual-20260714/more-large.png
```

`accessibility-large`：

```text
/tmp/healthmanager-stage007d-visual-20260714/today-accessibility-large-top.png
/tmp/healthmanager-stage007d-visual-20260714/today-accessibility-large-middle.png
/tmp/healthmanager-stage007d-visual-20260714/today-accessibility-large-lower.png
/tmp/healthmanager-stage007d-visual-20260714/more-accessibility-large-top.png
/tmp/healthmanager-stage007d-visual-20260714/more-accessibility-large-lower.png
```

D1 纯展示 preview 实际渲染：

```text
/tmp/healthmanager-stage007d1-previews-20260714/loaded.jpg
/tmp/healthmanager-stage007d1-previews-20260714/empty.jpg
/tmp/healthmanager-stage007d1-previews-20260714/loading.jpg
/tmp/healthmanager-stage007d1-previews-20260714/failed.jpg
/tmp/healthmanager-stage007d1-previews-20260714/accessibility-large-top.jpg
/tmp/healthmanager-stage007d1-previews-20260714/accessibility-large-lower.jpg
```

accepted archival audit 的原始 runtime attachment：

```text
/tmp/healthmanager-stage007d-visual-audit-accepted-20260714/attachments/33017135-CC75-4584-B0AC-14DE270864EB.txt
SHA-256 ec3d204c8f0b93d8ebffc3c579d582b81f6e3679709658ceb6ddb4f6d54fa8dd

/tmp/healthmanager-stage007d-visual-audit-accepted-20260714/attachments/6D725C6A-582E-4ADD-8D8C-7B1996AA7BE9.png
SHA-256 2e7ba9ce9311179ccaa5c96ef19ddd2bc4cf52dbe3424c94bd9142fa25d24a3b
```

原始视觉对照、Dynamic Type 截图与 accepted accessibility tree 共同证明：

- 日期最终为“7月14日 星期二”，不再受 `en_CN` locale 语言漂移影响；
- 日汇总、真实时间线、来源 footer 与五栏层级清晰；
- `large` 和 `accessibility-large` 均可通过滚动到达完整内容，长文案换行且无固定高度裁切；
- tree 第 60 行把 taken 行读作“奥美拉唑，动作时间 08:12，已服用 20 mg”；第 74 行完整记录 fallback label“奥美拉唑，计划时间 20:00，已延后，动作时刻未记录”；全文不存在“动作时间 20:00”；
- 视觉对照轮次的来源 footer 读作 Apple Health / Watch / Apple Watch / 1 sample；accepted archival 轮次为维持冷启动聚合保存了 6 条同源 raw sample。两者都保持“当日原始样本覆盖”边界，不外推为单一字段来源；
- More 的七个既有能力入口完整，底栏和返回路径可用。

## 5. 自动化与最终判定

- locale 修正定向单测：12/12，`/tmp/healthmanager-stage007d-locale-fix-green-20260714-attempt02.xcresult`
- 最终定向合同：41/41，`/tmp/healthmanager-stage007d-final-targeted-20260714-attempt01.xcresult`
- 全量 unit：242/242，0 failed / 0 skipped，`/tmp/healthmanager-stage007d-final-unit-20260714-attempt01.xcresult`
- 全量 UI：6/6，0 failed / 0 skipped，`/tmp/healthmanager-stage007d-final-ui-20260714-attempt01.xcresult`
- 独立 build：0 error / 0 warning，`/tmp/healthmanager-stage007d-final-build-20260714-attempt01.xcresult`
- 常规验收 Simulator 的导航副作用 smoke：1/1，`/tmp/healthmanager-stage007d-side-effect-smoke-20260714-attempt01.xcresult`；测试后主库 migration v1…v5、integrity ok、FK 0，meal / item / medication plan / log / alert / raw sample 均为 0。
- accepted archival runtime audit：1/1，`/tmp/healthmanager-stage007d-visual-audit-accepted-20260714/runtime-audit.xcresult`；原始 tree/screenshot 已导出，截图后 fixture invariant `PASS`、migration v1…v5、integrity ok、FK 0、active sync job 0。
- 删除临时 audit test 并重新生成工程后的正式导航 smoke：1/1，`/tmp/healthmanager-stage007d-post-audit-production-smoke-20260714-attempt01.xcresult`。
- 原 P1 归档缺口的独立规格复核：PASS；复核完成后已 shutdown/delete accepted 与失败的 disposable audit Simulator，保留上述只读原始证据包。

最终结论：关键视觉层级、交互、证据边界、locale、Dynamic Type 与数据库隔离均满足 STAGE-007D，且此前的原始证据归档缺口已经由 accepted archival audit 闭环，Design QA 为 PASS。真机 VoiceOver、真实 HealthKit 与真实用户数据库仍由 STAGE-009 标记 INCOMPLETE，不从 Simulator 外推。

---

# STAGE-010A Design QA

> 验收日期：2026-07-16（Asia/Shanghai）
>
> 范围：Onboarding、Apple 健康不可用、Today loading / failure，以及本轮新增语义 token / 共享状态组件。

## 参考与同屏对照

参考图与同一 iPhone 17 视口的 runtime 截图已组合为同屏输入并逐张打开：

```text
/tmp/healthmanager-stage010a-acceptance-20260716/comparisons/onboarding-reference-vs-runtime.png
/tmp/healthmanager-stage010a-acceptance-20260716/comparisons/unavailable-reference-vs-runtime.png
/tmp/healthmanager-stage010a-acceptance-20260716/comparisons/today-loading-reference-vs-runtime.png
```

实现保留参考的编辑型中文排版、暖象牙底、功能性关系图、少量白色独立表面和一个明确主动作；没有复制参考中无法证明的设置深链、HealthManager 图片 Logo 或持续装饰动画。

## 运行态矩阵

- Simulator：`HealthManager-STAGE010A-QA-20260716` / `2E27DE90-4B5E-4956-88C4-B039843CCE8F`。
- 设备：iPhone 17 / iOS 26.5（23F77）/ portrait。
- 语言 / 区域：zh-Hans / zh_CN；状态栏固定 09:41。
- 四个表面各有 light-large、dark-large、light-accessibility-large，共 12 张；目录为 `/tmp/healthmanager-stage010a-acceptance-20260716/screenshots/`。

首轮发现 Health unavailable 在默认字号错误落入纵向连接图，使主动作离开首屏；主架构师改为只在 accessibility size 使用纵向结构，并修复状态与端点标签断行后重新生成三组截图。最终没有文字截断、控件重叠、不可达主动作或 dark mode 低对比度问题。

## 可访问性、动效与功能

- 关键动作最小高度 44 pt；状态均由图标 + 文字表达，颜色不是唯一信号。
- 文本使用 Dynamic Type 语义样式且无固定文本高度；accessibility-large 内容由 ScrollView 承载。
- loading 骨架全部对 VoiceOver 隐藏，页面仍暴露“正在读取本机证据”；源码没有 shimmer 或持续动画，因此 Reduce Motion 下无额外运动。
- failure 保留 `today-screen`、`today-load-error`、`today-retry`，技术信息可展开、选择和复制。
- 最终全量测试结果包为 `/tmp/healthmanager-stage010a-architect-final-20260716-attempt01.xcresult`：258 / 258 passed，0 failed，0 skipped。

## 判定

没有剩余 P0、P1 或 P2 设计问题。010A 只证明四个根状态，不外推五个一级 loaded 页面或真实 iPhone HealthKit。

result: passed

---

# STAGE-010G Design QA

> 验收日期：2026-07-16（Asia/Shanghai）
>
> 范围：全 App dark、accessibility-extra-large、Reduce Motion、永久主流程与跨页视觉回归。

## 运行矩阵与修复

- dark 高密度页最终 8 / 8，目录 `/tmp/healthmanager-stage010g-acceptance-20260716/dark/`；永久 Smoke 1 / 1，`/tmp/healthmanager-stage010g-dark-smoke-20260716-attempt01.xcresult`。
- accessibility-extra-large 高密度页最终 8 / 8，目录 `/tmp/healthmanager-stage010g-acceptance-20260716/accessibility-final/`；顶部、证据行与底部内容均经真实滚动到达。
- 系统 Reduce Motion=1 时永久 Smoke 1 / 1，`/tmp/healthmanager-stage010g-reduce-motion-smoke-20260716-attempt01.xcresult`；随后恢复为 0。
- 截图捕获的长状态标签夸张胶囊、trailing 时间挤压正文与可选卡片动画问题均以共享组件 / 环境值最小修复；默认字号视觉语言未重做。

## 自动化与结论

- 定向：30 / 30；`/tmp/healthmanager-stage010g-architect-targeted-20260716-attempt01.xcresult`。
- 全量：258 / 258；`/tmp/healthmanager-stage010g-architect-full-20260716-attempt01.xcresult`。
- `git diff --check`、`xcodegen generate`：PASS；临时视觉审计 test 已删除。

没有用异常列表隐藏可访问性问题，也没有修改业务合同。Simulator 结果不外推真机 VoiceOver、触觉或系统权限面板。

result: passed

---

# STAGE-010F Design QA

> 验收日期：2026-07-16（Asia/Shanghai）
>
> 范围：Dashboard 卡片编辑、剩余状态源码审计与永久 Smoke 回归。

## 参考、运行矩阵与交互

- `17` reference / runtime 同屏组合图已打开复核：`/tmp/healthmanager-stage010f-acceptance-20260716/comparisons/card-editor-reference-vs-runtime.png`。
- light / dark 各验证 default 与 hidden-change；accessibility-extra-large 最终验证 top / bottom 两张：`/tmp/healthmanager-stage010f-acceptance-20260716/`。
- 永久 Smoke 从真实 Trends 入口进入，执行恢复默认、隐藏活动、重新显示、再次恢复默认、完成返回；没有新增确认 / 保存步骤，结束后默认布局得到恢复。
- 参考图中的数量、排序和卡片名不是 fixture；runtime 的 6 / 4 与真实 `DashboardCardKind.defaults` / `allCases` 一致。

accessibility 首轮截图发现动态图标随字号过度放大并挤压文字；固定非文本图标视觉尺寸后，正文仍按 Dynamic Type 放大且上下内容可滚动到达。完整 accessibility Smoke 的测试滚动定位无法在隐藏后找到动态新增行，随后用收窄的 top / bottom 可达审计复验通过；没有 App crash、数据丢失或布局持久化失败。

## 自动化与结论

- 构建：`/tmp/healthmanager-stage010f-architect-build-20260716-attempt01`，BUILD SUCCEEDED。
- 定向：18 / 18；`/tmp/healthmanager-stage010f-architect-targeted-20260716-attempt01.xcresult`。
- 全量：258 / 258；`/tmp/healthmanager-stage010f-architect-full-20260716-attempt01.xcresult`。
- `git diff --check`：PASS；临时视觉 test 已删除并重新生成工程。

没有修改 `DashboardLayoutStore`、UserDefaults、排序 / 显示 / 隐藏 / 恢复语义或其他业务合同。Simulator 结果不外推真实用户的长期偏好升级或真机 VoiceOver 操作手感。

result: passed

---

# STAGE-010E Design QA

> 验收日期：2026-07-16（Asia/Shanghai）
>
> 范围：设置数据总账、AI 文本 / 照片双通道、兼容接口、Profile 与 Apple 健康权限证据。

## 组合对照与运行矩阵

- 设置、AI、添加接口、权限 4 张 reference / runtime 组合图均已逐张打开复核：`/tmp/healthmanager-stage010e-acceptance-20260716/comparisons/`。
- light 真实运行态 6 张：`/tmp/healthmanager-stage010e-acceptance-20260716/light/`。
- dark 核心页 4 张：`/tmp/healthmanager-stage010e-acceptance-20260716/dark/`。
- accessibility-extra-large 核心页 4 张：`/tmp/healthmanager-stage010e-acceptance-20260716/accessibility/`。

运行态使用当前未配置 AI 与本地实际样本状态，没有把参考图中的 provider、模型、Key、授权结果或样本数写成真实状态。权限页只呈现最近实际导入证据；无样本仍明确为读取授权未知。设置总账把默认本地、数据库快照、Keychain 与两个可选 AI 外发边界分开。

## 自动化与结论

- 构建：`/tmp/healthmanager-stage010e-architect-build-20260716-attempt03`，BUILD SUCCEEDED。
- 定向：77 / 77；`/tmp/healthmanager-stage010e-architect-targeted-20260716-attempt01.xcresult`。
- 全量：258 / 258；`/tmp/healthmanager-stage010e-architect-full-20260716-attempt01.xcresult`。
- `git diff --check`：PASS；临时视觉 test 已删除并重新生成工程。

真实 UI 流程发现 Profile sheet 挂在滚动 Section 上时不能稳定呈现；移动到页面根节点后同一路径复验通过。没有进行真实 AI 请求、输入真实 Key 或伪造 HealthKit 授权。Simulator 结果不外推真实 iPhone 逐类型授权、系统权限面板或 Keychain 跨安装行为。

result: passed

---

# STAGE-010D Design QA

> 验收日期：2026-07-16（Asia/Shanghai）
>
> 范围：指标 / 活动详情、数据质量、来源、同步、告警、总结、运动与补录活动。

## 组合对照与运行矩阵

- 九张 reference / runtime 同屏组合图均已逐张打开复核：`/tmp/healthmanager-stage010d-acceptance-20260716/comparisons/`。
- light 真实运行态 9 张：`/tmp/healthmanager-stage010d-acceptance-20260716/light/`。
- dark 核心页 6 / 6：`/tmp/healthmanager-stage010d-visual-dark-20260716-attempt01.xcresult`。
- accessibility-extra-large 核心页最终 6 / 6：`/tmp/healthmanager-stage010d-visual-accessibility-20260716-attempt05.xcresult`；组合主动作的多行省略由截图发现并修复。

真实状态通过正式补录、保存、对账和本地摘要生成路径产生；没有把参考图中的示例健康数据、设备来源或 AI 评注写入数据库。同步失败未在模拟器自然产生，因此没有伪造 failure fixture；失败 / soft skip / waiting 的分支仍保持既有状态机映射并由定向测试覆盖。

## 自动化与结论

- 构建：`/tmp/healthmanager-stage010d-architect-build-20260716-attempt03`，BUILD SUCCEEDED。
- 定向：73 / 73；`/tmp/healthmanager-stage010d-architect-targeted-20260716-attempt02.xcresult`。
- 全量：258 / 258；`/tmp/healthmanager-stage010d-architect-full-20260716-attempt01.xcresult`。
- `git diff --check`：PASS；临时视觉 test 已删除并重新生成工程。

没有剩余 P0、P1 或 P2 设计问题；Simulator 结果不外推真实 HealthKit 授权、外部 App 刷新或后台同步时序。

result: passed

---

# STAGE-010C Design QA

> 验收日期：2026-07-16（Asia/Shanghai）
>
> 范围：餐食编辑、最近餐复用、餐食分项证据、用药计划编辑。

## 参考与运行态对照

四张参考图与对应的 iPhone 17 runtime 截图已分别组合为同一张对照图并逐张打开复核：

```text
/tmp/healthmanager-stage010c-acceptance-20260716/comparisons/meal-editor-reference-vs-runtime.png
/tmp/healthmanager-stage010c-acceptance-20260716/comparisons/meal-reuse-reference-vs-runtime.png
/tmp/healthmanager-stage010c-acceptance-20260716/comparisons/meal-evidence-reference-vs-runtime.png
/tmp/healthmanager-stage010c-acceptance-20260716/comparisons/medication-editor-reference-vs-runtime.png
```

参考图中的食物照片、AI 结果、药名和营养数值没有写入验收数据库。对照判断的是已选视觉语言在真实状态中的层级、表面、动作、来源和事实边界，不把示例内容差异当成像素误差。运行态保留原生 `Form` / `List`，因此系统控件尺寸、日期 locale 和滚动行为服从真实 iOS 环境。

## 运行态矩阵

- Simulator：`HealthManager-STAGE010C-QA-20260716` / `4B5F15D0-0C49-4820-A6E1-DFC8AAC98417`。
- 设备：iPhone 17 / iOS 26.5（23F77）/ portrait；状态栏固定 09:41。
- 四个页面各有 light-large、dark-large、light-accessibility-large，共 12 张：

```text
/tmp/healthmanager-stage010c-acceptance-20260716/screenshots/
```

- dark-large：餐食证据、整餐复用与全页 Smoke 3 / 3；通知权限首次系统弹窗处理后，干净的用药编辑器 Smoke 再取证 1 / 1。
- accessibility-large：同三条真实 UI 流程 3 / 3；表单、复用动作、证据详情和星期控件均可滚动到达。
- 视觉结论：没有固定高度文本裁切、横向溢出、控件重叠或颜色唯一表达；深色关键正文与动作可辨识。accessibility-large 下证据头和复用动作自动纵排，星期选择使用适应列布局。

## 自动化与结论

- 定向：42 / 42；`/tmp/healthmanager-stage010c-architect-targeted-20260716-attempt05.xcresult`。
- 全量：258 / 258；`/tmp/healthmanager-stage010c-architect-final-20260716-attempt01.xcresult`。
- `git diff --check`：PASS。

两次真实 UI 回归分别发现保存错误离开懒加载树、非必要说明块挤压第二次添加菜品入口；都通过收窄 UI 修复并复验，没有删除或放宽测试。没有剩余 P0、P1 或 P2 设计问题。

result: passed

---

# STAGE-010B Design QA

> 验收日期：2026-07-16（Asia/Shanghai）
>
> 范围：Today、Diet、Medication、Trends、More 五个一级页面及共享 `HMDecisionLens`、`HMProvenanceRail`、`HMEmptyState`。

## 同屏对照与运行矩阵

五张 reference / runtime 同屏对照已逐张打开：

```text
/tmp/healthmanager-stage010b-acceptance-20260716/comparisons/
```

运行态目录包含 18 张：五页各自 light-large、dark-large、light-accessibility-large，加 Diet empty 三组：

```text
/tmp/healthmanager-stage010b-acceptance-20260716/screenshots/
```

最终修正包括：移除一级页重复大标题；压缩开发者式解释；让饮食主次动作在默认字号同排、无障碍字号自动纵排；把来源链在默认字号横排、accessibility size 纵排；为 dark mode 使用独立动态表面和可读主动作填充色。

## 功能与可访问性

- 五栏、sheet / push 目的地、Dashboard card route、More 八个 identifier 均保留。
- Diet 的新增、历史复用、编辑和原生侧滑删除可用；发现侧滑回归后，三个原失败 MealReuse 用例独立重跑 3 / 3 通过。
- Medication 的通知能力只说明提醒状态，不冒充服药动作；`taken / skipped / deferred` 仍来自日志。
- accessibility-large 下标题、说明、主次动作和来源链均换行或改为纵向；内容通过滚动可达，没有固定文本高度或水平裁切。
- 颜色均配合文字和 SF Symbol；dark mode 五页逐屏复核，未发现低对比度正文、丢失分隔或不可辨识动作。

## 自动化

最终结果包：

```text
/tmp/healthmanager-stage010b-architect-final-20260716-attempt02.xcresult
```

258 / 258 passed，0 failed，0 skipped；0 编译错误。现有 `MealItemMigrationTests` 可变变量 warning 与无 AppIntents 依赖时的 metadata 提示不属于本阶段视觉缺陷。

没有剩余 P0、P1 或 P2 设计问题。参考图中的示例数据未写入验收 Simulator；除 Diet empty 外，其余同屏对照只用于结构与视觉语言判断，不把空白 runtime 伪称为 loaded 像素匹配。

result: passed

---

# STAGE-010H Design QA

> 验收日期：2026-07-16（Asia/Shanghai）
>
> 范围：最终 Standards / Spec 双轴审查、关键修复运行态复验、临时 seam 清理与清理后全量回归。

## 最终设计审查

- 首轮审查发现的用药计划 / 动作时间混淆、首次加载与成功空白混淆、后台刷新覆盖旧内容、同步 phase 假成功、活动图表缺少选中值 / 来源 / VoiceOver 描述、文本与照片 AI 测试未分开等问题均已修复。
- 返工后 Standards 与 Spec 两个独立复审均无剩余 P0、P1 或 P2。
- 活动详情与 AI 设置最终运行态来自 `/tmp/healthmanager-stage010h-visual-audit-20260716-attempt07.xcresult`，1 / 1 passed；两张 attachment 均已人工打开，缺失事实有停止条件，照片模型测试动作与数据边界在真实滚动位置可见。
- 临时 `Stage010HAcceptanceAuditTests.swift` 已删除，工程重新生成；生产和测试代码中无 visual-audit route、fixture mode、screenshot mode 或仅为截图存在的 seam。

## 自动化与边界

- 正式构建：BUILD SUCCEEDED；`/tmp/healthmanager-stage010h-fix-build-20260716-attempt05`。
- 定向：87 / 87；`/tmp/healthmanager-stage010h-architect-targeted-20260716-attempt03.xcresult`。
- 清理后全量：258 / 258；`/tmp/healthmanager-stage010h-architect-full-20260716-attempt02.xcresult`。
- `git diff --check`、`xcodegen generate`、固定点解析和 `Core/` 零改动：PASS。

没有将 Simulator 外推为真实 iPhone VoiceOver、触觉、系统 HealthKit 权限面板或真实 AI 请求证据。本轮不 commit、不 tag、不 push、不发布。

result: passed
