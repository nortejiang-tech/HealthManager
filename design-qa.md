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
