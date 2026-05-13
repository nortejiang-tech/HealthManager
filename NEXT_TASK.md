# NEXT_TASK

> 下一轮（Round 4）开工前先读这份。读完即可恢复上下文。

## 上下文回放

Round 1：工程骨架 + 12 表 schema + 30 天回补。
Round 2：自动增量同步 F-001（Anchored + Observer + BGTask 完整打通）。
Round 3：手动一键同步 F-002（两阶段 envelope + scenePhase 自动续跑）。详见 `WORKLOG.md`。

当前状态：
- `SyncEngine.runBackfill` ✅
- `SyncEngine.runIncremental` ✅
- `SyncEngine.runManualSync` ✅
- `IncrementalSyncCoordinator.executePass(progress:)` 是共享原语，Round 4 的 reconcile 不需要再写一遍拉取
- `data_quality_daily` 表已存在但全空
- `missing_data_alerts` 表已存在但全空
- `BackgroundTaskScheduler.handleReconcile` 是 stub（Round 1 留位）

## Round 4 目标：每日对账（PRD R-001，执行顺序 §12 第 5 项）

### 必须交付

1. **`Core/Sync/DailyReconciler.swift`（新文件）**
   - 输入：要对账的日期窗口（默认前 1 天 - 前 7 天）
   - 流程：
     a. 对每个日期：
        - 从 `health_samples_raw` 聚合：每个 hk_type 是否有非删除样本
        - 从 `source_coverage_daily` 读：该日有哪些 source 写入
     b. 计算 3 个分数（参考 PRD §6 / 自定义合理实现）：
        - `completeness_score`：核心指标（体重 / 步数 / 心率 / 睡眠）是否齐全，0..1
        - `freshness_score`：最近一次 ingested_at 距今多久；越久越低
        - `conflict_score`：同 hk_type 同小时窗口出现多个 source 的程度
     c. UPSERT `data_quality_daily(date, ...)`
     d. 任一指标低于阈值 → 写 `missing_data_alerts(date, metric, severity, message)`
        - 已存在同 (date, metric) 未确认告警则跳过
     e. 单条 `sync_jobs(job_type=reconcile)` envelope

2. **Round 4 不做 UI**
   - Dashboard 红点 / 告警面板留 Round 5
   - 但要确认数据写入正确：可以临时在 SyncCenter 加一个「跑一次对账」按钮（debug 用）

3. **打通 `BackgroundTaskScheduler.handleReconcile`**
   - 真正调 `DailyReconciler.run`，BGProcessingTask 节奏 ≥ 6h
   - expirationHandler 内 cancel 当前 Task（参照 Round 2 incremental 的写法）

4. **`SyncEngine.runReconcile`（新方法）**
   - 入口：BGProcessingTask + 调试按钮
   - 状态机：Reconcile 自己其实不属于 `SyncStateMachine` 的现有路径，可以走单独标志位 `isReconciling` 或新加状态。建议先用独立 `@Published var isReconciling`，不污染 phase。
   - 与 `runBackfill / runIncremental / runManualSync` 共享 `isBusy`？— 建议不共享：reconcile 是只读 + 写衍生表，与拉取互不冲突。给 reconcile 一个独立锁。

### 验证清单
- `swiftc -typecheck` 通过
- 真机：执行回补后跑一次对账 → `data_quality_daily` 有当日行 → 故意删除某类型样本 → 重跑对账 → `missing_data_alerts` 有对应记录

### 不要做
- 不要在 Round 4 做 dashboard 红点（Round 5）
- 不要在 Round 4 改 schema（12 张表已经留好位）
- 阈值不要固化魔数：用 `ReconcileConfig` 结构集中放，方便 Round 5 暴露给设置页

### 已知约束
- `freshness_score` 在 backfill 刚跑完时所有日期会显示高分；目标是周期性识别「停摆」而不是「冷启动」，所以判断窗口建议是「过去 7 天」而不是「过去 1 天」。
- iOS 17+ Scene 的 `onChange(of:)` 用零参形态（Round 3 已确认）。

## 额度策略提醒
- 进入 Round 4 前评估剩余额度
- 每 5 小时 / 每日结束 / 额度将尽前 checkpoint：`git commit` + 更新 WORKLOG / NEXT_TASK
- Round 3 验证步骤新增 `swiftc -typecheck` 独立路径，记得 Round 4 沿用
