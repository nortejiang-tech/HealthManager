# STAGE-009 Item4-7 真机复核记录（2026-07-15）

> 用途：记录到目前为止的真机证据扫描与下一步执行边界。未执行项保持 INCOMPLETE，不替代真实验证。

## 当前判定

- 基线：分支 `codex/health-planning-20260713`、commit `2e3b038c4d5722d507874feaea90002fc2379e66`
- 结论：`item4~7` 仍为 **INCOMPLETE**。

### 已有证据扫描

扫描目录（按时间倒序）：

- `/tmp/healthmanager-stage009-item45-device-next-20260715-0508-attempt01b`
- `/tmp/healthmanager-stage009-item45-device-next-20260715-0508-attempt01`
- `/tmp/healthmanager-stage009-item45-device-20260715-0420-attempt04`
- `/tmp/healthmanager-stage009-item45-device-20260715-0420-attempt03`
- `/tmp/healthmanager-stage009-item45-device-20260715-041649-attempt02`
- `/tmp/healthmanager-stage009-item45-device-20260715-041605-attempt02`
- `/tmp/healthmanager-stage009-item45-device-20260715-041338-attempt01`

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

## 缺失项（当前无法闭环 PASS）

1. **Item4（照片生命周期）**
   - 没有与“导入/替换/取消/保存/删除”动作对应的 `before/after` 照片路径差分与时间戳日志。
   - 目录中虽有 `photo` 清单，但缺少“动作序列->DB 变更->文件变更”的因果链。

2. **Item5（VO / Dynamic Type / 44pt）**
   - 未看到 VoiceOver 读序、最大字号或 44pt 命中截图/录像。

3. **Item6（sleepAnalysis 真实性）**
   - 有 SQL 摘要（跨午夜样本与来源聚合），但缺少 5 个跨午夜窗口与 UI 对照截图。

4. **Item7（observer 增量）**
   - 有 sync_jobs 最终收敛样本，但缺少由“真实样本新增/删除”触发前后对照日志与截图。

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
