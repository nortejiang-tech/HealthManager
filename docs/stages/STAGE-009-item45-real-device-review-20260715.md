# STAGE-009 Item4-7 真机复核记录（2026-07-15）

> 用途：记录 STAGE-009 item4-7 的真机证据与严格判定。未执行项保持 INCOMPLETE，不替代真实验证。

## 当前判定

- 基线：分支 `codex/health-planning-20260713`、commit `7c5e561`（本轮验收修复后工作树另有 `UI/More/MoreView.swift` 变更）。
- 结论：`item4=PASS`；`item5=INCOMPLETE`（Dynamic Type 审计 PASS，但未执行 VoiceOver 录屏/44pt 专项）；`item6=INCOMPLETE`（已有 5 个跨午夜窗口与睡眠详情页截图，但尚未完成逐窗口来源/阶段对照）；`item7=INCOMPLETE`（未完成 Health App 外部样本新增/删除触发）。

### 本轮真机执行结果（2026-07-15）

设备：`NortePro的iPhone` / iPhone Air / iOS 26.5.2 (23F84)，UDID `00008150-001204800152401C`。

#### Item4：照片生命周期 — PASS

- 相机全生命周期真机 UI：`/tmp/healthmanager-stage009-item4-camera-20260715.xcresult`，1/1 passed。覆盖拍照保存、再次拍照后取消、移除已保存照片、保存并删除一次性餐次。
- PhotosPicker 全生命周期真机 UI：`/tmp/healthmanager-stage009-item4-picker-20260715.xcresult`，1/1 passed。覆盖相册选择保存、再次选择后取消、移除已保存照片、删除一次性餐次。
- 清理后的安装容器快照：`/tmp/healthmanager-stage009-item45-device-20260715-attempt09`。
- `reports/item4-diff-summary.txt` 机器差分：照片文件 `133 -> 133`（delta 0）、`meal_records.photo_path` 引用 `63 -> 63`（delta 0）、餐次 `114 -> 114`（delta 0）、一次性 marker `0`、`PRAGMA integrity_check=ok`。
- 该结论只覆盖本轮动作创建的临时对象；没有修改用户既有餐次。

#### Item5：Dynamic Type / 无障碍 — INCOMPLETE

- 最大 Dynamic Type + hit region / sufficient description / dynamic type / text clipped 审计：`/tmp/healthmanager-stage009-item5-ax-fixed2-20260715.xcresult`，1/1 passed；截图导出目录 `/tmp/healthmanager-stage009-item5-attachments`。
- 审计曾真实发现“数据质量”列表项文本裁切；已将 More 列表标签改为可垂直扩展的自定义行布局并复跑通过。该修复位于 `UI/More/MoreView.swift`。
- 仍未执行 VoiceOver 开关后的读序/口述证据，也未单独录制 44pt 命中区与 sheet 可用性，因此不能把 item5 标成 PASS。

#### Item6：睡眠跨午夜与来源 — INCOMPLETE

- 真机睡眠详情 UI：`/tmp/healthmanager-stage009-item6-sleep-20260715.xcresult`，1/1 passed；截图导出目录 `/tmp/healthmanager-stage009-item6-attachments`。截图显示睡眠周视图、7 月 8 日—7 月 15 日区间、平均 5.1 小时及柱状图。
- 同一轮清理后 DB 快照的 5 个跨午夜窗口见 `/tmp/healthmanager-stage009-item45-device-20260715-attempt09/reports/item6-cross-midnight-windows.txt`，包含 2026-07-13、07-09、07-03、06-28 等跨午夜样本；总 sleepAnalysis 行数 16,897。
- 新增逐窗口与汇总映射报告 `/tmp/healthmanager-stage009-item45-device-20260715-attempt09/reports/item6-window-ui-crosscheck.csv`：按 `start_at` 归属日连接 `activity_metrics_daily`，明确区分 `inBed` / `asleepDeep` / `asleepREM` / `asleepCore`，并核对周视图 `平均 5.1h / 最高 6.0h / 最低 3.6h` 与 DB 的 `5.12h / 6.04h / 3.58h`（显示层四舍五入一致）。
- 当前已证明跨午夜归属、inBed 不计入 Asleep 汇总、来源和阶段字段可解释；但周视图只覆盖最近 7 天，5 个抽检窗口中有 3 个早于该 UI 区间，尚未完成“5 个窗口全部在 UI 中逐项可见”的同屏对照，保留 INCOMPLETE。

#### Item7：后台 observer / 增量同步 — INCOMPLETE

- 本轮快照的 `active_sync_jobs=0`、`failed_sync_jobs=249`，并保留了完整 DB/WAL/SHM；但没有在 Health App 中新增/删除真实样本后，记录 observer 触发前后 job 与 backfill 的因果链。
- 追加的真实设备 probe 因本机 macOS 当前锁屏导致登录钥匙串不可用，Xcode 在安装测试前以 `errSecInternalComponent` 失败；未产生 HealthKit marker，也未篡改设备数据。故不能把已有的启动/手动同步收敛结果外推为真实 observer PASS。

### 已有证据扫描

扫描目录（按时间倒序）：

- `/tmp/healthmanager-stage009-item45-device-next-20260715-0508-attempt01b`
- `/tmp/healthmanager-stage009-item45-device-next-20260715-0508-attempt01`
- `/tmp/healthmanager-stage009-item45-device-20260715-0420-attempt04`
- `/tmp/healthmanager-stage009-item45-device-20260715-0420-attempt03`
- `/tmp/healthmanager-stage009-item45-device-20260715-041649-attempt02`
- `/tmp/healthmanager-stage009-item45-device-20260715-041605-attempt02`
- `/tmp/healthmanager-stage009-item45-device-20260715-041338-attempt01`
- `/tmp/healthmanager-stage009-item45-device-live-20260715-043448`（当前在线设备快照，设备 `NortePro的iPhone`, iOS 26.5.2, 已安装 `com.norte.HealthManager` v0.2.5 build 7）

### 2026-07-15 标准化快照收口（机器可复用）

为便于下一轮复核，新增一轮标准化导出已收口到：

- `/tmp/healthmanager-stage009-item45-device-continual-20260715-043014`

其中包含：

- `reports/db-audit.txt`（完整 PRAGMA + 表计数）
- `reports/photo-paths.csv`（基于 `meal_type` 的当前 schema）
- `reports/photo-paths-and-db-orphan-candidates.txt`
- `reports/photo-path-components.csv`
- `reports/photo-paths-summary.txt`
- `reports/photo-files.txt`
- `reports/sleep-cross-midnight.csv`
- `reports/sleep-cross-midnight-summary.txt`
- `reports/sync-jobs-final.txt`

补充现场快照已从当前设备直接拉取（`00008150-001204800152401C`）并在上述目录生成 `reports`：

- `reports/live-db-audit.txt`（`integrity_check=ok`, FK 无异常）
- `reports/photo-paths.csv`
- `reports/photo-files.txt`
- `reports/sync-active.txt`（`0`）
- `reports/device-list.txt`
- `reports/device-apps.txt`（当前 App 明细：`com.norte.HealthManager` v0.2.5 build 7）

## 关键可核对数字

在 `...-0508-attempt01b` 中可复用的机器可读输出：

- `meal_records_count = 114`
- `meal_records_with_photo_ref = 63`
- `mealphotos_files = 133`
- `unreferenced_files = 14`
- `active_sync_jobs = 0`
- `failed_sync_jobs = 249`
- `cross_midnight_rows = 273`
- `source_bundle_id` 来源去重数 = 5（com.garmin.connect.mobile、com.apple.health.DB4E..., HM.wristband、com.apple.health.47..., com.xiaomi.miwatch.pro）
- `/tmp/...-043014/reports/photo-paths-summary.txt` 显示：
  - `mealphotos_files=133`
  - `meal_records_photo_path_rows=63`
  - `unreferenced_files=0`
  - `missing_reference_components=0`
- `/tmp/...-043014/reports/sync-jobs-final.txt` 显示最新 `active_sync_jobs=1`（已转到已完成序列），`total_jobs=1309`，其中 `succeeded_jobs=1060`、`failed_jobs=249`。

在 `...-live-20260715-043448` 中新增基线：

- `meal_records_count=114`
- `meal_items_count=0`
- `meal_records_with_photo_ref=63`
- `mealphotos_files=133`
- `active_sync_jobs=0`
- `failed_sync_jobs=249`
- `total_jobs=1316`
- `active_backfill_reports=0`
- `failed_backfill_reports=0`
- `sleep_cross_midnight_rows=0`（该次 SQL 聚焦 `HKCategoryTypeIdentifierSleepAnalysis`）

## 尚未闭环的项目

- **Item5** 还缺 VoiceOver 读序、44pt 命中区和 sheet 可用性专项证据。
- **Item6** 还缺 5 个跨午夜窗口的逐窗口来源/状态/阶段与 UI 对照。
- **Item7** 还缺 Health App 外部样本变化触发 observer 的前后证据。

## 下一步行动（请按此执行）

- 按 `docs/coder-prompts/STAGE-009-item4-7-real-device-checklist.md` 开一轮 **标准化真机回归**。
- 每项仅在三要素齐备时允许 PASS：
  - 真实动作序列（人工操作）
  - 关键 DB / 文件差分
  - UI 证据（截图/录像）与时间戳标注
- 回传后我只基于 Coder 的原始证据做最终 PASS/FAIL/INCOMPLETE 判定与发布门决策。

## 交接说明（给 Coder 下一个会话）

- 下一个会话请以 `docs/coder-prompts/STAGE-009-item4-7-real-device-checklist.md` 为唯一输入。
- 在执行时要求每项输出“动作前后对照”证据（建议至少 5 分钟内固定同一测试餐次）：
  - item4：操作动作序列、`meal_records` `photo_path`、`MealPhotos` 文件清单差分与时间戳。
  - item5：VO 读序关键控件名与 44pt/最大字号可点截图。
  - item6：至少 5 个跨午夜窗口的数据库行与 UI 对照时间戳。
  - item7：触发前后 `sync_jobs` 收敛过程与 `backfill_report` 核对日志（含手动 sync 一次）。
