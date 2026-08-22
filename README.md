# HealthManager

iOS 健康数据管理 App。聚合 Apple Health 中各来源（Garmin / 米家 / Apple Watch / 华为 / 手动）的体重、活动、心血管、睡眠、饮食等数据，做自动同步、数据质量对账、日报/周报；可选接入 OpenAI-compatible LLM 做摘要评注和餐食图片营养估算。

V1 已交付：详见 `WORKLOG.md` 末尾「V1 交付摘要」节。

## 前置条件

| 工具 | 版本 | 备注 |
|---|---|---|
| macOS | 14+ | |
| Xcode | 15+（含 iOS 17+ SDK） | iOS 26.5 simulator runtime 也可，但需要在 Xcode → Settings → Platforms 下载 |
| xcodegen | 任意近期版本 | `brew install xcodegen`。改 `project.yml` 或新增源文件后需要重跑 |

默认本地优先。GRDB.swift 6.29+ 通过 SwiftPM 自动拉取；AI 摘要 / 饮食视觉估算只有在用户手动配置 API Key 后才会访问对应 LLM 服务。

## 快速开始

```bash
# 1. 解压本压缩包并进入目录
cd HealthManager

# 2.（可选）重新生成 Xcode 工程（压缩包内已带，正常无需）
xcodegen generate

# 3. 用 Xcode 打开
open HealthManager.xcodeproj

# 4. 在 Xcode 里：
#    - 选一台 iOS 17+ 真机 或 simulator
#    - 设置 Signing Team（Settings 页可看到 Bundle ID = com.norte.HealthManager；
#      自动签名需要你自己的 Apple ID）
#    - Run（⌘R）
```

首次运行会进入 onboarding 授权页，授权全部读权限后进入主界面。

## 一次跑通核心链路（首次安装后）

1. **Onboarding** → 点「授权读取健康数据」→ 系统弹出 HealthKit 权限页 → 全选 Allow
2. **同步中心** → 选「过去 30 天」→ 点「开始回补」→ 等回补完成（首次约几秒到几十秒，取决于历史数据量）
3. **同步中心** → 点「立即对账（7 天）」
4. **仪表盘** → 三色质量徽标出现（完整度 / 新鲜度 / 冲突度）；告警红点反映 `missing_data_alerts` 数
5. **来源** tab → 看每个数据源最近 N 天的活跃天数
6. **仪表盘 → 数据质量 / 同步明细 / 报告 → 总结** → 一键生成日报 + 周报（本地确定性聚合；配置 LLM 后可生成 AI 评注）

之后 **HKObserverQuery** 会在 Apple Health 收到外部 App 写入时秒级自动触发增量同步；**BGAppRefresh** ≥1h 兜底；**BGProcessing** ≥6h 自动对账。

## 项目结构

```
HealthManager/
├── App/                 # @main + AppEnvironment + RootView + Info.plist + entitlements
├── Core/
│   ├── Database/        # GRDB DatabaseManager + Migrations + Models（14 张表）
│   ├── HealthKit/       # HealthKitManager + TypeCatalog + SampleMapper
│   ├── Sync/            # Backfill / Incremental / Manual / Observer / BGScheduler / StateMachine
│   ├── Aggregate/       # DailyAggregator + 活动能量/手动活动估算
│   ├── Reconcile/       # DailyReconciler（R-001 三分数 + missing_data_alerts）
│   ├── Summary/         # SummaryGenerator（日报/周报，本地确定性）
│   ├── LLM/             # OpenAI-compatible config/client + 饮食视觉营养估算
│   └── Logging/         # AppLogger
├── UI/
│   ├── Onboarding/      # 授权页
│   ├── Dashboard/       # 仪表盘
│   ├── Diet/            # 饮食
│   ├── Medication/      # 用药
│   ├── Sources/         # 来源归因
│   ├── Summary/         # 日/周报
│   ├── Workouts/        # 运动记录 + 手动活动补录
│   ├── Alerts/          # 告警面板
│   ├── Settings/        # 设置 / 隐私
│   └── SyncCenter/      # 同步中心
├── Resources/
│   └── Assets.xcassets  # AppIcon / AccentColor 占位
├── project.yml          # xcodegen 配置
├── WORKLOG.md           # 7 轮交付滚动记录 + V1 总结
├── NEXT_TASK.md         # v2 蓝图
└── README.md            # 你正在读
```

## 编译验证

### 方式 A：完整 `xcodebuild`（推荐，需 simulator runtime）

```bash
rm -rf /tmp/HMbuild
xcodebuild -target HealthManager \
  -project HealthManager.xcodeproj \
  -configuration Debug -sdk iphonesimulator \
  BUILD_DIR=/tmp/HMbuild/Products BUILD_ROOT=/tmp/HMbuild/Build \
  OBJROOT=/tmp/HMbuild/Intermediates SYMROOT=/tmp/HMbuild/Products \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES SKIP_INSTALL=YES
# 期望：** BUILD SUCCEEDED **
```

### 方式 B：独立 `swiftc -typecheck`（不依赖 simulator runtime，仅校验 Swift 正确性）

需要先跑一次方式 A 让 GRDB 模块产物落到 `/tmp/HMbuild`，然后：

```bash
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
GRDB_MODULE_DIR="/tmp/HMbuild/Products/Debug-iphonesimulator"
CSQLITE_MAP="$HOME/Library/Developer/Xcode/DerivedData/HealthManager-*/SourcePackages/checkouts/GRDB.swift/Sources/CSQLite/module.modulemap"
find App Core UI -name "*.swift" -print0 | xargs -0 swiftc -typecheck \
  -target arm64-apple-ios17.0-simulator -sdk "$SDK" \
  -I "$GRDB_MODULE_DIR" -Xcc -fmodule-map-file="$CSQLITE_MAP"
# 期望：0 errors / 0 warnings
```

## 关键技术点（看代码前先了解）

- **HealthKit 不预过滤来源**（PRD §4.1）：`allReadSampleTypes` 全集订阅；归因只在采集后用 `SourceAttribution` 标签化，不删样本
- **去重**：`health_samples_raw.sample_uuid` 是 PK，`INSERT OR IGNORE` 兜重复；v7/v8 起再按「规范读数」`(hk_type, start_at, ROUND(value,3), unit)` 加部分唯一索引（`WHERE is_deleted = 0`），两个 App 各自写入的**同一物理读数**（含 float 表示噪声，如 82.84999847 vs 82.85）也只保留一条（保留来源优先级更高者）
- **删除**：HK 删的 UUID → `is_deleted = 1`（软删，不物理删除）
- **Anchor 持久化**：`HKQueryAnchor` 走 `NSKeyedArchiver.archivedData(requiringSecureCoding: true)` 存 `sync_anchors.anchor_data` BLOB
- **状态机**：`SyncStateMachine` 是 PRD §5 状态机；backfill / incremental / manual 三条路径都通过它
- **手动同步两阶段**：先拉一遍 → `await promptForExternalSync()`（`CheckedContinuation`）→ `scenePhase=.active` 自动 ack 后再拉一遍
- **对账三分数**：completeness / freshness / conflict，定义在 `DailyReconciler` 顶部 `Config`
- **热量缺口口径**：`DailyAggregator` 写入 `activity_metrics_daily.active_energy_kcal` 时，会以 Active Energy 样本为基线，再把 `HKWorkout.totalEnergyBurned` 中未被覆盖的运动消耗补入，避免 Garmin/手动运动漏算，也避免同一段训练重复计入
- **永远不要 in-place 改已应用的迁移**：见 `Core/Database/Migrations.swift` 顶部注释；要加表/列就新增 `v2_*` 迁移

## 隐私

- 所有数据存本地 SQLite（`Application Support/HealthManager/health.sqlite`，WAL）
- 默认不向云端上传任何健康数据；用户配置 LLM 后，只会上传聚合摘要文本和用户主动选择的餐食图片
- 数据备份（可选）：用户可在「设置 → 数据备份」选择一个文件夹（如 iCloud Drive），App 会把解析后数据的明文 JSONL 备份包写入该文件夹，退到后台时自动导出；App 自身不上传。重装后可在引导页/设置页从备份包恢复（只补缺、不覆盖）。备份包不包含照片与原始样本，格式契约见 `docs/export-schema.md` 与 ADR-003
- 不接入第三方分析 / 崩溃收集
- HealthKit 数据本身由 Apple 系统级加密
- 卸载 App = 清除所有本地数据（除非此前配置过数据备份）

## 后续开发

- 改了 `project.yml`、新加源代码目录 → 跑 `xcodegen generate`
- 改了已应用迁移 → 不允许；写新的 `v2_*` migration
- v2 候选见 `NEXT_TASK.md`

## 提交历史

```
196e2de Round 7: 收尾（Settings + Reconcile BG 排程 + V1 交付）
eb9b434 Round 5+6: 数据质量 UI + 告警/来源 + 饮食/用药 + 日报周报
0e34b6c Round 4: 每日对账 R-001
a6a9fae Round 3: 手动一键同步 F-002
147759a Round 2: 自动增量同步 F-001
6256520 Round 1: 工程骨架 + HealthKit 授权 + 12 表 Schema + 30 天回补骨架
```
