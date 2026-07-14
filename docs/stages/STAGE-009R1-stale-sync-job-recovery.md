# STAGE-009R1：跨进程遗留同步任务恢复

> 状态：PASS（主架构师接管；2026-07-15）

## 目标

在任何新同步、HealthKit observer、后台调度或聚合任务启动前，把上一次进程退出时遗留在 `pending` / `running` 的同步任务原子地收敛为可解释的 `failed` 终态，避免 Sync Center 永久显示伪运行状态，也避免真机后台恢复验收建立在错误数据库状态上。

## 已验证的触发证据

安装前从真实 `iPhone Air`（iOS 26.5.2）只读复制的 v0.2.5 (7) App 数据容器中：

- `sync_jobs` 共 1225 行：976 succeeded、230 failed、19 running。
- 19 条 running 均为 `incremental`；17 条由 observer 触发、2 条由 bg_task 触发。
- 最早遗留于 2026-06-10，最新遗留于 2026-07-14，均不可能仍是当前进程内的有效任务。
- 当前候选没有启动时恢复数据库终态的路径；`SyncStateMachine.reset` 只重置内存状态，不修复 `sync_jobs`。
- 快照路径：`/tmp/healthmanager-stage009-device-preinstall-snapshot-20260715-attempt01/`；数据库 `integrity_check=ok`、FK 违规 0、迁移为 v1～v4。

这项证据使 STAGE-009 的“后台 observer / 增量同步恢复”门在覆盖安装前就暴露出明确风险。按既定边界，跨进程恢复由主架构师接管，不交给低成本 Coder 试错。

## 设计约束

1. 不修改 v1～v5 migration，不新增 schema；这是进程启动恢复，不是数据迁移。
2. `AppEnvironment.bootstrap()` 必须先且仅一次注册所有 permitted BGTask handler，以满足 iOS 启动合同；两个注册结果必须都为成功，任一返回 false 时本进程保持全部同步关闭且不重试注册。注册本身不得开启同步。数据库恢复必须早于 BGTask 调度/执行、HealthKit observer、任何自动或手动同步以及聚合任务。
3. 同一数据库事务内：
   - 将所有既有 `sync_jobs.state IN ('pending', 'running')` 改为 `failed`；
   - `ended_at` 只在为空时写入本次启动时刻；
   - `error_code` 明确写为 `interrupted_before_completion`；
   - 空错误信息写入固定、可解释的中断说明，既有非空错误信息不覆盖；
   - 若存在关联且仍为 `running` 的 `backfill_report`，同步改为 `failed`，补齐结束时间和空错误信息。
4. 恢复返回实际修改计数，重复执行必须为 0/0，保证幂等。
5. handler 注册失败或恢复失败时不得开放 SyncEngine/scheduler；已注册 handler 在恢复未完成时必须以失败结束系统交付的任务，不得调度或执行自动同步，所有手动同步入口也必须由 `SyncEngine` 深层门禁拒绝。App 保持可启动并记录明确日志，下一次启动可重试完整启动链。
6. 终态任务、统计 JSON、已存在的结束时间和非空错误信息不得被改写。
7. 本阶段不碰 HealthKit 样本、anchors、餐食、照片、summary 或任何用户健康数据。

## 允许修改

- `Core/Sync/SyncJobRecovery.swift`（新增深模块）
- `Core/Sync/SyncEngine.swift`（统一启动门禁）
- `Core/Sync/BackgroundTaskScheduler.swift`（一次性注册与执行门禁）
- `App/AppEnvironment.swift`
- `App/HealthManagerApp.swift`
- `Tests/SyncJobRecoveryTests.swift`
- `Tests/SyncEngineStartupGateTests.swift`
- `project.yml` 生成后的 `HealthManager.xcodeproj/project.pbxproj`（仅纳入新增源文件）
- 本任务书及 STAGE-009 / handoff 的结果回填

## 禁止修改

- v1～v5 migration 与既有数据合同
- HealthKit 写入/删除、照片生命周期、Today/Diet/Medication UI
- 版本号、Bundle ID、签名 Team 与 provisioning 策略
- 通过直接改真机数据库掩盖问题

## 行动拆解

1. 固定真实设备、既有 App、签名身份、Finder 备份和安装前数据库/照片证据，覆盖安装前不得改动设备数据。
2. 以独立恢复模块原子收敛遗留 job/report；用枚举 raw value 绑定数据库状态，避免字符串合同漂移。
3. 在 App 启动时先且仅一次注册 BGTask handler；恢复成功前关闭 scheduler 执行/重排、HealthKit observer、前台自动同步与 SyncEngine 全部公共同步入口。
4. 用定向测试证明恢复、幂等、既有证据保全和启动门禁，再跑全量 unit、全量 UI 与独立签名 device build。
5. Finder 备份完成后终止既有 App，冻结最终安装前数据库/照片基线；只有软件门与备份门均通过才覆盖安装。
6. 首次启动后只读复制数据容器，核对 v1～v5、完整性、外键、19 条遗留 job 的固定终态、餐食与照片差值。
7. STAGE-009R1 通过后再继续 HealthKit、照片、可访问性、睡眠和真实后台 observer 的七项真机验收；任一停止条件触发即保留证据并拆独立修复阶段。

## 预计完成标准

1. 单元测试证明 active job 与关联 running report 被恢复，终态行和既有证据不变。
2. 单元测试证明无 active job 时为 no-op，重复执行幂等。
3. 定向测试、全量 `HealthManagerTests`、全量 UI 与独立 device/Simulator build 均通过；计数来自 xcresult。
4. 新签名候选仍为 `com.norte.HealthManager` / Team `K8RVJSC4NU`，且目标真机在 provisioning profile 中。
5. Finder 备份完成且安装前数据库/照片基线留存后，才允许覆盖安装。
6. 覆盖安装首次启动后，真实数据库 v1～v5、integrity ok、FK 0，安装前 19 条 running 全部以固定恢复码进入 failed，active job 最终为 0。

## 验证边界

- 软件回归通过不等于真机门 PASS；第 6 项必须来自真实设备安装后的数据容器。
- 本阶段不把安装前已有的 14 个未引用照片文件归因于新版本；照片生命周期后续按“不得新增 orphan”的差值验证。
- 候选当前仍使用 0.2.5 (7) 开发签名元数据，因此正式 v0.3 发布就绪继续为 INCOMPLETE。

## 结果

### 双轴审查

- Standards：PASS。
- Spec：PASS。
- 固定比较基线：`b480e100f6e656e61f9f48c0c66c4fe656f3c5c1`；最终审查覆盖全部 tracked 与新增文件。
- 审查中发现并关闭的硬问题：BGTask handler 启动合同、恢复失败后的手动入口绕过、handler 注册 false 后错误开放同步，以及关联 backfill 既有证据漏测。

### 软件证据

- 定向恢复与启动门禁：3/3，0 failed / 0 skipped，`/tmp/healthmanager-stage009r1-targeted-20260715-attempt04.xcresult`。
- 全量 `HealthManagerTests`：245/245，0 failed / 0 skipped，`/tmp/healthmanager-stage009r1-full-unit-20260715-attempt03.xcresult`。
- 全量 `HealthManagerUITests`：6/6，0 failed / 0 skipped，`/tmp/healthmanager-stage009r1-full-ui-20260715-attempt03.xcresult`。
- 独立 iPhone 17 / iOS 26.5 Simulator 冷构建：0 error / 0 warning / 0 analyzer warning，`/tmp/healthmanager-stage009r1-simulator-build-20260715-attempt01.xcresult`。
- 独立签名 device Release 冷构建：0 error / 0 warning / 0 analyzer warning，`/tmp/healthmanager-stage009r1-device-release-build-20260715-attempt02.xcresult`。
- 签名：`K8RVJSC4NU.com.norte.HealthManager`，Team `K8RVJSC4NU`，HealthKit/background-delivery entitlement 均存在；目标 UDID 在 profile `0f272adb-41c3-46a3-8bfb-08514cdc8c3c` 中。

### 备份与覆盖安装证据

- 设备：iPhone Air（iPhone18,4），iOS 26.5.2 (23F84)，UDID `00008150-001204800152401C`。
- Finder 备份：`~/Library/Application Support/MobileSync/Backup/00008150-001204800152401C`，81GB，`SnapshotState=finished`；`Manifest.db` quick check 为 `ok`，320,243 条文件记录，设备/系统身份匹配。
- 最终安装前快照：`/tmp/healthmanager-stage009-device-preinstall-final-20260715-attempt01/`；v1～v4、integrity ok、FK 0、114 餐、3,352,655 条健康样本、19 个 active job、119 个唯一照片引用、缺失引用 0、物理照片 133、基线 orphan 14。
- 覆盖安装使用相同 Bundle ID/Team，未卸载、未清库；安装证据 `/tmp/healthmanager-stage009-device-install-20260715-attempt01.json`。
- 首次启动后快照：`/tmp/healthmanager-stage009-device-postinstall-first-launch-20260715-attempt01/`；v1～v5、integrity ok、FK 0、114 餐、`meal_items=0`、active job 0。
- 安装前 19 个 active job 的同一 ID 全部转为 `failed`，统一 `error_code=interrupted_before_completion`，结束时间一致；恢复计数 19。
- 其余用户表行数保持一致；启动期间新增 17 条真实 HealthKit raw sample 与 2 个 succeeded sync job，不是数据丢失。照片仍为 119 个唯一引用、缺失引用 0、物理文件 133、orphan 14，未新增 orphan。

### 结论与边界

STAGE-009R1：**PASS**。跨进程遗留任务恢复、启动 fail-closed、既有数据库 v5 升级和覆盖安装数据保全已有真实设备证据。此结论不替代 STAGE-009 剩余的 HealthKit 写入/更新/删除、照片交互、VoiceOver/最大字号、真实 sleepAnalysis 来源组合与新样本 observer 行为验收；正式发布就绪继续为 INCOMPLETE。
