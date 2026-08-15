# HealthManager 备份包字段字典（export schema）

> 契约版本：formatVersion 1（对应 `BackupManifest.currentFormatVersion`）
> 决策记录：`docs/adr/ADR-003-backup-package-export-restore.md`
> 本文件是备份包与外部读取方（例如电脑上的 agent）之间的稳定契约。

## 通用规则

1. **格式只增不改**：字段名一经发布永不改名、不删除语义；未来只追加字段。外部读取方应忽略不认识的字段。
2. **值类型**：整数 → JSON number（不区分 32/64 位）；小数 → JSON number；文本 → string；布尔 → true/false；NULL → null。
3. **时间**：一律为 Unix 秒（整数，`start_at` / `eaten_at` / `created_at` / `computed_at` 等）。
4. **主键/唯一键**：导入侧按数据库主键与唯一索引执行 `INSERT OR IGNORE`——恢复只补缺、不覆盖，可重复执行。
5. **文件与行序**：每行一条 JSON，键按字母序输出；行按主键升序。行序不是契约，读取方不得依赖。
6. **manifest.json**：`{ formatVersion, appVersion, exportedAt, files: [{ file, recordCount, bytes, sha256 }] }`。每个数据文件的 SHA-256 必须与 manifest 一致才导入。

## 表清单

11 张解析后数据表 + 1 个配置快照。**不包含**：`health_samples_raw`（原始样本，由 Apple 健康同步）、`sync_jobs`、`backfill_report`、`sync_anchors`（运维数据）、照片文件。

| 文件 | 表 | 主键 / 唯一键 | 导入冲突策略 |
|---|---|---|---|
| meal_records.jsonl | meal_records | id | 只补缺（INSERT OR IGNORE） |
| meal_items.jsonl | meal_items | id；(meal_id, sort_order) 唯一 | 只补缺 |
| medication_plans.jsonl | medication_plans | id | 只补缺 |
| medication_logs.jsonl | medication_logs | id | 只补缺 |
| activity_metrics_daily.jsonl | activity_metrics_daily | date | **覆盖**（INSERT OR REPLACE） |
| body_metrics_daily.jsonl | body_metrics_daily | date | **覆盖** |
| source_coverage_daily.jsonl | source_coverage_daily | (date, source_bundle_id) | **覆盖** |
| data_quality_daily.jsonl | data_quality_daily | date | **覆盖** |
| missing_data_alerts.jsonl | missing_data_alerts | id | **覆盖** |
| daily_summaries.jsonl | daily_summaries | date | 只补缺 |
| weekly_summaries.jsonl | weekly_summaries | week_start_date | 只补缺 |
| settings.json | （App 配置快照） | — | 整体应用（见下） |

**为什么投影表用「覆盖」**：这五张表是由原始样本派生的数据（非用户创作）。重装后 App 在无原始样本时的启动补算可能先写入空投影行，若恢复只补缺，这些空行会挡住备份里的真实值。覆盖语义保证备份值生效；之后同步回补原始样本时，投影会按正常管线重新计算。

### settings.json（App 配置快照）

字段：对账阈值（completenessThreshold / conflictMinSources / consecutiveMissingForCritical / defaultWindowDays）、仪表盘可见卡片 rawValue 列表、AI 非敏感配置（enabled / baseURL / visionBaseURL / textModel / visionModel / customPresets / profiles / activeProfileName）。

- **不含 API Key**：密钥在 Keychain，永远不进明文备份包。
- 应用规则：阈值与卡片布局无条件应用；AI 配置仅在本地端点/模型字段为空时应用（不覆盖重装后新设的 AI 配置）。
- 备份位置书签存 Keychain（卸载重装后仍可读），不进备份包。

## 逐表字段

### meal_records.jsonl

| 字段 | 类型 | 含义 |
|---|---|---|
| id | int | 本地主键 |
| meal_type | string | breakfast / lunch / dinner / snack |
| eaten_at | int | 进餐时间（Unix 秒） |
| calories_kcal | number\|null | 热量快照；null = 未知 |
| protein_g / fat_g / carbs_g | number\|null | 三大营养；null = 未知 |
| photo_path | string\|null | JSON 数组字符串（照片文件名）。恢复后文件可能不存在（照片不随包导出），UI 显示「照片已丢失」 |
| notes | string\|null | 备注 |
| hk_sync_id | string\|null | 写回 Apple 健康的关联 id |
| created_at | int | 创建时间 |

### meal_items.jsonl

| 字段 | 类型 | 含义 |
|---|---|---|
| id | int | 主键 |
| meal_id | int | 所属餐次（外键 meal_records.id） |
| sort_order | int | 餐内顺序（0 起） |
| name | string | 分项名称快照 |
| grams | number\|null | 克数；null = 未知（未知不是 0） |
| preparation_state | string | unknown / raw / cooked |
| calories_kcal / protein_g / fat_g / carbs_g | number\|null | 营养快照 |
| provenance_kind | string | manual / ai_estimate / nutrition_database / nutrition_label |
| provenance_ref | string\|null | 来源条目/模型引用 |
| provenance_version | string\|null | 数据集/模型版本快照 |
| confidence | string\|null | low / medium / high；无证据为 null |
| is_user_edited | bool | 用户是否修订过机器候选 |
| created_at / updated_at | int | Unix 秒 |

### medication_plans.jsonl

id · name · dosage_mg · frequency（weekly/biweekly/custom）· schedule_json · start_date · end_date · reminder_enabled（bool）· notes · created_at

### medication_logs.jsonl

id · plan_id（外键）· scheduled_at · action（taken/skipped/deferred）· action_at（null=未记录）· dosage_mg · side_effects · notes · created_at

### activity_metrics_daily.jsonl

date（`yyyy-MM-dd`，本地时区）· step_count · active_energy_kcal · basal_energy_kcal · distance_m · exercise_minutes · stand_minutes · flights_climbed · resting_hr_bpm · avg_hr_bpm · hrv_ms · vo2_max · sleep_seconds · sleep_efficiency · sources_json · computed_at

### body_metrics_daily.jsonl

date · weight_kg · body_fat_pct · bmi · lean_mass_kg · height_m · basal_energy_kcal · visceral_fat_level · muscle_mass_kg · water_pct · protein_pct · sources_json · computed_at

### source_coverage_daily.jsonl

date · source_bundle_id · source_name · sample_count · hk_types_json · last_seen_at

### data_quality_daily.jsonl

date · completeness_score · freshness_score · conflict_score · missing_metrics_json · computed_at

### missing_data_alerts.jsonl

id · date · metric · severity（info/warning/critical）· message · acknowledged（bool）· created_at

### daily_summaries.jsonl

date · summary_text · key_findings_json · quality_score · generated_at

### weekly_summaries.jsonl

week_start_date · summary_text · findings_json · quality_score · generated_at

## 版本演进

- **formatVersion +1 的时机**：新增表文件、或对既有文件新增字段（字段只增不改，因此读取方永远向后兼容）。
- **导入侧规则**：formatVersion 高于 App 支持范围 → 拒绝并提示升级 App；未知文件忽略；未知字段忽略。
- **迁移链**：未来若必须改语义，写新字段（如 `calories_kcal_v2`）而非改旧字段。
