# NEXT_TASK

> 下一轮（Round 2）开工前先读这份。读完即可恢复上下文。

## 上下文回放

Round 1 已交付：可编译工程 + HealthKit 授权 + 12 表 schema + 30 天回补骨架。
详见 `WORKLOG.md` 的 Round 1 节。

当前状态：
- `SyncEngine.runBackfill` 已可用
- `SyncEngine.runIncremental` 是 stub（仅写日志）
- `SyncEngine.runManualSync` 是 stub
- `BackgroundTaskScheduler` 注册了 BGAppRefresh / BGProcessing，但 handler 内部委托 `runIncremental`，目前空跑

## Round 2 目标：自动增量同步（PRD F-001，执行顺序 §12 第 3 项）

### 必须交付
1. **`Core/Sync/IncrementalSyncCoordinator.swift`**
   - 输入：`SyncJob.Trigger`
   - 流程：
     a. 新建 `sync_jobs(job_type=incremental, state=running)`
     b. 遍历 `HealthKitTypeCatalog.allReadSampleTypes`
     c. 从 `sync_anchors` 读取该类型的 `HKQueryAnchor`（首次为 `nil`）
     d. `HealthKitManager.anchoredFetch(for:anchor:)` → `(added, deleted, newAnchor)`
     e. `SampleMapper.map(...)` → `INSERT OR IGNORE health_samples_raw`
     f. `deleted` 走 `UPDATE health_samples_raw SET is_deleted=1 WHERE sample_uuid IN (...)`
     g. 序列化 `newAnchor` (`NSKeyedArchiver.archivedData(withRootObject:requiringSecureCoding:true)`) → `sync_anchors UPSERT`
     h. 失败重试：指数退避，最多 3 次（PRD F-001）
     i. 收尾 `sync_jobs`

2. **`Core/Sync/HealthKitObserver.swift`**（新文件）
   - 为每个 `HKSampleType` 注册 `HKObserverQuery` + `enableBackgroundDelivery(for:frequency:.immediate)`
   - 观察到变化 → `Task { await SyncEngine.runIncremental(trigger: .observer) }`
   - App 启动后调用 `start()`；权限通过后再 enable backgroundDelivery

3. **打通 `BackgroundTaskScheduler.handleIncremental`**
   - 调用 `SyncEngine.runIncremental(trigger: .bgTask)`，确保 `task.setTaskCompleted` 时机正确（任务即将过期时调 `expirationHandler`，里面 cancel 当前 Task）

4. **`SyncEngine` 状态机**
   - 把 `runIncremental` 走完整路径：`idle → syncingIncremental → reconciling → completed/failed`
   - reconcile 本轮可以是占位（Round 4 才真正做对账）

### 验证清单
- `xcodebuild` 编译通过
- 单元测试（可选）：mock HKHealthStore，验证 anchor 编/解码 round-trip
- 真机/模拟器：首次 backfill 后再触发 `runIncremental`，确认 raw 表无重复增长

### 注意
- `HKQueryAnchor` 不是 Codable —— 用 `NSKeyedArchiver/NSKeyedUnarchiver` 走 secureCoding，存为 BLOB
- BG Task 注册必须在 app 启动早期（已在 `AppEnvironment.bootstrap` 里调），不要移动
- 增量同步触发频率：observer 是主要驱动；BGAppRefresh 是兜底，最低 1 小时

### 不要做
- 不要在 Round 2 实现对账 / 缺失告警（那是 Round 4）
- 不要预过滤 source（PRD §4.1 硬约束）
- 不要把 `IncrementalSyncCoordinator` 写得依赖 UI；它必须能在 BGTask handler 里独立跑完

## 额度策略提醒
- 进入 Round 2 前评估剩余额度
- 每 5 小时 / 每日结束 / 额度将尽前 checkpoint：`git commit` + 更新 WORKLOG / NEXT_TASK

