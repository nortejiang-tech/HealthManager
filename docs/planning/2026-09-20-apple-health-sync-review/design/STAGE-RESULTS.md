# 阶段验收记录

## S01 — 首屏移除无用 raw 全表读取

状态：`PASS`

验收基线：

- Git HEAD：`1479db9e8aec80db1c557130315bcd0cb9e74949`
- `UI/Dashboard/DashboardData.swift` SHA256：`7284f9ed0a3c4272b96eb5216a71f5b7f05719686b06e7d04d3ab12081ad0aaa`
- `Tests/DashboardIndexMigrationTests.swift` SHA256：`e0316588e667098ef8b112a10ab3fbca352f086a97d2088ec8f242632128f03e`

Planner 独立验收：

1. 变更只触及声明白名单中的两个文件。
2. `DashboardSnapshot` 及 `DashboardLoader.loadSnapshot` 已移除首屏未消费的 raw 总数与最后写入时间查询；详情页按日读取 raw 的能力仍保留。
3. 新增回归测试删除隔离数据库中的 `health_samples_raw` 后调用真实 `DashboardLoader.loadSnapshot`，并校验活动、心率、睡眠、身体、饮食、热量差与提醒卡片。
4. `git diff --check` 通过；首屏相关文件内不再引用 `rawSampleCount` 或 `lastIngest`。
5. 声明的聚焦测试命令退出码为 `0`；xcresult 中 `20 passed, 0 failed, 0 skipped`。

验证结果：

- 命令：`xcodebuild -project /Users/nortepro/HealthManager/HealthManager.xcodeproj -scheme HealthManager -destination 'platform=iOS Simulator,id=6364DCEB-82DF-448C-91D9-2C19FD844AA8' -clonedSourcePackagesDirPath /Users/nortepro/Library/Developer/Xcode/DerivedData/HealthManager-ggcivopbkrhyayfzwvojpwacksqd/SourcePackages -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates -parallel-testing-enabled NO -only-testing:HealthManagerTests/DashboardIndexMigrationTests -only-testing:HealthManagerTests/DashboardNutritionEvidenceTests test CODE_SIGNING_ALLOWED=NO -quiet`
- 结果包：`/Users/nortepro/Library/Developer/Xcode/DerivedData/HealthManager-ggcivopbkrhyayfzwvojpwacksqd/Logs/Test/Test-HealthManager-2026.09.20_06-56-31-+0800.xcresult`
- 未验证边界：真实设备首屏可见时间由后续阶段统一验证；该项不影响 S01 的软件验收。

## S02 — 首屏阶段计时

状态：`PASS`

验收基线：

- Git HEAD：`1479db9e8aec80db1c557130315bcd0cb9e74949`
- `Core/Diagnostics/StartupMetrics.swift` SHA256：`464efd6de43a0fafe9ecb09c6ca84f129138e78f5bd8713b1b6e1adcfe3f6ffa`
- `App/AppEnvironment.swift` SHA256：`52a4ad387e575451f52d6f8d58add8ebf0050a0a2f997f56d5da5edf588e39f4`
- `UI/Dashboard/DashboardView.swift` SHA256：`c772e8882bddf1845a0aaf66f4bc4fa5f587cf7f3da8724498caf70969a34ef4`
- `Tests/StartupMetricsTests.swift` SHA256：`28392d118ce77ae8b4eb8cc5c9695ac861b3ba46c4e1b361aaee152181783e42`

Planner 独立验收：

1. 确定时钟测试覆盖有序里程碑、累计毫秒、序号、重复记录幂等、首屏 error/available 互斥以及 session ID 独立性。
2. `AppEnvironment` 在数据库创建前、数据库可用后、全部既有服务接线后记录阶段；BG 注册或恢复失败仍在原位置 return，恢复成功后才记录 ready。
3. `DashboardView` 只在尚无成功快照时记录初次请求，并在 generation 仍有效、主线程接收结果后记录 available/error；普通刷新不会重复生成启动事件。
4. S02 前已有的 HealthBridge 属性、构造、同步回调和本地数据导出触发全部保留。
5. 日志仅含 session、milestone、sequence、elapsedMs；不含数据库路径、健康值或错误正文。`git diff --check` 通过。
6. 声明的聚焦测试命令退出码为 `0`；xcresult 中 `5 passed, 0 failed, 0 skipped`。

验证结果：

- 红测：同一声明命令在生产实现缺失时退出码 `65`，明确报 `cannot find 'StartupMetrics' in scope`。
- 绿测命令：`xcodebuild -project /Users/nortepro/HealthManager/HealthManager.xcodeproj -scheme HealthManager -destination 'platform=iOS Simulator,id=6364DCEB-82DF-448C-91D9-2C19FD844AA8' -clonedSourcePackagesDirPath /Users/nortepro/Library/Developer/Xcode/DerivedData/HealthManager-ggcivopbkrhyayfzwvojpwacksqd/SourcePackages -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates -parallel-testing-enabled NO -only-testing:HealthManagerTests/StartupMetricsTests -only-testing:HealthManagerTests/SyncEngineStartupGateTests test CODE_SIGNING_ALLOWED=NO -quiet`
- 结果包：`/Users/nortepro/Library/Developer/Xcode/DerivedData/HealthManager-ggcivopbkrhyayfzwvojpwacksqd/Logs/Test/Test-HealthManager-2026.09.20_07-03-59-+0800.xcresult`
- 未验证边界：真实 `firstContentVisible` 与真机冷启动耗时由后续 UI/真机阶段验证；本阶段只证明 `snapshotAvailable`。

## S03 — 纯请求合并与公平调度状态

状态：`PASS`

验收基线：

- Git HEAD：`1479db9e8aec80db1c557130315bcd0cb9e74949`
- `Core/Sync/SyncDemand.swift` SHA256：`972d722a5903d213d6f53311327b1a5fd300db188cc5a61ce90aa52faf6a1fed`
- `Core/Sync/SyncSchedulingState.swift` SHA256：`0f65e4a971d4ef3999698368acbb867fe10967a9b4e1f534bf1892191bc226cb`
- `Tests/SyncSchedulingStateTests.swift` SHA256：`c2cf1cbc369a64a4770af373e58e2f225ce43dda9cfa571b0bd8866c0ec346c7`

Planner 独立验收：

1. reducer 只依赖 Foundation，不含 Task、数据库、HealthKit、MainActor、timer 或静态可变状态。
2. 同 intent 重复提交幂等；多类型提交在任何 generation 溢出时整次不变；1000 个真实事件只形成一个 pending 类型集合。
3. active token 唯一；token 不匹配不能释放或推进 completed；deferred 类型保持 pending 且不会造成空转 busy。
4. claim 每次只捕获一个类型的当前 generation；运行中追加的更高 generation 在旧 claim 完成后继续 pending。
5. 字典序循环游标保证 A 被重新请求且 B 已 ready 时先轮到 B；受控 A/B/A/A 序列最终保留 A 的第 4 代。
6. `git diff --check` 通过；声明聚焦测试退出码为 `0`，xcresult 中 `9 passed, 0 failed, 0 skipped`。

验证结果：

- 红测：生产值类型和 reducer 缺失时声明命令退出码 `65`，明确报 `cannot find 'SyncSchedulingState' in scope`。
- 绿测命令：`xcodebuild -project /Users/nortepro/HealthManager/HealthManager.xcodeproj -scheme HealthManager -destination 'platform=iOS Simulator,id=6364DCEB-82DF-448C-91D9-2C19FD844AA8' -clonedSourcePackagesDirPath /Users/nortepro/Library/Developer/Xcode/DerivedData/HealthManager-ggcivopbkrhyayfzwvojpwacksqd/SourcePackages -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates -parallel-testing-enabled NO -only-testing:HealthManagerTests/SyncSchedulingStateTests test CODE_SIGNING_ALLOWED=NO -quiet`
- 结果包：`/Users/nortepro/Library/Developer/Xcode/DerivedData/HealthManager-ggcivopbkrhyayfzwvojpwacksqd/Logs/Test/Test-HealthManager-2026.09.20_07-10-06-+0800.xcresult`
- 未验证边界：本阶段没有接入真实 runner 或持久队列，不能据此宣布自动同步漏跑已经修复。

## S04A — HealthKit 错误分类

状态：`PASS`

验收基线：

- Git HEAD：`1479db9e8aec80db1c557130315bcd0cb9e74949`
- `Core/Sync/SyncFailurePolicy.swift` SHA256：`a2fe199ccf4560d33873dbc8859c3a0268a8055f8a35a2aa41ce812ccffa1207`
- `Tests/SyncFailurePolicyTests.swift` SHA256：`1c8398f92e5321eda8a1220bef477b2dc0c404654c75b866ccb451b0f687c06a`

Planner 独立验收：

1. 使用本机 SDK 的 `HKError.Code` 构造分类测试；受保护数据锁定映射为 `waitForUnlock`，三种授权错误映射为 `authorizationCheck`，用户取消与结构化取消映射为 `cancelled`。
2. `HealthKitManager.HKError.queryFailed` 与 `NSUnderlyingErrorKey` 递归解包，深度上限为 8。
3. `errorNoData` 不被误判为授权错误；未知 domain/code 原样保留。
4. 分类器不读取 `localizedDescription`、message 或英文文本。
5. Objective-C extensible enum 可由任意 raw value 构造；Planner 修复为按本机 SDK 已知连续范围判定，9999 保持 unknown。
6. `git diff --check` 通过；声明聚焦测试 `9 passed, 0 failed, 0 skipped`。

验证结果：

- 红测：分类器缺失时声明命令退出码 `65`，SDK 枚举名称本身已成功编译。
- 绿测命令：`xcodebuild -project /Users/nortepro/HealthManager/HealthManager.xcodeproj -scheme HealthManager -destination 'platform=iOS Simulator,id=6364DCEB-82DF-448C-91D9-2C19FD844AA8' -clonedSourcePackagesDirPath /Users/nortepro/Library/Developer/Xcode/DerivedData/HealthManager-ggcivopbkrhyayfzwvojpwacksqd/SourcePackages -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates -parallel-testing-enabled NO -only-testing:HealthManagerTests/SyncFailurePolicyTests test CODE_SIGNING_ALLOWED=NO -quiet`
- 结果包：`/Users/nortepro/Library/Developer/Xcode/DerivedData/HealthManager-ggcivopbkrhyayfzwvojpwacksqd/Logs/Test/Test-HealthManager-2026.09.20_07-16-06-+0800.xcresult`
- 未验证边界：本阶段只分类，不改变查询取消、deadline 或重试循环。

## S04B — 可取消且有 deadline 的 HealthKit 查询

状态：`PASS`

验收基线：

- `Core/HealthKit/HealthKitQueryExecutor.swift` SHA256：`d27471fc77c1432055d76de9750793cb4952ed14bb7a5312fbc311fe897be4af`
- `Core/HealthKit/HealthKitManager.swift` SHA256：`913772bff6241e7f0b472103f4f72ee8ec5bfb23aef9c328696a93adbd77d566`
- `Tests/HealthKitQueryLifecycleTests.swift` SHA256：`01944c1499b4606e31ea888662aac30ebcdfb7c0ba3fa6c8f830a4d50665d1df`

Planner 独立验收：

1. query 注册、execute、callback、timeout、cancel 与 stop 由单一串行生命周期队列仲裁；取消另有同步标记，使注册前取消不会 execute。
2. callback、timeout、取消只允许第一个终态恢复 continuation；重复/迟到 callback 被忽略。
3. timeout/取消胜出时只 stop 一次并取消 deadline；正常 callback 不 stop，但仍清理 deadline。
4. 没有使用会等待不响应取消子任务的 `withThrowingTaskGroup` race。
5. `fetchSamples`、`anchoredFetch` 与日累计 statistics 均接入 8 秒默认 deadline；现有错误包装、授权与营养写回接口保持。
6. 聚焦测试覆盖注册前取消、execute 后取消、timeout 后迟到/重复 callback、首 callback 胜出和完成/取消 50 次竞争。
7. `git diff --check` 通过；S04B + S04A 合并验证 `14 passed, 0 failed, 0 skipped`。

验证结果：

- 命令：`xcodebuild -project /Users/nortepro/HealthManager/HealthManager.xcodeproj -scheme HealthManager -destination 'platform=iOS Simulator,id=6364DCEB-82DF-448C-91D9-2C19FD844AA8' -clonedSourcePackagesDirPath /Users/nortepro/Library/Developer/Xcode/DerivedData/HealthManager-ggcivopbkrhyayfzwvojpwacksqd/SourcePackages -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates -parallel-testing-enabled NO -only-testing:HealthManagerTests/HealthKitQueryLifecycleTests -only-testing:HealthManagerTests/SyncFailurePolicyTests test CODE_SIGNING_ALLOWED=NO -quiet`
- 结果包：`/Users/nortepro/Library/Developer/Xcode/DerivedData/HealthManager-ggcivopbkrhyayfzwvojpwacksqd/Logs/Test/Test-HealthManager-2026.09.20_07-20-44-+0800.xcresult`
- 未验证边界：模拟器 fake 证明生命周期；真机 HealthKit stop/deadline 行为留到最终设备验收。

## S05 — durable work 和原子页提交

状态：`PASS`

验收基线：

- Git HEAD：`1479db9e8aec80db1c557130315bcd0cb9e74949`
- `Core/Database/Migrations.swift` SHA256：`01528c9a4e7ccc257b7db741082d772fd82ed4afce0557cf0fbe8eba4422c05d`
- `Core/Sync/SyncWorkStore.swift` SHA256：`5c3ac2e432571c2d03965512533b90a87f1d03add8db6c1cc7a388d53af8b02e`
- `Core/Sync/SyncJobRecovery.swift` SHA256：`bd9b079886b78e3c6d042cf10a7111138f8713b70aabe5154b983654cf053840`
- `Tests/SyncWorkStoreTests.swift` SHA256：`b48b003ad343e941eed049ee1f81a6ba9a07f7a21d3cded69c9b9dbc9ccad946`

Planner 独立验收：

1. v14 只追加三张运行时控制表；既有 v12/v13 HealthBridge 迁移原样保留，新表没有进入备份格式。
2. request 以持久代次表达；进程重开后 pending、dirty、deferred 与 restore marker 均保留，restore/暂停时不会产生可 claim 工作。
3. 样本插入、软删除、dirty date、anchor 与捕获代次完成在同一 GRDB 写事务中；四个故障注入点都证明整页回滚。
4. 新一代 request 不会被旧 claim 清除；实际插入/删除数来自 SQLite change count；未知 tombstone 不创建虚假 dirty date。
5. dirty date 按指定本地日历逐日展开，跨时区/DST 不按固定 86400 秒推算；无 raw 证据时不会清理恢复的 daily aggregate。
6. `git diff --check` 通过；聚焦回归 `12 passed, 0 failed, 0 skipped`。

验证结果：

- 命令：`xcodebuild -project /Users/nortepro/HealthManager/HealthManager.xcodeproj -scheme HealthManager -destination 'platform=iOS Simulator,id=6364DCEB-82DF-448C-91D9-2C19FD844AA8' -clonedSourcePackagesDirPath /Users/nortepro/Library/Developer/Xcode/DerivedData/HealthManager-ggcivopbkrhyayfzwvojpwacksqd/SourcePackages -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates -parallel-testing-enabled NO -only-testing:HealthManagerTests/SyncWorkStoreTests -only-testing:HealthManagerTests/SyncJobRecoveryTests -only-testing:HealthManagerTests/BackupV3Tests test CODE_SIGNING_ALLOWED=NO -quiet`
- 结果包：`/Users/nortepro/Library/Developer/Xcode/DerivedData/HealthManager-ggcivopbkrhyayfzwvojpwacksqd/Logs/Test/Test-HealthManager-2026.09.20_07-26-40-+0800.xcresult`
- 未验证边界：本阶段尚未接入真实分页查询；pending 的消费和 deadline slice 由 S06/S08 完成。

## S06 — 分页增量执行器

状态：`PASS`

验收基线：

- `Core/Sync/IncrementalSyncCoordinator.swift` SHA256：`1ee0277053b4b196a6432488ad02ae03ac8d8fbccf25f0a85f4231c58aea5112`
- `Core/Sync/SyncPageRunner.swift` SHA256：`c03471715d366ff23f9c5f84c7e49d7f06edd627c57dd588c04b6dca9bb86a23`
- `Tests/SyncPageRunnerTests.swift` SHA256：`0888944402ce0b5a2c0241267263f0513ea685f9287a80db5f70e42d9827b20b`

Planner 独立验收：

1. HealthKit anchored query 固定每页上限 1000；只在 added 和 deleted 同时为空的确认页完成捕获代次，删除-only 页会继续分页。
2. 每页通过 S05 的同一事务提交样本、软删除、dirty date 与新 anchor；第二页查询失败时第一成功页保留，失败页不会推进 anchor。
3. 页数或时间预算耗尽返回 `hasPending`，不清除代次；下一 slice 从最后已提交 anchor 继续。nil anchor 保留合法全历史分页语义。
4. 不支持的映射在提交前显式失败；非空页缺少新 anchor 显式失败，避免重复非进展页忙循环。
5. 损坏 anchor 返回 `repairRequired`，原始 anchor 行保留，不再删除证据并静默触发无界全量重拉。
6. 真实 WorkStore fixture 覆盖 2501 条 added、1001 条 deletion-only、多 slice 续跑、重复页、第二页失败、映射失败与无变化页；`git diff --check` 通过。

验证结果：

- 命令：`xcodebuild -project /Users/nortepro/HealthManager/HealthManager.xcodeproj -scheme HealthManager -destination 'platform=iOS Simulator,id=6364DCEB-82DF-448C-91D9-2C19FD844AA8' -clonedSourcePackagesDirPath /Users/nortepro/Library/Developer/Xcode/DerivedData/HealthManager-ggcivopbkrhyayfzwvojpwacksqd/SourcePackages -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates -parallel-testing-enabled NO -only-testing:HealthManagerTests/SyncPageRunnerTests -only-testing:HealthManagerTests/SyncWorkStoreTests test CODE_SIGNING_ALLOWED=NO -quiet`
- 结果包：`/Users/nortepro/Library/Developer/Xcode/DerivedData/HealthManager-ggcivopbkrhyayfzwvojpwacksqd/Logs/Test/Test-HealthManager-2026.09.20_07-34-57-+0800.xcresult`
- 结果：`15 passed, 0 failed, 0 skipped`。
- 未验证边界：本阶段的 compatibility coordinator 仍按入口执行一个有界 pass；所有入口的唯一 worker、繁忙期间合并和自动续跑由 S07 完成。

## S07 — 唯一 runner 接入现有 SyncEngine

状态：`PASS`

验收基线：

- `Core/Sync/SyncRunner.swift` SHA256：`390a9f08167284c60292aac6358c3d640b033dd0a75949c9258f28e645b1d952`
- `Core/Sync/SyncEngine.swift` SHA256：`700912121a157c0fc535877d52505ed220e50a7436dd4e59d59b8ebf33cb5b66`
- `Core/Sync/SyncStateMachine.swift` SHA256：`3d28c8001c441ebb546fed1a62515eb883ad5ba0327a37615b0cb51c99fa4eec`
- `Tests/SyncRunnerIntegrationTests.swift` SHA256：`8b2fd415778648408b1d403030bc1bcef2abb4a781df23eda3586a498e7406dd`

Planner 独立验收：

1. `SyncRunner` actor 是 incremental worker handle 的唯一所有者；每次 submit 先持久化 generation，再创建或复用 worker。
2. A 已 claim 后再次收到 A，旧 claim 只完成旧代次；worker 重读 durable queue 并自动执行第二 slice，无需再次调用入口。
3. 1000 个 observer 提交在受控竞争中只执行两次 slice，而不是 1000 次全类型扫描；最终完成第 1001 代。
4. 单个 waiter 取消不会取消共享持久工作；slice 失败会释放 worker、保留 pending，未发现孤立 busy。
5. 旧 backfill/manual envelope 占用写入面时，incremental 入口持久排队而不丢弃；backfill 释放后主动给 runner 新执行机会。
6. SyncEngine 的公开接口与现有状态机保持兼容；原 startup recovery gate 仍阻止所有入口提前运行。

验证结果：

- 命令：`xcodebuild -project /Users/nortepro/HealthManager/HealthManager.xcodeproj -scheme HealthManager -destination 'platform=iOS Simulator,id=6364DCEB-82DF-448C-91D9-2C19FD844AA8' -clonedSourcePackagesDirPath /Users/nortepro/Library/Developer/Xcode/DerivedData/HealthManager-ggcivopbkrhyayfzwvojpwacksqd/SourcePackages -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates -parallel-testing-enabled NO -only-testing:HealthManagerTests/SyncRunnerIntegrationTests -only-testing:HealthManagerTests/SyncEngineStartupGateTests -only-testing:HealthManagerTests/SyncStateMachineTests test CODE_SIGNING_ALLOWED=NO -quiet`
- 结果包：`/Users/nortepro/Library/Developer/Xcode/DerivedData/HealthManager-ggcivopbkrhyayfzwvojpwacksqd/Logs/Test/Test-HealthManager-2026.09.20_07-40-40-+0800.xcresult`
- 结果：`13 passed, 0 failed, 0 skipped`；`git diff --check` 通过。
- 已知边界：manual 的外部 App 等待仍沿用旧 envelope，按设计留到 S10；后台 expiration/observer completion 的 lease 语义由 S08B 完成。

## S08A — 启动与授权就绪补触发

状态：`PASS`

验收基线：

- `App/AppEnvironment.swift` SHA256：`0bff9800868dfae4fc18ef6c216952c46fed814b5cd4416a282943849322f0cf`
- `App/HealthManagerApp.swift` SHA256：`281d145d7771365aff776139918f5d26317c46a421c64719c780c26619ea7b12`
- `App/RootView.swift` SHA256：`541036c043ad01101ba1a6afa5f36576bc5515e8fee12b78cabce0215514af95`
- `Tests/SyncStartupLifecycleTests.swift` SHA256：`7636381473ac68cf183ada649800b4f92234a3b245a6db84c9223b19e1e7b71f`

Planner 独立验收：

1. 纯 lifecycle reducer 覆盖 active/authReady/recoveryReady 的全部六种排列；每种顺序最终只启动一次 observer、执行一次必要全类型检查。
2. recovery 失败时 observer 和自动检查始终关闭；同一 active epoch 的重复通知幂等，新的前台 epoch 在最新授权检查后补跑一次。
3. BG launch handlers 仍在 recovery 前注册一次，自动执行仍同时受 scheduler 与 SyncEngine startup gate 约束。
4. HealthKit 授权刷新从 RootView `.task` 移到 App 生命周期，observer 不再依赖某个 View 出现。
5. 已请求过授权的旧用户在 gate 暂为 unknown 时先进入本地主界面，但 lifecycle 的同步授权门仍关闭；首次安装仍显示 onboarding。
6. 空 read-type readiness 不会被 reducer 当成可同步，且当前 catalog 的实际 read 集合非空。

验证结果：

- 命令：`xcodebuild -project /Users/nortepro/HealthManager/HealthManager.xcodeproj -scheme HealthManager -destination 'platform=iOS Simulator,id=6364DCEB-82DF-448C-91D9-2C19FD844AA8' -clonedSourcePackagesDirPath /Users/nortepro/Library/Developer/Xcode/DerivedData/HealthManager-ggcivopbkrhyayfzwvojpwacksqd/SourcePackages -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates -parallel-testing-enabled NO -only-testing:HealthManagerTests/SyncStartupLifecycleTests -only-testing:HealthManagerTests/SyncEngineStartupGateTests test CODE_SIGNING_ALLOWED=NO -quiet`
- 结果包：`/Users/nortepro/Library/Developer/Xcode/DerivedData/HealthManager-ggcivopbkrhyayfzwvojpwacksqd/Logs/Test/Test-HealthManager-2026.09.20_07-43-10-+0800.xcresult`
- 结果：`7 passed, 0 failed, 0 skipped`；`git diff --check` 通过。
- 未验证边界：真机授权弹窗逐项结果仍由 iOS 管理，Apple 不公开 read-side 的逐类型授权状态；S08A 只验证本 App 不把 unknown/空集合误当成自动同步 ready。

## S08B — Observer 与后台机会适配

状态：`PASS`

验收基线：

- `Core/Sync/HealthKitObserver.swift` SHA256：`0493a3f664313b339d2214b0a1852a4ba2b053a9a671b6dd6ba5cd4cfb097501`
- `Core/Sync/BackgroundTaskScheduler.swift` SHA256：`74103a69c853c83e1d7f2d76ab876319e3459233679edecc0579a871d92ea1ac`
- `Core/Sync/IncrementalSyncCoordinator.swift` SHA256：`c8c1d0c012079f3b25fe022a9a605b4597bd229a9cb2baa9c68f793410362f48`
- `Tests/SyncDeliveryLifecycleTests.swift` SHA256：`20def884e8173890bd92d9a3d9c7b45e72cc66a049fc8d1f3105a6b41b20cf4a`

Planner 独立验收：

1. Observer completion 只在目标类型已应用，或已可靠持久化为 unlock/authorization/cancelled/transient deferred 时确认；repair/failure/未入账不会误报处理成功。
2. BG completion 按全部必需类型的实际 ledger outcome 判定；deferred、failed、cancelled 与未完成均返回 false。
3. 正常完成与 expiration 通过线程安全一次性 gate 竞争，100 次并发完成调用只执行一次；BG waiter 取消不取消共享 runner 工作。
4. HealthKit protected-data 错误出现后，其余未查询类型直接进入 waitForUnlock，不再逐类型重复查询/三次重试。
5. `enableBackgroundDelivery` 失败不再永久卡死：查询注册保持幂等，失败类型按 30s/60s 有限退避重试，最多三次。
6. 模拟器验证只证明 App 内回调/ledger 语义，不冒充 iOS 真实后台投递。

验证结果：

- 命令：`xcodebuild -project /Users/nortepro/HealthManager/HealthManager.xcodeproj -scheme HealthManager -destination 'platform=iOS Simulator,id=6364DCEB-82DF-448C-91D9-2C19FD844AA8' -clonedSourcePackagesDirPath /Users/nortepro/Library/Developer/Xcode/DerivedData/HealthManager-ggcivopbkrhyayfzwvojpwacksqd/SourcePackages -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates -parallel-testing-enabled NO -only-testing:HealthManagerTests/SyncDeliveryLifecycleTests -only-testing:HealthManagerTests/SyncRunnerIntegrationTests test CODE_SIGNING_ALLOWED=NO -quiet`
- 结果包：`/Users/nortepro/Library/Developer/Xcode/DerivedData/HealthManager-ggcivopbkrhyayfzwvojpwacksqd/Logs/Test/Test-HealthManager-2026.09.20_07-51-31-+0800.xcresult`
- 结果：`9 passed, 0 failed, 0 skipped`；`git diff --check` 通过。

## S09 — 按受影响日期投影

状态：`PASS`

验收基线：

- `Core/Aggregate/DailyAggregator.swift` SHA256：`b4869e7d75ffd7d5f3c0d3d41ee26708732f8e4a1ad445b0eec21debd9654016`
- `Core/Sync/ProjectionWorker.swift` SHA256：`4eaf17b4a3094fed724319fcc912354516d2f2911e0709be5f7e0f4ce3b6b794`
- `Core/Sync/SyncRunner.swift` SHA256：`eb8803a177ff0579125d89273ff258d35e574ae347de33c63515b6d34886dcbb`
- `Core/Sync/SyncEngine.swift` SHA256：`83ced00c74a05b1f4217aff7482386d1aa25c8bbacc1d67f63e636bcca859b96`
- `Tests/IncrementalProjectionTests.swift` SHA256：`9976ad50cd275a8d8900b8891e1692de3c88b03f7521f2233e1d136fbd0ffe55`

Planner 独立验收：

1. DailyAggregator 新增确定 calendar 的指定日期接口；incremental 只消费 durable dirty dates，不再固定重算最近 7 天。
2. dirty row 按捕获 generation 清除；投影期间新增代次不会被旧工作确认，runner 会继续有界消费剩余投影。
3. 覆盖 120 天前添加/删除、sleep 跨午夜 start-day、跨日 workout、洛杉矶 DST 23/25 小时、时区变化与进程持久待办。
4. 时区/版本变化只按现有 raw 覆盖日期排队；没有 raw 的恢复汇总不会被空投影覆盖。
5. 相同发布值不更新 computedAt，零 dirty 不写投影、不增加 downstream tick；真实内容变化后才发布刷新。
6. Apple Health 日统计仍作为受影响跨度内的 bounded override；失败时保留 raw 聚合 fallback，不清空已发布值。

验证结果：

- 命令：`xcodebuild -project /Users/nortepro/HealthManager/HealthManager.xcodeproj -scheme HealthManager -destination 'platform=iOS Simulator,id=6364DCEB-82DF-448C-91D9-2C19FD844AA8' -clonedSourcePackagesDirPath /Users/nortepro/Library/Developer/Xcode/DerivedData/HealthManager-ggcivopbkrhyayfzwvojpwacksqd/SourcePackages -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates -parallel-testing-enabled NO -only-testing:HealthManagerTests/IncrementalProjectionTests -only-testing:HealthManagerTests/DailyAggregatorSleepTests -only-testing:HealthManagerTests/DailyAggregatorEnergyTests -only-testing:HealthManagerTests/DashboardNutritionEvidenceTests test CODE_SIGNING_ALLOWED=NO -quiet`
- 结果包：`/Users/nortepro/Library/Developer/Xcode/DerivedData/HealthManager-ggcivopbkrhyayfzwvojpwacksqd/Logs/Test/Test-HealthManager-2026.09.20_07-50-58-+0800.xcresult`
- 结果：`32 passed, 0 failed, 0 skipped`；`git diff --check` 通过。

## S10 — 手动两次同步最终状态

状态：`PASS`

验收基线：

- `Core/Sync/ManualSyncCoordinator.swift` SHA256：`30cb09fe0986c4e8682add5e97f7d6848be07b8118f2ab63a572c7672c3facc5`
- `Core/Sync/SyncEngine.swift` 阶段验收 SHA256：`5a4a962698159a93d49187939110e925aa139eb3b6f4191bf959eab28eafbbc8`
- `Tests/ManualSyncOutcomeTests.swift` SHA256：`c0a18dadf7273a068a698e22e57470addc46a334c11b816630a728082279dbbf`

Planner 独立验收：

1. 手动父会话在两次 runner pass 之间等待用户时不占用共享 writer；observer/前台 demand 可以继续进入 durable 队列。
2. pass2 同类型成功（包括零新增）覆盖 pass1 同类型错误；其他仍失败类型保留最新错误，授权不可读不被提升为整轮失败。
3. waiter 在 resume、取消和重复确认下只结束一次；父会话和两次子 job 不复用 job id。
4. 手动同步继续保留外部 App 提示和饮食营养写回入口；数据投影通过共享 runner 完成后才发布结果。
5. 聚焦回归 `17 passed, 0 failed, 0 skipped`；`git diff --check` 通过。

验证结果：

- 结果包：`/Users/nortepro/Library/Developer/Xcode/DerivedData/HealthManager-ggcivopbkrhyayfzwvojpwacksqd/Logs/Test/Test-HealthManager-2026.09.20_07-55-13-+0800.xcresult`
- 未验证边界：外部健康 App 的真实写入与返回时序留到 S13 真机验收。

## S10B — 备份恢复与新同步互锁

状态：`PENDING`

验收基线：

- `Core/Backup/BackupManager.swift` SHA256：`1aa173efff82e18938d8554b812324c226940f83420488682e70285200bfe73c`
- `Core/Backup/BackupImporter.swift` SHA256：`5fddca1c1c499aafcee15fdd1ea207094dadc5134e42be6b207d24f373766361`
- `App/AppEnvironment.swift` 阶段验收 SHA256：`b415d15d71e0d3230dcc1f7d883ef062ea08e38d0c89b3ef6136aad028010bdc`
- `Core/Sync/SyncRunner.swift` SHA256：`168a55ac5746338e9836b1da6c4fba1bcc6c54a0cc442124d233f71670a139c0`
- `Tests/SyncRestoreIntegrationTests.swift` SHA256：`64c48d79345468aef2dd02d39a57eb3812ee1aeb814230f3743a97fe4362e783`

Planner 独立验收：

1. restore barrier 先停止新的 writer 机会、取消并等待当前 worker 退出，再写 durable marker，随后才允许 BackupImporter 改内容。
2. 成功恢复清 marker 但保留原 pending demand；失败或进程中断保留 marker，重开后不会静默恢复写入。
3. 模拟 query 晚回调不能覆盖导入后的汇总；无 raw 的恢复汇总不会被空投影清除。
4. Backup V3 表列表与格式保持不变，新 runtime/pending/control 表没有进入用户备份内容。
5. 新增的 4 条恢复集成测试均通过；声明组合套件共 `18 passed, 1 failed, 0 skipped`。

PENDING 原因：

- 唯一失败为既有 `BackupExportImportTests.test_locationStore_saveLoadClearRoundTrip()`，测试宿主在 `CODE_SIGNING_ALLOWED=NO` 下访问 Keychain 返回 `-34018`（缺少 entitlement）。单独重跑结果相同；没有恢复逻辑断言失败。
- 该环境门不阻塞后续纯软件阶段，但 S10B 在有签名测试宿主或真机完成同一 Keychain round-trip 前不标记整体 PASS。

## S11A — Bridge payload 读取与维护有界化

状态：`PASS`

验收基线：

- `HealthBridge/Sources/BridgeCore/Source.swift` SHA256：`a9db5d903b8ba43e82df0b8897f2fbd8c83186bfd40d63765f31edeb65fdce56`
- `Core/Bridge/HealthBridgeManager.swift` SHA256：`e1ae676b740762190d9b725deb0ff656ecf5fe8b35e890d68dfea540658c362a`
- `HealthBridge/Tests/BridgeCoreTests/BridgePublishSchedulingTests.swift` SHA256：`f388469746fa119d037916e115ffa447ac20440db598e972ceaec98bd9978979`

Planner 独立验收：

1. publish metadata 查询不再包含 payload；只有目录缺失、文件不完整或达到重放间隔的未确认批次才读取 durable payload。
2. 合成 `418` 批、`411 acknowledged`、`7 pending` 场景只触发 7 次 payload reader；写出的 payload、manifest、bytes 与 sha256 与 outbox 完全一致。
3. 有效 receipt 不读 payload 即确认；错误 hash 不确认。中断后的不完整目录从 outbox 重放完全相同字节。
4. 未确认发布与已确认维护各有独立固定预算；同步目录中的原子 sidecar cursor 跨调用推进，receiver 不扫描该隐藏文件，不需 schema 迁移。
5. 已确认批次只有在 receipt 再验证通过且超过 7 天后才删除 batch/清 payload；未满 7 天或 receipt 无效继续保留。
6. 大型初始快照若单次打满 32 批且确有发布/确认进展，Manager 只续排下一个有界 pass；65 批回归按 `32 + 32 + 1` 排空，下一轮不再自旋。

验证结果：

- 声明聚焦测试：`5 passed, 0 failed, 0 skipped`。
- HealthBridge 完整 package：`20 passed, 0 failed, 0 skipped`，60,000 行内存回归增长约 `5.1 MiB`。
- `HealthBridge/Package.resolved` 未修改；`git diff --check` 通过。

## S11B — 首轮本地加载后再安排维护

状态：`PASS`

验收基线：

- `App/AppEnvironment.swift` SHA256：`98a2b33be9d6b1f887e0a0560eabc1880100e2d56ae8fd0ef385eab3849560d5`
- `App/HealthManagerApp.swift` SHA256：`5ce547bda17da55f3316880e526ca00c825c0ea2ed60f1d72fed63f60edd0a10`
- `UI/Dashboard/DashboardView.swift` 阶段验收 SHA256：`f9eafc19e007240cd11efe9dda28cf4010d97c0103dbe19f7f56125ed61c29b6`
- `Tests/StartupMaintenanceGateTests.swift` SHA256：`b5153deee943fee33b03c2d6cc41f2294d2ad75d97acc5797ed1fa5715dcb8e3`
- 接口依赖修正 `Core/Sync/SyncEngine.swift` 最终 SHA256：`fc1d0cfb5951c706ba5033bea72b8ec72bdfa7d1088840bc72ebb52e765c1835`

Planner 独立验收：

1. 前台 Bridge、聚合补建和目录种子在首次 Dashboard 本地快照成功或失败落定后才释放；快照读取本身不等待这些维护。
2. 快照先于 scene active 落定和 scene 先 active 的两种顺序都只释放一次；重复 active/refresh/background 不重复启动 startup maintenance。
3. 没有 Dashboard 的后台启动由单独 background opportunity 释放，不等待 SwiftUI 页面创建；备份导出保留在后台路径。
4. 聚合存在性查询由 raw/daily 全表 COUNT 改为 EXISTS；无 raw 时保留恢复的 daily aggregate。
5. `runCatchUpAggregation` 返回真实 raw 投影结果，失败不再推进 UserDefaults projection version。该必要接口位于原阶段白名单外，由 Planner 接管并记录为边界扩展。

验证结果：

- 聚焦回归：`16 passed, 0 failed, 0 skipped`。
- 结果包：`/Users/nortepro/Library/Developer/Xcode/DerivedData/HealthManager-ggcivopbkrhyayfzwvojpwacksqd/Logs/Test/Test-HealthManager-2026.09.20_08-21-48-+0800.xcresult`
- `git diff --check` 通过。

## S12 — 真实阶段状态与显示

状态：`PASS`

验收基线：

- `UI/SyncCenter/SyncPresentation.swift` SHA256：`e9f66539a330d1fc2b5e722eb4316127c830e24050aa45e3f7c9e2ab4168903b`
- `UI/SyncCenter/SyncCenterView.swift` SHA256：`d16e42fb465919a761eb80cae245e6f9d3b98c1c98854e5482339029d74b9437`
- `UI/Dashboard/DashboardView.swift` SHA256：`f9eafc19e007240cd11efe9dda28cf4010d97c0103dbe19f7f56125ed61c29b6`
- `Tests/SyncPresentationTests.swift` SHA256：`b5701ee34fbdfbb52983cad8316c1d3308ebc7c680a396c31cf5b8dc53778112`

Planner 独立验收：

1. 纯 presentation 映射区分读取、投影、等待解锁、等待授权检查、部分完成、已更新、零变化检查与失败。
2. `completed + 0 changes` 显示“已检查，无新增”，明确不等于没有历史数据；projection pending 的结果不能显示 completed。
3. durable `sync_type_work` 和 `sync_projection_work` 只读证据进入显示层；waitForUnlock 优先于 authorization 文案，不会把设备锁定说成全部权限拒绝。
4. 进度直接使用实际阶段描述，不生成估算百分比；完成时间取真实 `endedAt`。
5. 失败/部分完成保留已写入数、错误详情和可访问的“重试本地同步”按钮；Dashboard 刷新失败继续保留旧 snapshot。

验证结果：

- 聚焦回归：`14 passed, 0 failed, 0 skipped`。
- 结果包：`/Users/nortepro/Library/Developer/Xcode/DerivedData/HealthManager-ggcivopbkrhyayfzwvojpwacksqd/Logs/Test/Test-HealthManager-2026.09.20_08-12-41-+0800.xcresult`
- `git diff --check` 通过。

## S13 — 软件回归与真实设备验收

状态：`PENDING`

### 软件回归

1. 最终候选 Debug build 已成功签名、安装并在 `NortePro的iPhone`（iPhone18,4，iOS 27.0）启动；bundle ID 为 `com.norte.HealthManager`，App 数据容器 UUID 覆盖安装前后保持不变。
2. 新增的 observer 单类型 demand、runner 空闲提交竞争和启动首投递覆盖回归共 `21 passed, 0 failed, 0 skipped`。
3. 备份导出改为目标同目录 staging 完整生成后再用同卷替换发布；故障注入证明提交前中断时旧包逐字节不变，成功重导后 manifest 与全部文件一致且 staging 被清理。两个新测试和既有完整 round-trip 共 `3 passed, 0 failed, 0 skipped`。
4. 早期未签名 Simulator 测试宿主中的唯一 Keychain `-34018` 已由有签名完整回归关闭。最终完整测试为 `437 passed, 0 failed, 0 skipped`，其中 `HealthManagerTests 428/428`、`HealthManagerUITests 9/9`；UI 覆盖餐次保存、列表可见、重新打开后数据持久化、复用和清理。
5. 本轮真机发现并修复四个同步集成缺陷：observer callback 曾把单类型事件扩大为全 28 类型请求；coordinator 曾重复写一轮全类型 generation；runner 在空队列探测与提交 idle 之间存在新 demand 被搁置窗口；启动注册后的首个 BodyMass observer delivery 与同批 full check 重叠，造成每次冷启动遗留一个 generation。最终实现用单类型 scope、删除重复 request、revision + durable ledger 双重 idle 复核，以及同批 startup full check 的一次性首投递覆盖消除这些问题。
6. 餐次卡死修复的聚焦结果包为 `/tmp/healthmanager-meal-save-hang/projection-fix-targeted-1.xcresult`（`9/9`）；最终完整结果包为 `/tmp/healthmanager-meal-save-hang/full-unit-after-projection-fix.xcresult`（`437/437`）。
7. 修复后签名候选 Debug dylib SHA256 为 `f9a29aed3a840f7e2c1c424c61effd559f21204452aec85e3527a437402d4f32`；真机 build 结果包为 `/tmp/healthmanager-meal-save-hang/device-build-after-fix-2.xcresult`，覆盖安装回执为 `/tmp/healthmanager-meal-save-hang/device-install-after-fix.json`。安装成功且沿用原数据容器 UUID `6A7E06F0-54E8-4FCB-88F2-A02DEB810ED4`。

### 餐次保存卡死根因与修复

- 用户现场页面停在“保存中”时复制数据库取证：`meal_records=338`、`max(id)=357`，没有新的餐次或待写 HealthKit 记录，说明阻塞发生在 SQLite 提交之前，不是保存后 dismiss 或 HealthKit 回写阶段。进程终止后记录仍未出现，本次失败录入没有落库。
- 真机库包含 `3,598,600` 条 raw 样本，其中 `3,548,930` 条有效；`sync_runtime_state.projection_time_zone` 仍为 NULL。旧 `ProjectionWorker.prepareCalendarIfNeeded` 在唯一 writer transaction 中全表扫描，并为每条样本新建 `DateFormatter`。旧算法抽样 100,000 行耗时 `10.216s`，线性推算完整扫描约 `355s`；App 被终止时整个事务回滚，下次冷启动会再次重复。
- 修复把证据扫描移到 WAL 只读快照，使用 `Row.fetchCursor` 流式读取并复用一个 formatter；仅将去重后的日期集合在短 writer transaction 中发布，并在提交前复核 runtime state，避免并发重复初始化。真机副本完整扫描 3,548,930 行耗时 `5.980s`，期间不占用交互写锁。
- 新增并发回归在投影扫描被测试钩子暂停期间执行真实 `MealStore.save`，要求 1 秒内完成，然后检查餐次与时区状态都已持久化；聚焦 `9/9`、完整 `437/437` 均通过。
- 修复后 0.8.1（16）已签名并覆盖安装到原真机数据容器；锁屏下复制的数据库 `quick_check=ok`，仍有 `3,598,600` 条 raw、338 条餐次和 664 条 item，覆盖安装未造成数据丢失。设备因用户已入睡并锁定，SpringBoard 以 `Locked` 拒绝远程启动，所以真实点按重放仍为 `PENDING`。

### 冷启动真机证据

- 旧版 0.8.1（16）基线完成 20 次进程冷启动。20/20 首张截图已有有效卡片，无 skeleton、空白页或崩溃；截图完成时刻形成的可见上界为 p50 `929.508 ms`、p95 `1007.515 ms`、max `1065.356 ms`。基线没有 startup milestone，不能估造内部 snapshot 时间。原始分析：`/tmp/healthmanager-s13-baseline/baseline-run/analysis.json`。
- 候选版完成 20 个独立 startup session；`snapshotAvailable` p50 `783 ms`、p95 `815 ms`、max `833 ms`，database/environment/recovery ready p95 分别为 `96/154/206 ms`，`initialSnapshotError=0`。这组内部指标达到 p95 ≤ 1 秒目标。原始分析：`/tmp/healthmanager-s13-acceptance/startup-metrics-summary.json`。
- 候选版视觉采样 19/20 在首张截图已有卡片、20/20 无 skeleton；截图完成上界 p50 `1121.627 ms`、p95 `1545.257 ms`、max `3500.384 ms`。截图与前台激活本身约占 1 秒，无法用这组上界证明“实际卡片可见 p95 ≤ 1 秒”；该视觉门保持 `PENDING`。原始分析：`/tmp/healthmanager-s13-acceptance/candidate-run/analysis.json`。
- 最终签名二进制另外完成 20 次进程冷启动，20/20 launch 成功；launch 命令 p50 `801.293 ms`、p95 `871.789 ms`、max `981.654 ms`。19/20 的首张并发截图已经是完整卡片；第 1 轮截图经人工复核为主屏幕，截图发生在 App 前台激活前，不是 App 空白页。截图工具自身排队使可见上界 p95 达到 `2371.698 ms`，因此它不能用于证明实际卡片可见 p95 ≤ 1 秒；冷启动无空白/崩溃回归通过，严格视觉时钟门仍为 `PENDING`。证据：`/tmp/healthmanager-s13-acceptance/final-candidate-20/analysis.json`。

### 自动同步与 durable queue 真机证据

- 修复前，单次冷启动会使全部类型 generation 约增加 30，并遗留 8–9 个 pending；这是“App 正常打开但数据不更新，手动同步后才更新”的真实可复现机制之一。
- 最终候选在一次前台启动后 `pending=0`、全部 `requested_generation == completed_generation`；连续 3 次初验和最终签名二进制 20 次冷启动后仍为 `pending=0`。最终 jobs 857–876 全部 `succeeded`，每一类型 `requested_generation == completed_generation`；没有依赖手动同步。证据：`/tmp/healthmanager-s13-acceptance/fix3-foreground-state.json`、`/tmp/healthmanager-s13-acceptance/fix3-three-round-state.json`、`/tmp/healthmanager-s13-acceptance/final-candidate-20/final-db-summary.json`。
- 在未点击手动同步的情况下，候选自动导入 39 条真实 Apple Health 样本，覆盖 8 类；这证明自动 catch-up 可以工作。样本源时间早于本轮打开 App，无法据此计算“Apple Health 可读到 App 卡片可见”的 p95，也不替代 A/B/C 各 3 轮。证据：`/tmp/healthmanager-s13-acceptance/fix3-natural-ingestion-summary.json`。

### 升级与数据保全

- 安装前后数据库 `quick_check=ok`，v14 迁移成功；基线全部 3,598,537 个 raw UUID 均保留。最终 20 轮后共有 59 个真实新增 UUID，既有 UUID 的删除标志变化为 0。
- 28/28 anchors 非空；338 条饮食记录及其非空 `hk_sync_id`、664 条 meal item、药物计划/记录、367 天活动和身体日表、daily/weekly summary 均保留。
- HealthBridge dataset/epoch 摘要稳定，acknowledged sequence 从 455 单调推进到 476；最终有 2 个新 outbox batch 等待 Mac 回执，Bridge 未暂停。该 transport pending 不是 HealthKit acquisition pending。
- 证据：`/tmp/healthmanager-s13-preservation/postinstall-comparison.json`、`/tmp/healthmanager-s13-acceptance/fix3-data-preservation-set-comparison.json`、`/tmp/healthmanager-s13-acceptance/fix3-final-summary.json`、`/tmp/healthmanager-s13-acceptance/final-backup-fix-device-summary.json`、`/tmp/healthmanager-s13-acceptance/final-candidate-20/final-db-summary.json`。

### 备份与 Keychain

- 现有 iCloud 备份包的 `manifest.json` 仍是 2026-09-20 11:15:39 的 format 3 / App 0.8.1；`meal_items.jsonl` 和 `meal_records.jsonl` 已被更新，但 manifest 未原子更新。两文件声明/实际字节数分别为 `231751/235409` 与 `82672/83509`，SHA256 也不匹配，因此该保留副本当前不能作为已验证可恢复备份。
- 旧版和前一候选版各给过一次 40–45 秒后台导出机会，manifest 都没有更新。代码审计确认导出实现会逐个原地覆盖旧文件，后台中止足以制造这次不一致；现已改成 staging 完整生成后原子发布，并通过提交前中断故障注入。最终真机仍需在隔离目录中完成一次实际导出与导入，才能把该子门从 `PENDING` 改为 `PASS`。
- 升级覆盖后 backup bookmark 摘要和 HealthBridge dataset/epoch 均保持，说明既有 Keychain 数据没有因安装丢失；但 save/load/clear/reselect round-trip 会改变真实 bookmark，尚未执行。Simulator 的 `-34018` 也不能替代有签名真机结论。

### 仍需用户参与的真实设备门

- 场景 A：真实外部来源写入后前台自动追新 3 轮，并记录 Apple Health 可读到本地 raw/卡片可见的 p95；当前只有一次自然批量 catch-up，轮数与延迟证据不足。
- 场景 B：锁屏期间发生真实更新，解锁后自动收敛 3 轮；当前 `0/3`。
- 场景 C：有 pending 时让 BG task expiration/中断，再回前台自动续跑 3 轮；当前 `0/3`。
- 在隔离目录完成备份 bookmark save/restart/load/clear/reselect，并对可回滚副本执行成功恢复与取消/失败恢复门。

因此当前可以确认：冷启动本地 snapshot 路径达到内部 p95 815 ms；最终签名二进制 20/20 冷启动成功且 launch 命令 p95 871.789 ms；真实升级数据保全通过；本轮发现的 observer 全目录放大和 runner 丢 demand 缺陷在最终 20 轮后仍保持 `pending=0`。由于精确视觉 p95、A/B/C 3×3、备份完整导出和 Keychain/恢复 round-trip 尚未完成，S13 维持 `PENDING`，不能给整体 `PASS`。
