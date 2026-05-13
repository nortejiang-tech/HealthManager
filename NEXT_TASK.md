# NEXT_TASK

> 下一轮（Round 3）开工前先读这份。读完即可恢复上下文。

## 上下文回放

Round 1：可编译工程 + HK 授权 + 12 表 schema + 30 天回补骨架。
Round 2：自动增量同步（F-001）落地 —— `IncrementalSyncCoordinator`、`HealthKitObserver`、`SyncEngine.runIncremental`、BGTask handler 真正打通。详见 `WORKLOG.md`。

当前状态：
- `SyncEngine.runBackfill` ✅
- `SyncEngine.runIncremental` ✅（observer / bgTask / timer 三入口）
- `SyncEngine.runManualSync` 仍是 stub
- `HealthKitObserver` 在 authorizationGate 进入 granted/partiallyGranted 时自动 start
- `BackgroundTaskScheduler.handleIncremental` 真正调 `runIncremental` 且 expirationHandler 会 cancel

## Round 3 目标：手动一键同步（PRD F-002，执行顺序 §12 第 4 项）

### 必须交付

1. **`Core/Sync/ManualSyncCoordinator.swift`（新文件）**
   - 状态机路径：`idle → syncingIncremental → waitingExternalSync → syncingIncremental2 → reconciling → completed/failed`
   - 流程：
     a. 第一次跑 `IncrementalSyncCoordinator.run(trigger: .user)` 拉一遍
     b. 通过回调要求 UI 弹「请去 Garmin / 米家 App 触发一次同步」（PRD §4.4）
     c. 等待 UI 触发 `userResumedFromExternal`（用户回到 App 或显式点击「已完成」）
     d. 再跑一次 `IncrementalSyncCoordinator.run(trigger: .user)` 拉外部 App 刚写入 HK 的部分
     e. 收尾 reconcile（Round 4 真做；这里走过即可）

2. **`SyncEngine.runManualSync`**
   - 替换 stub，串起 ManualSyncCoordinator
   - 暴露 `manualSyncPrompt: ManualSyncPrompt?` 让 UI 监听
   - `acknowledgeExternalSyncDone()` 让 UI 通知协调器继续

3. **`scenePhase` 自动续跑**
   - `HealthManagerApp` 监听 `@Environment(\.scenePhase)`
   - 进入 `.active` 且 `manualSyncPrompt != nil` 时自动 `acknowledgeExternalSyncDone()`
   - 用户其实只需打开 Garmin → 再回到 HealthManager 就完成全流程

4. **UI：`SyncCenterView` 一键同步按钮**
   - 按钮 → `runManualSync()`
   - 中段弹 sheet：「请打开 Garmin Connect / 米家 → 完成同步后回到本 App」
   - 「已完成」按钮 → `acknowledgeExternalSyncDone()`

### 验证清单
- `xcodebuild` Swift 阶段通过
- 真机：点一键同步 → 按提示去 Garmin → 回 App → 自动续跑 → dashboard 数据刷新
- `sync_jobs` 出现 `job_type=manual, trigger=user` 记录

### 不要做
- 不要在 Round 3 实现真正的 reconcile / 缺失告警（Round 4）
- 不要在 Round 3 引入 AI / 饮食识别（Round 5）
- 不要把外部 App 触发逻辑硬编码 Garmin/米家——UI 文案是说明，协调器只关心「用户说外部已完成」

### 已知约束
- HKObserver 已经会在外部 App 写入后自动触发增量；手动同步真正解决的是「用户怀疑漏数据 / iOS 后台被 kill」场景，所以两次拉取间夹用户操作是必要的。

## 额度策略提醒
- 进入 Round 3 前评估剩余额度
- 每 5 小时 / 每日结束 / 额度将尽前 checkpoint：`git commit` + 更新 WORKLOG / NEXT_TASK
