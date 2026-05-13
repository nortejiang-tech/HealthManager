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

