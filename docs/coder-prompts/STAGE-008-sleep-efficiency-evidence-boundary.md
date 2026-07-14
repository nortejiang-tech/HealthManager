# 给 Coder 的提示词：STAGE-008 睡眠效率证据边界

## 任务开始

只执行 HealthManager `STAGE-008`。不要继续 STAGE-007、重做产品设计、计算新的睡眠效率或读取记忆库。完整阅读：

- `docs/stages/STAGE-008-sleep-efficiency-evidence-boundary.md`
- `NEXT_TASK.md`
- `Core/Aggregate/DailyAggregator.swift`
- `Core/Database/Models/ActivityMetricsDaily.swift`
- `Core/Database/Models/HealthSampleRaw.swift`
- `UI/Dashboard/DashboardData.swift`
- `UI/Dashboard/Cards/SleepCard.swift`
- `UI/Dashboard/Detail/MetricDetailView.swift` 中 `MetricDetailConfig.sleep`
- `Tests/DailyAggregatorEnergyTests.swift`

先确认：

1. 分支是 `codex/health-planning-20260713`。
2. HEAD 是本阶段文档 checkpoint `9cd0973`，且 `git merge-base --is-ancestor b3107ef HEAD` 成功。
3. 工作区干净。

任一不成立就停止并报告，不要修复基线。

唯一目标：在真实 inBed/asleep 组合尚未审计前，彻底停止消费睡眠效率，并让日聚合主动把历史非空 `sleep_efficiency` 清回 NULL；保持现有 Asleep 时长语义和 UI 不变。

按 TDD 纵向切片执行：

1. 新增 `Tests/DailyAggregatorSleepTests.swift`，先写失败测试并保留 red 结果摘要。
2. fixture 在 in-memory DB 中预置一条非空 `sleep_efficiency` daily row，并写入 sleepAnalysis category 样本；运行 rebuild 后断言效率为 NULL、Asleep seconds 正确。
3. fixture 至少同时包含 inBed (`value=0`)、awake (`value=2`) 和一个 Asleep stage，证明只有 Asleep 进入现有时长。
4. 用 `DashboardLoader` 断言 rebuild 后小时数仍能读取。
5. 最小修改生产代码使测试 green：UPSERT 显式覆盖 `sleep_efficiency`；删除 `SleepCardData.lastNightEfficiency` 与 loader 对该列的 SELECT/赋值；更新 model 注释。

关键合同：

- 不实现效率计算；不以 0、100%、`—%` 或 sleep hours 代替未知效率。
- schema 和 migration 不变。INSERT 继续为 NULL，UPSERT 必须用 `sleep_efficiency = excluded.sleep_efficiency` 或等价显式 NULL 覆盖，使旧脏值被清除。
- 不改变 `sleepDuration` 的 dominant source、start-day、category 或求和逻辑；该算法的更深审计等待真实设备数据。
- `SleepCard` 和 `MetricDetailConfig.sleep` 不应修改：它们已经只展示 Asleep 时长。
- `DashboardLoader` 查询睡眠时只取 `sleep_seconds`；生产 UI/data payload 不再有 `lastNightEfficiency`。
- 不修改 HealthKit mapper/catalog、同步、来源优先级、dashboard 布局、导航、照片、饮食、用药或任何 STAGE-007 内容。

允许修改：

- `Core/Aggregate/DailyAggregator.swift`
- `Core/Database/Models/ActivityMetricsDaily.swift`
- `UI/Dashboard/DashboardData.swift`
- 新增 `Tests/DailyAggregatorSleepTests.swift`
- xcodegen 必要生成结果

禁止修改其他生产文件、schema/migration、docs。不要 commit、tag 或 push。若必须越界才能完成，停止并精确报告。

运行并简要报告：

    xcodegen generate
    xcodebuild -project HealthManager.xcodeproj -scheme HealthManager -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -resultBundlePath /tmp/healthmanager-stage008-coder-unit-20260714.xcresult -only-testing:HealthManagerTests/DailyAggregatorSleepTests -only-testing:HealthManagerTests/DailyAggregatorEnergyTests test -quiet
    xcodebuild -project HealthManager.xcodeproj -scheme HealthManager -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -resultBundlePath /tmp/healthmanager-stage008-coder-build-20260714.xcresult build -quiet
    git diff --check
    git status --short

任一测试或 build 失败时立即停止，不连续猜修，不扩大 helper 或产品范围。不要运行全量测试；由主架构师运行。

最终只列：候选状态、TDD red/green 证据、改动文件、定向测试/build 结果、静态边界检查、未验证真机边界、git status。

## 任务结束
