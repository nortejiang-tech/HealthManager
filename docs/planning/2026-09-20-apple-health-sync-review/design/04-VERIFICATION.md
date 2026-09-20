# 验证方案与命令合同

## V00：文档阶段已验证与未验证

2026-09-20 只读确认：Xcode 27.0（27A266a），Swift 6.4，iOS 26.5 Simulator；iPhone 17 UUID `6364DCEB-82DF-448C-91D9-2C19FD844AA8` 存在；XcodeGen `/opt/homebrew/bin/xcodegen` 存在；离线 `xcodebuild -list` 确认 HealthManager scheme 和 Unit/UI targets。GRDB package cache 和现有 resolved file 存在。没有运行本设计未来的测试、构建或部署。

旧文档写 Xcode26.6/112或258 tests 是历史快照，不能当当前事实。上轮331测试是当时hotfix记录，也不是本轮已运行结果。后续新增类型/测试名是 Proposed；激活阶段时先确认文件存在并通过编译。

## V01：预检与可审计基线

Planner或用户手动选择的云端执行者先运行只读检查：

```bash
cd /Users/nortepro/HealthManager
git rev-parse HEAD
git status --short
xcodebuild -version
xcrun simctl list devices available
xcodebuild -list -json -project HealthManager.xcodeproj -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates
```

目标/保护文件与 `BASELINE.json` 比较SHA256；新文件只允许原来不存在且列在白名单。相同HEAD但目标hash变更时不能自动继续套旧patch。仅记录路径与hash，不把健康数据或敏感配置内容塞进验收材料。

阶段需要新增文件时，Planner审查 `project.yml` 后允许固定XcodeGen命令更新ignored project。既有工程目录是生成产物，不直接编辑或删除。离线解析失败→环境未就绪，保留错误，由Planner预装依赖；Coder不删除Package.resolved、不换包版本、不隐式联网。

## V02：S01可直接使用的定向命令

完整命令同时保存在S01提示词及manifest，下面便于人阅读。原有测试文件承载新测试，不需要XcodeGen。

```bash
xcodebuild \
  -project /Users/nortepro/HealthManager/HealthManager.xcodeproj \
  -scheme HealthManager \
  -destination 'platform=iOS Simulator,id=6364DCEB-82DF-448C-91D9-2C19FD844AA8' \
  -clonedSourcePackagesDirPath /Users/nortepro/Library/Developer/Xcode/DerivedData/HealthManager-ggcivopbkrhyayfzwvojpwacksqd/SourcePackages \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates \
  -parallel-testing-enabled NO \
  -only-testing:HealthManagerTests/DashboardIndexMigrationTests \
  -only-testing:HealthManagerTests/DashboardNutritionEvidenceTests \
  test CODE_SIGNING_ALLOWED=NO -quiet
```

S01的红信号来自**实际loader访问已从合成fixture中移除的raw表**，不是编译失败、mock return、源码字符串匹配或在测试里复制SQL。生产改动完成后应得到日汇总卡片及正确nutrition evidence。仅fixture允许DROP TABLE；手机数据和诊断副本不可作为此测试目标。

云端手动Coder按相同命令先红后绿；EVO由Planner预先建立、运行并冻结红测试，再将生产目标与固定green verifier暴露给它。每次测试命令的最新结果必须全部通过才可请求review，历史红结果保留。不能要求EVO最终验证集合仍含一个必须失败的“红专用命令”。

本示例不固定resultBundlePath，Xcode会保存有唯一时间戳的默认xcresult；必须记录实际输出路径。若Planner希望固定路径，激活阶段时生成独占路径并同步JSON清单；不删除/复用旧xcresult掩盖失败。

## V03：必须覆盖的自动化矩阵

| ID | 生产调用路径/场景 | 断言 | 主要阶段 |
|---|---|---|---|
| R01 | DashboardLoader真实读取，无raw表fixture | 日汇总/营养卡片照常返回，无无用raw依赖 | S01 |
| R02 | 本地快照失败与旧快照已有 | 保留旧内容、显式错误，不发布空成功 | S02/S12 |
| R03 | A读取开始后A写入，第二observer到来 | 新版本最终导入，pending不丢，额外轮次有界 | S07 |
| R04 | 1000通知、同intent重复、未开始类型变化 | 合并集合且公平轮转，非1000全扫描 | S03/S07 |
| R05 | active/authReady/recoveryReady所有顺序 | 合法ready后补跑，恢复失败所有入口关闭 | S08A |
| R06 | locked查询错误再解锁 | defer后自动补跑，无28倍重试 | S04A/S08B |
| R07 | cancel-before-execute / cancel-after-execute | 没有取消后新execute；执行中查询stop并resume一次 | S04B |
| R08 | timeout/callback/cancel同刻、late/重复callback | 每个continuation最多resume一次，资源释放 | S04B |
| R09 | BG expiration与正常完成同刻 | setTaskCompleted最多一次且真实result | S08B |
| R10 | 有added、有deleted、仅deleted、多页2501条 | anchor页级前进，最后空页才drain | S06 |
| R11 | 页事务不同点抛错/进程重开 | raw/删除/anchor/dirty全或无，pending可续跑 | S05/S06 |
| R12 | nil初始anchor/损坏anchor/重复非进展页 | 有界首次采集；repairRequired不无限重置 | S06 |
| R13 | 90天前新样本/旧样本删除 | 对应历史日更新，删除前定位旧日期 | S09 |
| R14 | 跨午夜睡眠/跨日workout+activeEnergy | 扩大依赖日但不改变原业务口径 | S09 |
| R15 | DST23/25小时、时区改变、算法版本升级 | Calendar日区间正确，历史重建有界且可恢复 | S09 |
| R16 | 投影期间到来新dirty代次 | 旧计算不能清新pending，最终结果收敛 | S09 |
| R17 | 无变化及同值结果 | 0次投影内容写入、0个重复data tick | S09 |
| R18 | required projection失败/统计fallback | 不假报completed；旧值/fallback来源清楚 | S09/S12 |
| R19 | manual pass1错误/pass2零新增成功 | 最新类型状态成功，其他失败不被全清 | S10 |
| R20 | manual waiting期间observer | 不占writer，自动工作继续；重复ack安全 | S10 |
| R21 | backfill/manual/auto交错 | 唯一writer通道与anchor owner | S07/S10 |
| R22 | restore期间query晚回调/restore中断重开 | 不覆盖恢复值，marker/队列可恢复 | S10B |
| R23 | 只有备份日汇总无raw/局部raw未drain | 不被空聚合抹掉；actual deletion有证据才清字段 | S09/S10B |
| R24 | Bridge418批、411ack、7pending | metadata不读全部payload；校验/重放/保留期不变 | S11A |
| R25 | 首屏成功/失败/后台无页面 | 维护不挡首屏、不永远等待UI、不重复启动 | S11B |
| R26 | phase/read/project/deferred/failed组合 | 文案和job状态真实，缺失≠0，无假进度 | S12 |

fake必须注入真正生产模块边界。S03纯reducer通过只是组件证据；S07应替代上轮提取方法的probe，调用真实Engine/Runner。禁止用仅测试自己的fake证明同步已修复。

对于计时，功能单测优先assert调用次数、查询范围和事件先后，不用“必须小于1ms”做脆弱断言。容量测试（3.6M合成行）由Planner按需在隔离环境运行，不交给15分钟本地Coder。

## V04：独立软件验收

每阶段定向测试通过后，Planner在同一候选diff独立检查并复跑必需验证；代码未变且相关测试已完成后不无理由反复跑全套。

最终至少包括全量HealthManagerTests、相关UITests、Simulator build、HealthBridge完整package tests；模型/平台环境不足属于PENDING。建议命令基于V02移除 `-only-testing` 或改为 `-only-testing:HealthManagerTests`；结果记录测试数、失败数、跳过数、警告和真实xcresult。新增测试类不存在或命中0 tests视为验证无效。

```bash
swift test --package-path /Users/nortepro/HealthManager/HealthBridge --skip-update --disable-automatic-resolution
```

包需重新核对HealthBridge/Package.resolved及现有.build依赖状态；不能按上轮12tests硬编码期望数。生产代码签名、部署、提交与push不在这些验证命令中。

## V05：真实设备与性能验收

由Planner执行，需要手机解锁、真实外部来源写入或安装时单独满足操作门。测试不在用户健康库制造/删除虚假健康样本。已有真实记录可用于只读验证；写入相关测试使用隔离测试设备或用户明确选择的真实操作。

### 冷启动

- 同一真机、同一数据量、同一构建配置，基线与候选各≥20次冷启动。明确是进程冷启动还是存储缓存冷启动；不把warm foreground当cold launch。
- OS启动测量 + signpost +实际UI可见判据。分开记录 DB初始化/恢复、授权等待、snapshotAvailable、首批有效卡片可见、首次新数据可见。
- 记录每次样本与p50/p95/max（p95采用nearest-rank，n=20取第19个排序样本），不用总平均掩盖长尾；记录低电量/热状态/系统版本/Bridge开关。
- 初始目标：已有数据首批有效卡片p95≤1秒，且不依赖HK返回；若基线说明目标需校准，由Planner记录原因，不能由Coder自行放宽。
- 人工延迟HK 10秒/Bridge30秒的隔离测试下，本地卡片仍先展示；失败/无数据状态各有正确文案。

### 自动追新与恢复

- 真实来源已经写入Apple Health后，进前台/后台允许交付/解锁恢复都应最终更新；分别记录 source→HealthKit 和 HealthKit→本App延迟，前者不归App同步保证。
- 覆盖“同步中再来数据”“锁屏失败后解锁”“后台预算中断后前台恢复”，每个场景至少3轮；不靠手动同步按钮补救。
- 小批增量（例如≤100个样本）前台本地可见目标p95≤3秒，限定HealthKit正常可读、无初始回补。长历史积压单独报告吞吐和内存，不能混进常态SLA。
- 默认前台空闲检查可设置新鲜度阈值以减少重复全类型检查，但用户手动与pending类型必须强制满足请求；阈值若引入，额外测试不漏真实observer。
- Apple BG调度不保证每小时准时运行；模拟器也不证明后台HealthKit唤醒。真机没有观察到的门一律PENDING。

### 数据保全

比较升级/操作前后必要记录计数、UUID集合摘要、anchor存在性、饮食syncID/备份恢复、历史删除效果以及Bridge已确认序列，排除同期真实新增差异；不要把计数变化一律当丢失或一律解释成正常同步。

## V06：最终结果分类

- 组件PASS：单个阶段范围与软件合同已覆盖。
- 整体PASS：R01–R26相关自动化、真机首屏/恢复、数据保全全部有证据。
- PENDING：缺真机、计时或外部写入证据，代码可继续审查但不称完成。
- FAIL：确认存在回归/丢事件/错误数据/虚假成功，保留diff按写入分支处理。

Coder结果只能是待审，不自行激活下一阶段；最终报告分别给首屏、自动同步、历史投影、Bridge和备份恢复五项状态。
