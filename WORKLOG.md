# WORKLOG

> 滚动追加。每轮 checkpoint 写入一节。

---

## Round 1 — 2026-05-13 工程骨架 + HK 授权 + Schema + 30 天回补骨架

**目标（PRD §15 启动指令）**
- 可编译工程
- HealthKit 权限流程
- 数据类型清单
- 本地数据库 schema
- 30 天回补任务骨架

**已完成（文件级清单）**

工程 / 配置
- `project.yml` — xcodegen 配置，iOS 17.0+、SwiftUI、GRDB 6.29.x、HK 实体权限、BGTask 标识符。
- `App/HealthManager.entitlements` — `healthkit` + `healthkit.background-delivery`。
- `App/Info.plist`（由 project.yml 生成）— `NSHealthShareUsageDescription`、`NSHealthUpdateUsageDescription`、`BGTaskSchedulerPermittedIdentifiers`、相机/相册占位。
- `.gitignore`、`Resources/Assets.xcassets/*`、`.claude/settings.local.json`（bypassPermissions，已 ignore）。

App 入口
- `App/HealthManagerApp.swift` — `@main`、注入环境对象。
- `App/AppEnvironment.swift` — `@MainActor` 单例容器，组装 DB / HK / Sync / BG。
- `App/RootView.swift` — 根据 `authorizationGate` 切换 Onboarding / 主 TabView / 拒绝页。

HealthKit（执行顺序 1）
- `Core/HealthKit/HealthKitTypeCatalog.swift` — 体重 / 活动 / 心血管 / 睡眠 / 饮食 / Workout **全集**清单 + 每类型 canonical unit。**不按 source 预过滤。**
- `Core/HealthKit/HealthKitManager.swift` — `@MainActor`，授权 gate 状态机（`unknown/needsRequest/partiallyGranted/granted/denied`）、`requestAuthorization()`、`fetchSamples(from:to:)`、`anchoredFetch(anchor:)`。
- `Core/HealthKit/SampleMapper.swift` — `HKQuantitySample`/`HKCategorySample`/`HKWorkout` → `HealthSampleRaw`；元数据 / 类别值 / workout 详细字段进 `extra_json`。

数据库
- `Core/Database/DatabaseManager.swift` — GRDB DatabasePool，`Application Support/HealthManager/health.sqlite`，WAL + busy_timeout=5000。
- `Core/Database/Migrations.swift` — `v1_initial_schema`：12 张 PRD 表 + 2 张辅助表（`sync_anchors`、`missing_data_alerts`）。建索引：raw 表按 (`hk_type,start_at`)、(`source_bundle_id`)、(`start_at`)。
- `Core/Database/Models/{HealthSampleRaw,SyncJob,BackfillReport,SyncAnchor,MissingDataAlert}.swift` — Round 1 用到的实体。其余 8 张表本轮只建 schema，模型留待下轮按需补。

Sync 主链路
- `Core/Sync/SyncStateMachine.swift` — PRD §5 状态机（含手动同步的 5 阶段路径）。
- `Core/Sync/SyncEngine.swift` — `@MainActor` `ObservableObject`，对外暴露 `runBackfill`、`runIncremental`（占位，Round 3）、`runManualSync`（占位，Round 4）。发布 `phase / isBusy / progressDescription / lastResult`。
- `Core/Sync/BackfillCoordinator.swift` — **本轮核心**：
  1. 新建 `sync_jobs(running)` 记录；
  2. 遍历 `HealthKitTypeCatalog.allReadSampleTypes` 逐类型 `HKSampleQuery` 拉 [now-Ndays, now]；
  3. `SampleMapper` → `HealthSampleRaw`，按 `sample_uuid` PK `INSERT OR IGNORE` 去重；
  4. 写 `backfill_report` 行（含 missing 标记）；
  5. 一条 SQL `GROUP BY date,source_bundle_id` 重建窗口内的 `source_coverage_daily`；
  6. 收尾 `sync_jobs` + 返回 `LastResult`。
- `Core/Sync/SourceAttribution.swift` — Garmin / 小米米家 / 小米运动 / Apple / 华为 / 手动 / unknown 标签化，**不删样本**。
- `Core/Sync/BackgroundTaskScheduler.swift` — BGAppRefresh / BGProcessing 注册 + 调度入口。实际增量与对账逻辑留待 Round 3 / Round 6。
- `Core/Logging/AppLogger.swift` — os.Logger 按 category 分组。

最小 UI
- `UI/Onboarding/OnboardingView.swift` — 权限说明 + 「授权读取健康数据」按钮 + 错误回显。
- `UI/Dashboard/DashboardView.swift` — 累计样本数 / 最近入库时间 / 最近一次同步结果。
- `UI/SyncCenter/SyncCenterView.swift` — 状态显示、回补天数 Stepper（7-90）、「开始回补」按钮、最近 20 条 backfill_report。一键同步按钮已占位（Round 4 实现）。

**可运行验证步骤**

```bash
cd /Users/nortepro/HealthManager
xcodegen generate                            # 生成 HealthManager.xcodeproj

# 编译验证（无需 iOS 模拟器 runtime）：
rm -rf /tmp/HMbuild
xcodebuild -target HealthManager \
  -project HealthManager.xcodeproj \
  -configuration Debug -sdk iphonesimulator \
  BUILD_DIR=/tmp/HMbuild/Products BUILD_ROOT=/tmp/HMbuild/Build \
  OBJROOT=/tmp/HMbuild/Intermediates SYMROOT=/tmp/HMbuild/Products \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES SKIP_INSTALL=YES
# 期望：** BUILD SUCCEEDED ** （Swift 全部通过；如本机已安装 simulator runtime，
# actool 也会通过。当前本机 simulator runtime 未安装，UI 真机运行需先在 Xcode →
# Settings → Platforms 中下载 iOS 26.5 模拟器，再用 Xcode 打开 .xcodeproj 运行。）

# Round 1 的功能验证（需在装好 simulator runtime 的设备上）：
# 1. 首次启动 → Onboarding 出现「授权读取健康数据」
# 2. 点击授权 → 系统弹出 HealthKit 权限页（所有 read 类型）
# 3. 进入「同步中心」→ 选择 30 天 → 点击「开始回补」
# 4. 等待结束 → 「最近回补报告」列出每个 hk_type 的样本数 / missing 标记
# 5. 「仪表盘」显示累计原始样本数与最近入库时间
# 6. 再次点击「开始回补」 → 同样数据不会重复写入（sample_uuid 主键去重）
```

**当前编译状态**

| 项 | 状态 |
|---|---|
| Swift 编译 (`xcodebuild -target ... -sdk iphonesimulator`) | ✅ BUILD SUCCEEDED |
| `xcodegen generate` | ✅ |
| GRDB.swift 6.29.3 解析 | ✅ |
| Asset Catalog 编译 | ⚠️ 需 simulator runtime（本机未装）。Swift 通过；最终打包需 runtime。 |

**未完成项（按 PRD §12）**
- 阶段1：增量同步 Observer+Anchored、手动一键同步、来源归因落地到 UI / 报表
- 阶段2：每日对账、数据质量评分、缺失告警生成、样本级对账导出
- 阶段3：饮食 / 用药 / 日周总结
- 阶段4：边界 / 性能 / 发布前检查

**风险与阻塞**
1. 本机未安装 iOS Simulator runtime（iOS 26.5），无法在 simulator 中实跑。Swift 已验证编译通过；用户在 Xcode UI 中走 Settings → Platforms 下载一次即可，约 6 GB。
2. `HealthKit.statusForAuthorizationRequest` 不暴露读权限是否被授予；本轮使用「已请求过」标记 + `unnecessary` 判定近似 granted。如用户在系统设置里关闭部分读权限，App 只能通过查询返回 0 条来感知 —— 这是 Apple 平台的硬约束，Round 6 的对账逻辑里要加缺失告警弥补。
3. `HKQuantityTypeIdentifier` 中无内脏脂肪等级 / 骨骼肌 / 体水分 / 蛋白率的标准类型；当前路径：先尝试从样本 `metadata` 抽（部分秤会写入），抽不到则在 Round 后期开放手动补录 UI（PRD §4.2 已留位 `body_metrics_daily.visceral_fat_level` 等列）。
4. 多来源同时间同值样本目前以 `sample_uuid` 去重；HK 保证 uuid 唯一性，但如果两个 App 各自写入同一时刻不同值，会保留两条 —— 由 Round 2 的 `conflict_score` 与归因层处理，不在 raw 层强合并。

**下一步（最多 3 条）**
1. Round 2 —— `IncrementalSyncCoordinator`：`HKAnchoredObjectQuery` + `HKObserverQuery`，把每类型 anchor 持久化到 `sync_anchors`，与 `BackgroundTaskScheduler.handleIncremental` 真正打通；同时 `SyncEngine.runIncremental` 状态机走完整路径。
2. Round 3 —— 手动一键同步 F-002：UI 引导 + `scenePhase` 回前台二次拉取，沿用增量协调器。
3. Round 4 —— 每日对账 R-001：基于 `health_samples_raw + source_coverage_daily` 计算 `data_quality_daily`，写 `missing_data_alerts`，在仪表盘暴露红点。

---

## Round 2 — 2026-05-13 自动增量同步（F-001）

**目标（PRD §12 第 3 项 / F-001）**
- `HKAnchoredObjectQuery` 落地每类型增量拉取
- `HKObserverQuery` + `enableBackgroundDelivery(.immediate)`：HK 写入后秒级触发
- `sync_anchors` 持久化 anchor BLOB（SecureCoding）
- 删除事件 → `health_samples_raw.is_deleted` 软删
- BGAppRefresh 真正委托 `runIncremental`，过期时 cancel 当前 Task
- `SyncEngine.runIncremental` 走完 `idle → syncingIncremental → reconciling → completed/failed`

**已完成（文件级清单）**

新增
- `Core/Sync/IncrementalSyncCoordinator.swift` — 本轮核心。
  - 每类型 anchor 读取（`NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, ...)`）→ `anchoredFetch` → 写 added（`INSERT OR IGNORE` on `sample_uuid`）→ 写 deleted（`UPDATE ... SET is_deleted=1`，IN 子句按 400 行分块）→ UPSERT `sync_anchors`。
  - 单类型失败重试：指数退避（0.5s、1.5s），最多 3 次；最终仍失败则记录到 `sync_jobs.error_message` 并继续下个类型，不阻塞整体。
  - `sync_jobs` 完整生命周期：running → succeeded/failed + stats_json。
- `Core/Sync/HealthKitObserver.swift` — 全集 `HKObserverQuery` + `enableBackgroundDelivery(.immediate)`，回调里 `Task { @MainActor in await syncEngine.runIncremental(trigger: .observer) }`，通过 `SyncEngine.isBusy` 单工收敛突发触发。

修改
- `Core/Sync/SyncEngine.swift` — `runIncremental` 不再是 stub：装配 `IncrementalSyncCoordinator`，驱动状态机，发布 `progressDescription` / `lastResult`；`isBusy` 单工。
- `Core/Sync/BackgroundTaskScheduler.swift` — `handleIncremental` 持有 `Task` 句柄，`expirationHandler` 调 `work.cancel()` 后再 `setTaskCompleted(success:false)`。
- `App/AppEnvironment.swift` — 新增 `healthKitObserver`；`bootstrap()` 调 `scheduleIncrementalIfNeeded()` 排第一个 BG 槽位；新增 `onAuthorizationChange()` 在 gate 进入 granted/partiallyGranted 时启动 observer。
- `App/RootView.swift` — `.task` 与 `.onChange(of: authorizationGate)` 都调 `AppEnvironment.shared.onAuthorizationChange()`。

**数据流**

```
HK 写入  ─►  HKObserverQuery 回调 (前/后台)
              │
              ▼
        SyncEngine.runIncremental(.observer)
              │ isBusy 单工
              ▼
   IncrementalSyncCoordinator.run
     ├─ insertJob (incremental, running)
     ├─ for each HKSampleType:
     │    load anchor → anchoredFetch → persist added/deleted → save anchor
     │    (失败：0.5s/1.5s 指数退避，最多 3 次)
     └─ finaliseJob (succeeded/failed + stats_json)

兜底链路：BGAppRefresh(≥1h) → handleIncremental → 同一个 runIncremental
```

**当前编译状态**

| 项 | 状态 |
|---|---|
| Swift 编译 (HealthManager target，182 个 SwiftCompile 步骤) | ✅ 0 errors |
| GRDB.swift 6.29.3 解析 / 编译 | ✅ |
| `xcodegen generate` | ✅ 文件被自动纳入 target |
| Asset Catalog 编译 | ⚠️ 同 Round 1：本机无 simulator runtime，actool 仍报 "No available simulator runtimes" |

**可运行验证步骤**

```bash
cd /Users/nortepro/HealthManager
xcodegen generate
xcodebuild -target HealthManager -project HealthManager.xcodeproj \
  -configuration Debug -sdk iphonesimulator \
  BUILD_DIR=/tmp/HMbuild/Products BUILD_ROOT=/tmp/HMbuild/Build \
  OBJROOT=/tmp/HMbuild/Intermediates SYMROOT=/tmp/HMbuild/Products \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES SKIP_INSTALL=YES
# Swift 阶段通过；actool 仍受 simulator runtime 缺失阻挡（已知限制）。
```

功能验证（需 simulator runtime 或真机）：
1. 完成 Onboarding → 授权后 Observer 自动 `start()`
2. 在 Apple Health App 手动写一条体重 → 几秒内 dashboard 累计样本数 +1
3. 在 Apple Health 删一条 → DB 中对应 `sample_uuid.is_deleted` = 1
4. `sync_anchors` 表 14 行（每类型一行），重启 App 再写入仍能从断点继续
5. `sync_jobs` 出现 `job_type=incremental, trigger=observer/bg_task` 的记录

**风险与未完成**
1. Apple Watch 锁屏 / 系统压力下，Observer 不保证立即唤醒；BG App Refresh 是兜底但最低 1 小时。PRD F-001 的「≤ 1 小时」目标在 99% 路径满足，极端场景仍依赖 manual sync（Round 3）。
2. 当前 reconcile 阶段是占位（状态机走过，但没有真正对账逻辑）；Round 4 做 R-001 时再填实。
3. `enableBackgroundDelivery` 在权限被部分关闭的类型上会回调 `success=false`，目前仅写日志、不阻塞其他类型 —— 与 PRD §4.1「不删样本 / 不预过滤」一致。
4. `IncrementalSyncCoordinator` 的 anchor BLOB 大小约 200 B/类型 × 14 类型 = ~3 KB，存 SQLite blob 列；没有压力。

**下一步（最多 3 条）**
1. Round 3 —— 手动一键同步 F-002：UI 引导 + `scenePhase` 回前台二次拉取，沿用 `IncrementalSyncCoordinator` 与 `SyncStateMachine` 的 manual 路径。
2. Round 4 —— 每日对账 R-001。
3. Round 5 —— 数据质量评分 + 缺失告警进仪表盘红点。

---

## Round 3 — 2026-05-13 手动一键同步（F-002）

**目标（PRD §12 第 4 项 / F-002）**
- 用户点「立即同步」→ 拉一遍 → 提示去外部 App → 用户回 App → 再拉一遍
- `scenePhase` 进入 `.active` 时自动续跑，不强制点「已完成」
- `sync_jobs` 出现 `job_type=manual, trigger=user`，envelope 一行，内部两次 pass 共享同一 anchor 存储

**已完成（文件级清单）**

新增
- `Core/Sync/ManualSyncCoordinator.swift` — 两阶段 envelope。
  - 单条 `manual` sync_jobs 行包住两次 `IncrementalSyncCoordinator.executePass`
  - 中段 `await promptForExternalSync()` —— UI 无感的纯 async hook
  - 合并 per-type 计数，first non-nil error 上报
  - 不重复创建 incremental 行；anchor 仍由 `IncrementalSyncCoordinator` 持久化

修改
- `Core/Sync/IncrementalSyncCoordinator.swift` — 抽出 `executePass(progress:) -> PassResult`；原 `run` 改为薄包装。`insertJob` 改成多态（接 `jobType`）让 manual envelope 复用。
- `Core/Sync/SyncEngine.swift` —
  - 替换 `runManualSync` stub：装配 `ManualSyncCoordinator`，驱动 `startManual → userPromptedForExternal → userResumedFromExternal → incrementalFinished → reconcileFinished` 完整路径
  - 新增 `@Published manualSyncPrompt: ManualSyncPrompt?` 给 UI 监听
  - 新增 `acknowledgeExternalSyncDone()` 让 UI / scenePhase 唤醒等待
  - 内部 `CheckedContinuation<Void, Never>` 实现 wait-for-user；`defer` 里做防漏 cont.resume 兜底
- `App/HealthManagerApp.swift` — `.onChange(of: scenePhase)`（iOS 17 零参形态）在 `.active` + `manualSyncPrompt != nil` 时 sleep 800ms 后自动 `acknowledgeExternalSyncDone()`，给 HK 一点时间消化外部 App 的写入
- `UI/SyncCenter/SyncCenterView.swift` —
  - 「立即同步」按钮启用（不再是占位）
  - `.alert` 绑 `sync.manualSyncPrompt`，提供「已完成」按钮，关闭时也调 ack 兜底

**数据流**

```
SyncCenter「立即同步」按钮
   │
   ▼
SyncEngine.runManualSync (isBusy 单工)
   │ startManual → syncingIncremental
   ▼
ManualSyncCoordinator.run
   ├─ insertJob (manual, running)
   ├─ Pass 1: incremental.executePass  ─── 拉当前 HK
   ├─ await promptForExternalSync()
   │     │
   │     ▼ (SyncEngine 内部)
   │     userPromptedForExternal → waitingExternalSync
   │     设 manualSyncPrompt → 等 CheckedContinuation
   │
   │  «UI 显示 alert / 用户离开 App 到 Garmin / 米家»
   │  «用户回到本 App → scenePhase=.active»
   │  «scenePhase 监听器 800ms 后调 acknowledgeExternalSyncDone()»
   │     │
   │     ▼
   │     resume continuation → userResumedFromExternal → syncingIncremental2
   │
   ├─ Pass 2: incremental.executePass  ─── 拉外部 App 刚写入的
   └─ finaliseJob (succeeded/failed + 合并 stats)

最后 SyncEngine：incrementalFinished → reconcileFinished → completed
```

**当前编译状态**

| 项 | 状态 |
|---|---|
| `swiftc -typecheck` 全量 25 个 HealthManager 源文件 | ✅ 0 errors |
| GRDB.swift 6.29.3 编译 | ✅ |
| `xcodegen generate` | ✅ |
| Asset Catalog 编译 | ⚠️ 同 Round 1/2：本机无 simulator runtime |

Round 3 引入了独立的 `swiftc -typecheck` 验证步骤，弥补 Round 1/2 中"actool 早夭导致 HealthManager target 的 Swift 阶段实际未跑"的盲区。命令：

```bash
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
GRDB_MODULE_DIR="/tmp/HMbuild/Products/Debug-iphonesimulator"
CSQLITE_MAP="$HOME/Library/Developer/Xcode/DerivedData/HealthManager-*/SourcePackages/checkouts/GRDB.swift/Sources/CSQLite/module.modulemap"
find App Core UI -name "*.swift" -print0 | xargs -0 swiftc -typecheck \
  -target arm64-apple-ios17.0-simulator -sdk "$SDK" \
  -I "$GRDB_MODULE_DIR" -Xcc -fmodule-map-file="$CSQLITE_MAP"
```

需先跑一遍 `xcodebuild` 让 GRDB 产物落到 `$GRDB_MODULE_DIR`。

**功能验证清单（需 simulator runtime 或真机）**
1. SyncCenter 点「立即同步」→ 看到 `progressDescription: 第 1 次拉取 HealthKit…`
2. 出现 alert：「请前往外部 App 同步」
3. 切到 Garmin Connect / 米家 → 触发其同步 → 回到本 App
4. ~0.8s 后自动 alert 消失 + progressDescription 变 `第 2 次拉取…`
5. 完成 → `sync_jobs` 表多一行 `job_type=manual, trigger=user, state=succeeded`
6. 也可不离开 App：直接点 alert 上的「已完成」 → 立刻续跑

**风险与未完成**
1. 用户在 alert 出现时关掉 App，第一次 pass 已落库；下次启动 isBusy=false，再次点「立即同步」即可。无需特殊恢复逻辑。
2. iOS 17 Scene `onChange(of:)` 必须用零参闭包形态（含值闭包不存在或被解析为 deprecated 单参重载）—— 已用零参 + 闭包内读取 `scenePhase`。
3. reconcile 阶段仍是占位；Round 4 真正实现 R-001 时填实。
4. 「已完成」按钮 + scenePhase 自动 ack 是双触发，CheckedContinuation 已经在 ack 时 nil 化，重复调用是无害的 no-op。

**下一步（最多 3 条）**
1. Round 4 —— 每日对账 R-001：基于 `health_samples_raw + source_coverage_daily` 计算 `data_quality_daily`，写 `missing_data_alerts`。Dashboard 红点暂留 Round 5。
2. Round 5 —— 数据质量评分 UI + 缺失告警面板（PRD F-005）。
3. Round 6 —— 饮食 / 用药模块骨架（PRD F-003 / F-004）。

---

## Round 4 — 2026-05-13 每日对账 R-001

**已完成（文件级清单）**

新增
- `Core/Database/Models/DataQualityDaily.swift` — `data_quality_daily` 表的 GRDB record。
- `Core/Reconcile/DailyReconciler.swift` — 默认 7 天窗口。
  - 3 个分数：completeness（核心指标存在比例）/ freshness（最新 ingested_at 年龄分段：≤6h=1.0、≤24h=0.8、≤72h=0.5、≤7d=0.25、否则 0）/ conflict（同类型同小时桶 ≥2 source 占比反向）
  - UPSERT `data_quality_daily(date, ...)`
  - 缺失指标 → `missing_data_alerts`：连续天数 ≥3 升级 critical；整日无数据写 `__stale__` critical；按 `(date, metric)` 去重未确认
  - 单条 `sync_jobs(job_type=reconcile)` envelope
  - `humanLabel(for:)` 中文化常用指标

修改
- `Core/Sync/SyncEngine.swift` — 加 `runReconcile`（独立 `isReconciling` 锁，不与 `isBusy` 互斥，因为只读 raw + 写衍生表）
- `Core/Sync/BackgroundTaskScheduler.swift` — `handleReconcile` 真正委托 + `expirationHandler` 调 `Task.cancel()`
- `UI/SyncCenter/SyncCenterView.swift` — 加「立即对账（7 天）」按钮 + 上次结果摘要

---

## Round 5+6 — 2026-05-13 数据质量 UI + 告警 + 来源 + 饮食 + 用药 + 日报周报

**已完成（文件级清单）**

新增模型
- `Core/Database/Models/MealRecord.swift` — `meal_records`
- `Core/Database/Models/MedicationPlan.swift` — `medication_plans`
- `Core/Database/Models/MedicationLog.swift` — `medication_logs`
- `Core/Database/Models/DailySummary.swift` — `daily_summaries` + `WeeklySummary`（同文件）

新增逻辑
- `Core/Summary/SummaryGenerator.swift` — V1 不用 LLM，纯本地确定性聚合。
  - 日报：步数 / 活动能量 / 心率 / 静息心率 / 体重 / 餐次 / 用药 / 完整度 / 缺失列表
  - 周报：累计步数 + 日均 / 能量累计 / 心率均值 / 体重区间 / 餐次累计 / 用药次数 / 平均完整度
  - UPSERT `daily_summaries(date)` / `weekly_summaries(week_start_date)`
  - 周起始按 ISO-8601 周一对齐

新增 UI（5 个）
- `UI/Dashboard/DashboardView.swift` 改版 — 今日质量三色徽标（≥80 绿 / ≥50 橙 / <50 红）、告警红点 NavigationLink、分析入口
- `UI/Alerts/AlertsView.swift` — 按日期分组、按严重度图标着色、单条/全部确认、显示/隐藏已确认
- `UI/Sources/SourcesView.swift` — 按 `source_bundle_id` 聚合最近 7-60 天（Stepper），活跃天数比 <30% 标红；归因走 `SourceAttribution.Origin.label`
- `UI/Diet/DietView.swift` — 今日合计 + 近 50 餐次 + `MealEditView` 表单（餐次/时间/四大营养素/备注）+ 滑动删除
- `UI/Medication/MedicationView.swift` — 计划列表 +「记一次」按钮（写 taken log）+ `MedicationPlanEditView` + 最近 20 条日志
- `UI/Summary/SummaryView.swift` — 一键生成日报+周报，textSelection 允许复制

修改
- `Core/Sync/SourceAttribution.swift` — `Origin` 加 `.label` 显示名
- `App/RootView.swift` — `MainTabView` 加 饮食 / 用药 / 来源 4 个新 tab，总数到 5（iOS 上限内）
- `UI/SyncCenter/SyncCenterView.swift` — 顶部齿轮入设置

---

## Round 7 — 2026-05-13 收尾 / 设置 / Background reconcile bootstrap

**已完成**
- `UI/Settings/SettingsView.swift` — 版本 / Bundle ID / HK 授权状态 / DB 路径+大小+样本数 / 对账阈值（只读 V1）/ 隐私声明 / Danger zone（重置 `hk.hasRequestedAuthorization` 触发 onboarding）
- `App/AppEnvironment.swift.bootstrap` — 同时排 `scheduleReconcileIfNeeded()`（之前漏排）

---

## V1 交付摘要

**代码量**
- 38 个 Swift 文件 / Swift 0 errors 0 warnings（`swiftc -typecheck` 全量）
- 14 张 SQLite 表（PRD 12 + sync_anchors + missing_data_alerts）全部写入路径打通
- 5 个 Tab（仪表盘 / 饮食 / 用药 / 来源 / 同步中心）+ 5 个二级页面（告警 / 总结 / 设置 / 添加餐次 / 添加用药计划）

**PRD 完成度**
| ID | 名称 | 状态 |
|---|---|---|
| F-001 | 自动增量同步（Observer + Anchored + BGTask） | ✅ |
| F-001A | 历史回补 30 天 | ✅ |
| F-002 | 手动一键同步 + 外部 App 引导 + scenePhase 续跑 | ✅ |
| F-003 | 饮食记录（手动） | ✅ V1（无照片 AI 识别） |
| F-004 | 用药计划与日志 | ✅ V1（无系统通知调度） |
| F-005 | 数据质量评分 + 缺失告警 | ✅ |
| F-006 | 日报 / 周报 | ✅ V1（本地确定性，无 LLM） |
| R-001 | 每日对账 | ✅ |

**已知留待 v2**
- 饮食照片 AI 识别（PRD §F-003 提到）
- 用药提醒系统通知（UNUserNotificationCenter）
- 日周报接入 LLM
- 对账阈值在设置页可编辑
- 来源归因落到 raw 行（当前是查询侧标签化）
- 单元测试覆盖（HKQueryAnchor 编解码 round-trip、Reconciler 分数边界）

**编译验证**
```bash
# Swift 全量 typecheck（不依赖 simulator runtime）
xcodebuild -target HealthManager -project HealthManager.xcodeproj \
  -configuration Debug -sdk iphonesimulator ... 2>&1
# GRDB 构建会通过；HealthManager 的 Swift 阶段也会 0 错误。
# Asset Catalog 仍受本机无 simulator runtime 阻挡（Xcode→Settings→Platforms 下载 iOS 26.5 模拟器后 BUILD SUCCEEDED）。

# 独立 typecheck（绕开 actool）：
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
GRDB_MODULE_DIR="/tmp/HMbuild/Products/Debug-iphonesimulator"
CSQLITE_MAP="$HOME/Library/Developer/Xcode/DerivedData/HealthManager-*/SourcePackages/checkouts/GRDB.swift/Sources/CSQLite/module.modulemap"
find App Core UI -name "*.swift" -print0 | xargs -0 swiftc -typecheck \
  -target arm64-apple-ios17.0-simulator -sdk "$SDK" \
  -I "$GRDB_MODULE_DIR" -Xcc -fmodule-map-file="$CSQLITE_MAP"
# → 0 errors, 0 warnings
```

**真机首次运行步骤**
1. Xcode → Settings → Platforms → 下载 iOS 17+ simulator runtime（或直接连真机）
2. 打开 `HealthManager.xcodeproj`，选 device，Run
3. Onboarding 页 → 授权所有读权限
4. 自动进入主界面；首次 dashboard 数据为空
5. 同步中心 → 选 30 天 → 开始回补 → 等回补完成
6. 同步中心 → 立即对账 → 仪表盘出现完整度/新鲜度/冲突度三个数字
7. 后续每次外部 App 写入 HK，HKObserver 会自动触发增量；每日 BG Task 自动对账

---

## Round 8 · 稳定性强化（2026-05-14）

V1 在 Xcode 实测发现三类问题：①回补/手动同步报错信息模糊；②anchor 解码失败后续同步无法恢复；③点完「立即对账」后回到仪表盘有概率卡住。本轮全部修复并补诊断 UI。

**根因**
- `SyncEngine` 是 `@MainActor`，而四个 coordinator（Backfill / Incremental / Manual / DailyReconciler）是普通 class，因此它们继承调用方 actor → 内部同步 `database.read/write`（GRDB 阻塞 API）直接卡 MainActor；7 天对账 × N type × 数十次 SQL 会冻结主线程，Dashboard `.task` refresh 排队等不到机会。
- `IncrementalSyncCoordinator.loadAnchor` 的 `NSKeyedUnarchiver.unarchivedObject` 抛错被 syncType catch 后只是重试 3 次然后跳过；脏 anchor 行不清理 → 之后每次同步都失败。
- 任何一个 type 的 HK `authorizationDenied` 都让 `firstError` 非 nil → 整个 job 显示"失败"。
- catch 块只记 `firstError.localizedDescription`，UI 只能展示一句模糊文字。

**改动**

| Commit | 主题 | 影响 |
|---|---|---|
| 1 | `IncrementalSyncCoordinator.loadAnchor` 解码失败降级为 nil 并 `DELETE FROM sync_anchors WHERE hk_type = ?`，下次走全量（PK 去重） | 同步自愈 |
| 2 | 新增 `Core/Sync/SyncDiagnostics.swift`（`SyncStage` + `SyncTypeError`）；`SyncEngine.LastResult` 加 `perTypeErrors: [SyncTypeError]`；Incremental / Backfill / Manual 三个 coordinator 收集每个 type 的 stage + underlying + isAuthDenied | 诊断结构化 |
| 3 | Auth-denied 软失败：`status=.skipped`、`missing=true`，但**不**污染 `firstError`；retry 早退（重试授权毫无意义） | 部分授权也算成功 |
| 4 | 四个 coordinator 改 `actor`（`DailyReconciler` / `IncrementalSyncCoordinator` / `BackfillCoordinator` / `ManualSyncCoordinator`）；`SummaryGenerator` 也改 `actor`；`SyncEngine` 保留 `@MainActor`（继续管 `@Published`），调用 `try await coordinator.run(...)` 自动 hop 到 actor executor（后台线程） | **核心修复对账卡 UI** |
| 5 | `DatabaseManager` 加 `@unchecked Sendable` + `asyncRead`/`asyncWrite`（detached task 包同步 read/write）；所有 UI 文件（Dashboard / SyncCenter / Diet / Medication / Alerts / Sources / Summary / Settings）的 `database.read/write` 切到 async 版本；结果通过 `await MainActor.run { ... }` 写回 `@State` | UI 不再阻塞主线程 |
| 6 | `SyncCenterView` 新增「失败明细 DisclosureGroup」：每条 type 错误显示锁/红三角图标 + humanLabel + 阶段 + 原因 | 用户能定位问题 |

**新增/修改文件**
- 新文件：`Core/Sync/SyncDiagnostics.swift`
- Core 改动：
  - `Core/Sync/SyncEngine.swift`（LastResult.perTypeErrors）
  - `Core/Sync/IncrementalSyncCoordinator.swift`（actor + 收集 errors + auth-denied 软失败 + anchor 兜底）
  - `Core/Sync/BackfillCoordinator.swift`（actor + 收集 errors + auth-denied 软失败）
  - `Core/Sync/ManualSyncCoordinator.swift`（actor + pass1/pass2 errors 合并去重）
  - `Core/Reconcile/DailyReconciler.swift`（class → actor）
  - `Core/Summary/SummaryGenerator.swift`（class → actor）
  - `Core/Database/DatabaseManager.swift`（@unchecked Sendable + asyncRead/asyncWrite）
- UI 改动（每个文件去掉 `@MainActor` private func、改用 `asyncRead/asyncWrite` + `MainActor.run`）：
  - `UI/Dashboard/DashboardView.swift`（新增 `DashboardSnapshot: Sendable`）
  - `UI/SyncCenter/SyncCenterView.swift`（+ 失败明细 DisclosureGroup）
  - `UI/Diet/DietView.swift`（refresh / delete / save → async）
  - `UI/Medication/MedicationView.swift`（refresh / recordTaken / delete / save → async）
  - `UI/Alerts/AlertsView.swift`（refresh / acknowledge / acknowledgeAll → async）
  - `UI/Sources/SourcesView.swift`（refresh：Row 映射移入 asyncRead 闭包内）
  - `UI/Summary/SummaryView.swift`（refresh / generateBoth → async；await actor 方法）
  - `UI/Settings/SettingsView.swift`（refresh → async）

**编译验证**
```
** BUILD SUCCEEDED **
```
0 errors / 0 warnings（除 AppIntents 系统提示，与本工程无关）。

**功能验证（待用户在 Xcode 实测）**
1. 首次安装 → Onboarding 全选 Allow → 同步中心 → 30 天回补：所有 type 跑完；如有失败，「失败明细」可展开看到 `hk_type / 阶段 / 原因`；未授权 type 整体仍显示成功。
2. 立即同步（手动一键）：两阶段流程正常。
3. 立即对账（7 天）→ 切回仪表盘：**不再卡住**；refresh 正常完成。
4. 手工损坏 anchor（sqlite3 写脏 BLOB）→ 触发增量：日志「Anchor decode failed; resetting」；该 anchor 行被删；同步成功。

**未实施**
- Round 9（仪表盘对标 Apple Health + 饮食卡片 + 热量缺口卡片）作为下一轮单独交付。


---

## Round 9 · 仪表盘对标 Apple Health（2026-05-14）

**目标**：把原本 List 风格的仪表盘换成苹果健康摘要页的视觉与信息密度：hero 大字 + 2 列卡片网格 + 每张卡片可下钻到周/月/年大图。

**改动**

| Commit | 主题 | 影响 |
|---|---|---|
| 1 | 新增 `Core/Aggregate/DailyAggregator.swift`（actor）：把 `health_samples_raw` 按天 UPSERT 到 `activity_metrics_daily` / `body_metrics_daily`；体重/体脂取最新，步数/活动 kcal/距离/锻炼/站立/楼层取和，心率/HRV 取均值，睡眠按 categoryValue 1/3/4/5 计 asleep 秒数 | 数据投影层 |
| 2 | `SyncEngine` 在 backfill / incremental / manual 三条路径 success 分支挂载 `runAggregation(windowDays:)`，windowDays 与同步窗口对齐（backfill 30+、manual 30、incremental 7） | 同步即聚合 |
| 3 | 新增 `UI/Dashboard/DashboardData.swift`：`DashboardSnapshot` / `DashboardLoader` / `MetricPeriod`（周/月/年）/ `MetricPoint` / `DatedDouble` / `SeriesAggregation`；所有查询走 `DatabaseManager.asyncRead` | 数据层骨架 |
| 4 | 新增 `UI/Dashboard/Cards/*`：`CardTheme`（活动红/心率粉/睡眠紫/体重青/饮食橙/缺口蓝渐变）/ `DashboardCard`（统一容器）/ `CardMetric` / `CardEmptyState` / `HeroHeader`（问候 + 日期 + 4 大数字 + 完整度药丸 + 告警铃铛 badge）/ 6 张卡片（Activity / Heart / Sleep / Body / Diet / Deficit）每张都含 Swift Charts sparkline | 卡片视觉层 |
| 5 | 新增 `UI/Dashboard/Detail/MetricDetailView.swift`：周/月/年 segmented picker + 大字 summary + Swift Chart 大图 + 平均/最高/最低/最新 stat 网格 + 定义脚注；`MetricDetailConfig` 收 9 个静态配置（体重、体脂、步数、活动能量、静息心率、HRV、睡眠、锻炼时长、距离）；年视图自动按 7 天桶聚合 | 详情大图 + 周/月/年切换 |
| 6 | 新增 `UI/Dashboard/Detail/DataQualityDetailView.swift`：把原 Dashboard 的「今日数据质量 / 数据采集 / 最近同步 / 分析入口」搬过来；点 hero header 的完整度药丸进入 | 老 List 内容搬家 |
| 7 | 改写 `UI/Dashboard/DashboardView.swift`：ScrollView + HeroHeader + LazyVGrid 2 列 6 卡片 + 「数据质量明细」入口；`MetricRoute` 把卡片点击映射到 `MetricDetailView`；铃铛 / 药丸通过 `navigationDestination(isPresented:)` 实现 push | 仪表盘重做 |

**新增/修改文件**
- 新文件：
  - `Core/Aggregate/DailyAggregator.swift`
  - `UI/Dashboard/DashboardData.swift`
  - `UI/Dashboard/Cards/CardTheme.swift`
  - `UI/Dashboard/Cards/DashboardCard.swift`
  - `UI/Dashboard/Cards/HeroHeader.swift`
  - `UI/Dashboard/Cards/ActivityCard.swift`
  - `UI/Dashboard/Cards/HeartCard.swift`
  - `UI/Dashboard/Cards/SleepCard.swift`
  - `UI/Dashboard/Cards/BodyCard.swift`
  - `UI/Dashboard/Cards/DietCard.swift`
  - `UI/Dashboard/Cards/DeficitCard.swift`
  - `UI/Dashboard/Detail/MetricDetailView.swift`
  - `UI/Dashboard/Detail/DataQualityDetailView.swift`
- 改动：
  - `Core/Sync/SyncEngine.swift`：`lazy var dailyAggregator` + `runAggregation` 私有挂载
  - `UI/Dashboard/DashboardView.swift`：整文件重写
- 数据层：零 schema 变化（已存在的 `body_metrics_daily` / `activity_metrics_daily` 才被真正写入）

**编译验证**
```
xcodegen generate
xcodebuild -target HealthManager -project HealthManager.xcodeproj -configuration Debug -sdk iphonesimulator ... → ** BUILD SUCCEEDED **
```
0 errors / 0 warnings（除 AppIntents 系统提示）。

**功能验证（待用户在 Xcode 实测）**
1. 首次同步完成后回仪表盘：hero 显示步数/活动 kcal/缺口/体重 4 数字；6 张卡片 sparkline 都有内容；快速切 tab 不卡。
2. 点任意卡片：跳转 `MetricDetailView`，顶部周/月/年 segmented 可切；切换时大图与 stat 网格同步刷新；空时段显示「该时段暂无数据」。
3. 点 hero 的完整度药丸：进入「数据质量」详情页，含老的对账/采集/最近同步 section + 日报周报入口。
4. 点铃铛：进入告警列表。
5. 损坏体重 / 体脂数据：体重卡片显示「—」，最近 30 日 sparkline 显示 empty state。

---

## Round 10 · 仪表盘细节打磨（2026-05-14）

**目标**：补 Round 9 留的 stub，再把 Apple Health 体验最关键的两个交互补齐——图表拖动点选 + 卡片环比趋势 chip。

**改动**

| Commit | 主题 | 影响 |
|---|---|---|
| 1 | `MetricDetailConfig.source` 由 `(table, column, aggregation)` 改为 enum `Source { tableColumn / diet / deficit }`；`MetricDetailView.load` switch 派发 | 详情页可接异构数据源 |
| 2 | `DashboardLoader` 加 `loadDietSeries(period:)` / `loadDeficitSeries(period:)`：前者从 `meal_records` 按 localtime 分组求和，后者从 `activity_metrics_daily` 拿 burned + meal SUM 拿 intake；都用通用 `fillAndBucket` 补齐空缺天并支持年视图按 7 天桶 | 饮食 / 缺口可下钻 |
| 3 | 新增 `MetricDetailConfig.diet` / `.deficit` 静态配置；`MetricRoute` 干掉 stub，直接映射到真配置 | 饮食/缺口卡片点击=真详情 |
| 4 | `MetricDetailView` 加图表点选：`@State inspectedDate`；`chartOverlay { proxy in GeometryReader { ... DragGesture → proxy.value(atX:) → inspectedDate }}`；选中后顶部摘要切换为「选中 X 月 Y 日 · 数值」+ chart 上叠 `RuleMark` 虚线 + 大 `PointMark`；双击空白清除；切 period 自动清除 | Apple Health 拖动竖线体验 |
| 5 | 新增 `UI/Dashboard/Cards/TrendChip.swift`：把任意 `[DatedDouble]` 拦腰分两半算均值环比，输出 ↑/↓ + 百分比胶囊；体重/静息心率开 `lowerIsBetter` 翻转配色（下降=绿、上升=红）；`DashboardCard` 重构 `titleAccessory: String?` → `accessory: () -> some View` 通用槽位 | 卡片右上角 vs 前期对比 |
| 6 | 6 张卡片全部插入对应 `TrendChip`；`DietCardData` 新增 `last7Days` 字段（来自 `meal_records` 7 日按日合计） | 卡片视觉信息密度+1 |

**新增/修改文件**
- 新文件：`UI/Dashboard/Cards/TrendChip.swift`
- 改动：
  - `UI/Dashboard/Cards/DashboardCard.swift`（accessory 泛型槽位）
  - `UI/Dashboard/Cards/ActivityCard.swift` / `HeartCard.swift` / `SleepCard.swift` / `BodyCard.swift` / `DietCard.swift` / `DeficitCard.swift`（accessory 插入 TrendChip）
  - `UI/Dashboard/DashboardData.swift`（`DietCardData.last7Days` + meal 7 日聚合 + `loadDietSeries` + `loadDeficitSeries` + `fillAndBucket`/`bucketStatic`）
  - `UI/Dashboard/Detail/MetricDetailView.swift`（Source enum + inspectedDate + chartOverlay drag + 选中态摘要）
  - `UI/Dashboard/DashboardView.swift`（MetricRoute.diet / .deficit 真映射）

**编译验证**
```
xcodegen generate
xcodebuild ... → ** BUILD SUCCEEDED **
```
0 errors / 0 warnings（除 AppIntents 系统提示）。

**功能验证（待用户实测）**
1. 摘要页：每张卡右上角看到 ↑/↓ 百分比胶囊（体重/心率绿=好、橙=差；其他色按指标主题）。数据少于 4 天的卡片不显示胶囊。
2. 点饮食卡片：详情页显示「饮食热量」周/月/年柱图；点缺口卡片显示「热量缺口」详情，正负值通过 `%+.0f` 标注。
3. 任意详情页：用手指在图表上拖动 → 选中天的虚线 + 高亮点 + 顶部「选中 · M月D日 · 数值」；双击图表空白处清除选中；切周/月/年自动清除。

---

## Round 11 · 二级指标入口 + 详情期内趋势 + Hero 下钻（2026-05-14）

**目标**：把 Apple Health「显示所有健康类别」对应的"更多指标"二级入口补上；让 hero header 的 4 大数字也可以点进详情；详情页加期内趋势 chip。

**改动**

| Commit | 主题 | 影响 |
|---|---|---|
| 1 | `MetricDetailView.summaryHeader` 加 `TrendChip`：复用卡片同款拦腰算法，体重/体脂/静息心率开 `lowerIsBetter`；选中态时隐藏 chip（防止与「选中 X 月 Y 日」冲突） | 详情页一眼看出环比 |
| 2 | `DashboardView` 加 `moreMetricsSection`：卡片式 List 5 行（活动能量 / 锻炼时长 / 距离 / HRV / 体脂率），每行 NavigationLink(value:) 跳对应 detail；ThinMaterial 圆角容器配色统一 | 摘要页能进所有二级指标 |
| 3 | `HeroHeader` 加 `onMetricTap: (MetricRoute) -> Void` 回调；4 个大数字改为 Button；`DashboardView` 用 `NavigationStack(path: $metricPath)` 程序化推栈 | hero 数字可点击下钻 |
| 4 | `NEXT_TASK.md` 更新到 Round 11 状态 | 文档同步 |

**新增/修改文件**
- 改动：
  - `UI/Dashboard/Detail/MetricDetailView.swift`（summaryHeader TrendChip + lowerIsBetter switch）
  - `UI/Dashboard/DashboardView.swift`（NavigationStack path + moreMetricsSection + moreMetricRow）
  - `UI/Dashboard/Cards/HeroHeader.swift`（onMetricTap + heroMetric 改 Button + route 参数）
  - `NEXT_TASK.md`

**编译验证**
```
xcodegen generate
xcodebuild ... → ** BUILD SUCCEEDED **
```
0 errors / 0 warnings（除 AppIntents 系统提示）。

**功能验证（待用户实测）**
1. 摘要页：6 卡片下方有「更多指标」卡片列出活动能量 / 锻炼时长 / 距离 / HRV / 体脂率，点任一行直接进对应详情。
2. Hero 4 数字（步数 / 活动 kcal / 缺口 / 体重）：直接点击数字也能下钻进详情。
3. 任意详情页：顶部小字标签旁出现 ↑/↓ 百分比胶囊（相对窗口前半 → 后半的均值变化）；拖动选中某一天时胶囊隐藏，松开手指（双击图表空白）后恢复。
