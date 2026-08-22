import Foundation
import GRDB

/// GRDB migrations. **Never** edit an applied migration in-place; add a new one.
enum Migrations {

    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // MARK: v1 — initial schema (12 PRD tables + 2 auxiliary)

        migrator.registerMigration("v1_initial_schema") { db in

            // 1. sync_jobs — every sync attempt, success or failure
            try db.create(table: "sync_jobs") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("job_type", .text).notNull()          // backfill | incremental | manual | reconcile
                t.column("state", .text).notNull()             // pending | running | succeeded | failed
                t.column("trigger", .text)                     // user | timer | bg_task | observer
                t.column("started_at", .integer).notNull()
                t.column("ended_at", .integer)
                t.column("error_code", .text)
                t.column("error_message", .text)
                t.column("stats_json", .text)                  // counts per hk_type
                t.column("attempt", .integer).notNull().defaults(to: 1)
            }
            try db.create(index: "idx_sync_jobs_started_at", on: "sync_jobs", columns: ["started_at"])
            try db.create(index: "idx_sync_jobs_type_state", on: "sync_jobs", columns: ["job_type", "state"])

            // 2. health_samples_raw — every sample we've ever ingested, append-only-ish
            try db.create(table: "health_samples_raw") { t in
                t.column("sample_uuid", .text).primaryKey()    // HK uuid guarantees uniqueness
                t.column("hk_type", .text).notNull()           // identifier string e.g. HKQuantityTypeIdentifierBodyMass
                t.column("kind", .text).notNull()              // quantity | category | workout
                t.column("value", .double).notNull()
                t.column("unit", .text).notNull()
                t.column("start_at", .integer).notNull()
                t.column("end_at", .integer).notNull()
                t.column("source_name", .text)
                t.column("source_bundle_id", .text)
                t.column("device_name", .text)
                t.column("device_model", .text)
                t.column("ingested_at", .integer).notNull()
                t.column("is_deleted", .boolean).notNull().defaults(to: false)
                t.column("extra_json", .text)
            }
            try db.create(index: "idx_raw_hk_type_start", on: "health_samples_raw", columns: ["hk_type", "start_at"])
            try db.create(index: "idx_raw_source", on: "health_samples_raw", columns: ["source_bundle_id"])
            try db.create(index: "idx_raw_start", on: "health_samples_raw", columns: ["start_at"])

            // 3. body_metrics_daily — derived per-day rollup for weight/body-composition pane
            try db.create(table: "body_metrics_daily") { t in
                t.column("date", .text).primaryKey()           // ISO-8601 yyyy-MM-dd in local tz
                t.column("weight_kg", .double)
                t.column("body_fat_pct", .double)
                t.column("bmi", .double)
                t.column("lean_mass_kg", .double)
                t.column("height_m", .double)
                t.column("basal_energy_kcal", .double)
                t.column("visceral_fat_level", .double)        // manual fallback per PRD §4.2
                t.column("muscle_mass_kg", .double)            // manual / extra_json projection
                t.column("water_pct", .double)
                t.column("protein_pct", .double)
                t.column("sources_json", .text)                // attribution snapshot per metric
                t.column("computed_at", .integer).notNull()
            }

            // 4. activity_metrics_daily
            try db.create(table: "activity_metrics_daily") { t in
                t.column("date", .text).primaryKey()
                t.column("step_count", .integer)
                t.column("active_energy_kcal", .double)
                t.column("basal_energy_kcal", .double)
                t.column("distance_m", .double)
                t.column("exercise_minutes", .double)
                t.column("stand_minutes", .double)
                t.column("flights_climbed", .integer)
                t.column("resting_hr_bpm", .double)
                t.column("avg_hr_bpm", .double)
                t.column("hrv_ms", .double)
                t.column("vo2_max", .double)
                t.column("sleep_seconds", .integer)
                t.column("sleep_efficiency", .double)
                t.column("sources_json", .text)
                t.column("computed_at", .integer).notNull()
            }

            // 5. meal_records
            try db.create(table: "meal_records") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meal_type", .text).notNull()         // breakfast | lunch | dinner | snack
                t.column("eaten_at", .integer).notNull()
                t.column("calories_kcal", .double)
                t.column("protein_g", .double)
                t.column("fat_g", .double)
                t.column("carbs_g", .double)
                t.column("photo_path", .text)
                t.column("notes", .text)
                t.column("created_at", .integer).notNull()
            }
            try db.create(index: "idx_meal_eaten_at", on: "meal_records", columns: ["eaten_at"])

            // 6. medication_plans — tirzepatide / general
            try db.create(table: "medication_plans") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("dosage_mg", .double)
                t.column("frequency", .text)                   // weekly | biweekly | custom
                t.column("schedule_json", .text)               // reminders, weekday, time
                t.column("start_date", .text)
                t.column("end_date", .text)
                t.column("reminder_enabled", .boolean).notNull().defaults(to: true)
                t.column("notes", .text)
                t.column("created_at", .integer).notNull()
            }

            // 7. medication_logs
            try db.create(table: "medication_logs") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("plan_id", .integer).references("medication_plans", onDelete: .cascade)
                t.column("scheduled_at", .integer).notNull()
                t.column("action", .text).notNull()            // taken | skipped | deferred
                t.column("action_at", .integer)
                t.column("dosage_mg", .double)
                t.column("side_effects", .text)
                t.column("notes", .text)
                t.column("created_at", .integer).notNull()
            }
            try db.create(index: "idx_med_log_plan_time", on: "medication_logs", columns: ["plan_id", "scheduled_at"])

            // 8. daily_summaries
            try db.create(table: "daily_summaries") { t in
                t.column("date", .text).primaryKey()
                t.column("summary_text", .text)
                t.column("key_findings_json", .text)
                t.column("quality_score", .double)
                t.column("generated_at", .integer).notNull()
            }

            // 9. weekly_summaries
            try db.create(table: "weekly_summaries") { t in
                t.column("week_start_date", .text).primaryKey()
                t.column("summary_text", .text)
                t.column("findings_json", .text)
                t.column("quality_score", .double)
                t.column("generated_at", .integer).notNull()
            }

            // 10. source_coverage_daily — for attribution dashboard
            try db.create(table: "source_coverage_daily") { t in
                t.column("date", .text).notNull()
                t.column("source_bundle_id", .text).notNull()
                t.column("source_name", .text)
                t.column("sample_count", .integer).notNull().defaults(to: 0)
                t.column("hk_types_json", .text)               // map: hk_type -> count
                t.column("last_seen_at", .integer)
                t.primaryKey(["date", "source_bundle_id"])
            }

            // 11. data_quality_daily
            try db.create(table: "data_quality_daily") { t in
                t.column("date", .text).primaryKey()
                t.column("completeness_score", .double)
                t.column("freshness_score", .double)
                t.column("conflict_score", .double)
                t.column("missing_metrics_json", .text)
                t.column("computed_at", .integer).notNull()
            }

            // 12. backfill_report — F-001A output
            try db.create(table: "backfill_report") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("job_id", .integer).references("sync_jobs", onDelete: .setNull)
                t.column("started_at", .integer).notNull()
                t.column("ended_at", .integer)
                t.column("requested_days", .integer).notNull()
                t.column("hk_type", .text).notNull()
                t.column("sample_count", .integer).notNull().defaults(to: 0)
                t.column("missing", .boolean).notNull().defaults(to: false)
                t.column("status", .text).notNull()            // running | succeeded | failed | skipped
                t.column("error_message", .text)
                t.column("coverage_summary_json", .text)
                t.column("created_at", .integer).notNull()
            }
            try db.create(index: "idx_backfill_job_type", on: "backfill_report", columns: ["job_id", "hk_type"])

            // --- auxiliary tables (needed for incremental + alerts) ---

            // sync_anchors — per-hk_type HKQueryAnchor blob for incremental queries
            try db.create(table: "sync_anchors") { t in
                t.column("hk_type", .text).primaryKey()
                t.column("anchor_data", .blob).notNull()
                t.column("updated_at", .integer).notNull()
            }

            // missing_data_alerts — R-001 缺失告警
            try db.create(table: "missing_data_alerts") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("date", .text).notNull()
                t.column("metric", .text).notNull()
                t.column("severity", .text).notNull()          // info | warning | critical
                t.column("message", .text)
                t.column("acknowledged", .boolean).notNull().defaults(to: false)
                t.column("created_at", .integer).notNull()
            }
            try db.create(index: "idx_alert_date_metric", on: "missing_data_alerts", columns: ["date", "metric"])
        }

        // MARK: v2 — denormalize SourceAttribution.Origin onto raw rows
        //
        // Round 9 / v2: SourcesView previously classified bundle_id + source_name on
        // every read. Storing the classification at write time lets the view be a
        // simple GROUP BY source_origin and lets unit tests assert against the column
        // directly. Existing rows are back-filled by an UPDATE that mirrors
        // `SourceAttribution.classify` in SQL.
        migrator.registerMigration("v2_add_source_origin") { db in
            try db.alter(table: "health_samples_raw") { t in
                t.add(column: "source_origin", .text)
            }
            try db.create(index: "idx_raw_source_origin", on: "health_samples_raw", columns: ["source_origin"])

            // Back-fill existing rows. Mirrors `SourceAttribution.classify` order/logic.
            // CASE ladder; order matters because we test the most specific tokens first.
            try db.execute(sql: """
                UPDATE health_samples_raw
                SET source_origin = CASE
                    WHEN LOWER(COALESCE(source_bundle_id, '')) LIKE '%garmin%'
                         OR LOWER(COALESCE(source_name, '')) LIKE '%garmin%'
                        THEN 'garmin'
                    WHEN LOWER(COALESCE(source_bundle_id, '')) LIKE '%mijia%'
                         OR LOWER(COALESCE(source_name, '')) LIKE '%mijia%'
                         OR COALESCE(source_name, '') LIKE '%米家%'
                        THEN 'xiaomiMijia'
                    WHEN LOWER(COALESCE(source_bundle_id, '')) LIKE '%xiaomi%'
                         OR LOWER(COALESCE(source_bundle_id, '')) LIKE '%mi.fit%'
                         OR LOWER(COALESCE(source_name, '')) LIKE '%xiaomi%'
                         OR COALESCE(source_name, '') LIKE '%小米运动%'
                         OR LOWER(COALESCE(source_name, '')) LIKE '%zepp%'
                        THEN 'xiaomiSports'
                    WHEN LOWER(COALESCE(source_bundle_id, '')) LIKE 'com.apple.%'
                         OR LOWER(COALESCE(source_name, '')) = 'health'
                         OR LOWER(COALESCE(source_name, '')) LIKE '%apple%'
                         OR LOWER(COALESCE(source_name, '')) LIKE '%watch%'
                        THEN 'apple'
                    WHEN LOWER(COALESCE(source_bundle_id, '')) LIKE '%huawei%'
                         OR LOWER(COALESCE(source_name, '')) LIKE '%huawei%'
                         OR COALESCE(source_name, '') LIKE '%华为%'
                        THEN 'hutool'
                    WHEN LOWER(COALESCE(source_bundle_id, '')) LIKE '%com.norte.healthmanager%'
                        THEN 'manual'
                    ELSE 'unknown'
                END
                WHERE source_origin IS NULL
                """)
        }

        // MARK: v3 — LLM-generated commentary on summaries
        //
        // `llm_text` is an optional second narrative on top of the deterministic
        // `summary_text`. Generated by `SummaryGenerator.augmentDailyWithLLM` when the
        // user has configured an OpenAI-compatible endpoint (see LLMConfig). Nullable so
        // existing rows + LLM-disabled cases just leave it empty.
        migrator.registerMigration("v3_add_llm_text") { db in
            try db.alter(table: "daily_summaries") { t in
                t.add(column: "llm_text", .text)
                t.add(column: "llm_model", .text)
                t.add(column: "llm_generated_at", .integer)
            }
            try db.alter(table: "weekly_summaries") { t in
                t.add(column: "llm_text", .text)
                t.add(column: "llm_model", .text)
                t.add(column: "llm_generated_at", .integer)
            }
        }

        // MARK: v4 — track HealthKit write-back of meal nutrition
        //
        // When a meal's nutrition is written to Apple Health, we tag every sample with a
        // per-meal sync id (stored here). Lets us idempotently re-write on edit and delete
        // the matching samples when the meal is removed. Nullable: meals that predate the
        // feature or were never synced just leave it empty.
        migrator.registerMigration("v4_meal_hk_sync_id") { db in
            try db.alter(table: "meal_records") { t in
                t.add(column: "hk_sync_id", .text)
            }
        }

        migrator.registerMigration("v5_meal_items") { db in
            try db.create(table: "meal_items") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meal_id", .integer).notNull().references("meal_records", onDelete: .cascade)
                t.column("sort_order", .integer).notNull().check(sql: "sort_order >= 0")
                t.column("name", .text).notNull().check(sql: "TRIM(name) != ''")
                t.column("grams", .double).check(sql: "grams IS NULL OR grams > 0")
                t.column("preparation_state", .text).notNull()
                    .check(sql: "preparation_state IN ('unknown', 'raw', 'cooked')")
                t.column("calories_kcal", .double).check(sql: "calories_kcal IS NULL OR calories_kcal >= 0")
                t.column("protein_g", .double).check(sql: "protein_g IS NULL OR protein_g >= 0")
                t.column("fat_g", .double).check(sql: "fat_g IS NULL OR fat_g >= 0")
                t.column("carbs_g", .double).check(sql: "carbs_g IS NULL OR carbs_g >= 0")
                t.column("provenance_kind", .text).notNull()
                    .check(sql: "provenance_kind IN ('manual', 'ai_estimate', 'nutrition_database', 'nutrition_label')")
                t.column("provenance_ref", .text)
                t.column("provenance_version", .text)
                t.column("confidence", .text)
                    .check(sql: "confidence IS NULL OR confidence IN ('low', 'medium', 'high')")
                t.column("is_user_edited", .boolean).notNull().defaults(to: false)
                t.column("created_at", .integer).notNull()
                t.column("updated_at", .integer).notNull()
            }
            try db.create(index: "idx_meal_items_meal_sort_order", on: "meal_items", columns: ["meal_id", "sort_order"], unique: true)
        }

        // 仪表盘热路径查询索引：
        // - `SELECT COUNT(*) FROM health_samples_raw WHERE is_deleted = 0`
        // - `SELECT MAX(ingested_at) FROM health_samples_raw`（+ is_deleted = 0）
        // - `SELECT COUNT(*) FROM missing_data_alerts WHERE acknowledged = 0 [AND severity = 'critical']`
        // 这些查询此前对最大的原始表做全表扫描，趋势页每次打开都重算。
        migrator.registerMigration("v6_dashboard_partial_indexes") { db in
            try db.execute(sql: """
                CREATE INDEX idx_raw_ingested_active
                ON health_samples_raw(ingested_at)
                WHERE is_deleted = 0
                """)
            try db.execute(sql: """
                CREATE INDEX idx_alert_unack_severity
                ON missing_data_alerts(severity)
                WHERE acknowledged = 0
                """)
        }

        // MARK: v7 — collapse clearly-duplicate raw samples (同一物理读数被多个 App 各自写入)
        //
        // `sample_uuid` 是 HealthKit 给每个 sample 的唯一值，`INSERT OR IGNORE` 只在
        // sample_uuid 上兜重复。若两个数据源 App（例如 小米体重秤 与 小米运动/Zepp）把**同一
        // 次称重**先后写入 Apple 健康，HealthKit 会生成两条 sample：UUID 不同，但
        // hk_type / start_at / value / unit 完全相同。这两条会被当作独立样本落进
        // `health_samples_raw`，在「当日全部测量」列表中表现为同一时间点的重复条目，
        // 并让 body-metric 日聚合的“多次称重取平均”重复计次。
        //
        // v7 分两步：
        // 1. 把已存在的重复活动样本折叠为一条——保留来源优先级更高（Garmin > Apple >
        //    小米 > …，与 SourceAttribution.Origin.cumulativePriority 一致）的行，其余
        //    软删除（is_deleted=1）。软删除而非物理删除，保持 raw 表“追加为主”的既有约定，
        //    也让占位行不参与任何 is_deleted=0 的查询。
        // 2. 建部分唯一索引 (hk_type, start_at, value, unit) WHERE is_deleted = 0：同步层
        //    既有的 `INSERT OR IGNORE` 会在再次碰到同一读数时自动跳过，从源头阻止重复记录。
        //    索引限定“未删除”行，软删除后的行不阻塞未来的重新同步。
        migrator.registerMigration("v7_collapse_duplicate_raw_samples") { db in
            // 1. 折叠既有重复：把“存在严格更优活跃孪生行”的每一行标记为已删除，仅保留每组最佳。
            //    严格更优 = 更高来源优先级，其次更早 ingested_at，最后更小 sample_uuid（确定性）。
            //    优先级 CASE 严格对齐 SourceAttribution.Origin.cumulativePriority。
            try db.execute(sql: """
                UPDATE health_samples_raw AS dup
                SET is_deleted = 1
                WHERE dup.is_deleted = 0
                  AND EXISTS (
                    SELECT 1 FROM health_samples_raw AS keep
                    WHERE keep.is_deleted = 0
                      AND keep.hk_type = dup.hk_type
                      AND keep.start_at = dup.start_at
                      AND keep.value = dup.value
                      AND keep.unit = dup.unit
                      AND (
                        (CASE COALESCE(keep.source_origin, 'unknown')
                           WHEN 'garmin' THEN 100 WHEN 'apple' THEN 50
                           WHEN 'xiaomiSports' THEN 30 WHEN 'xiaomiMijia' THEN 30
                           WHEN 'hutool' THEN 20 WHEN 'manual' THEN 10
                           ELSE 0 END
                        ) > (CASE COALESCE(dup.source_origin, 'unknown')
                           WHEN 'garmin' THEN 100 WHEN 'apple' THEN 50
                           WHEN 'xiaomiSports' THEN 30 WHEN 'xiaomiMijia' THEN 30
                           WHEN 'hutool' THEN 20 WHEN 'manual' THEN 10
                           ELSE 0 END)
                        OR (
                          (CASE COALESCE(keep.source_origin, 'unknown')
                             WHEN 'garmin' THEN 100 WHEN 'apple' THEN 50
                             WHEN 'xiaomiSports' THEN 30 WHEN 'xiaomiMijia' THEN 30
                             WHEN 'hutool' THEN 20 WHEN 'manual' THEN 10
                             ELSE 0 END
                          ) = (CASE COALESCE(dup.source_origin, 'unknown')
                             WHEN 'garmin' THEN 100 WHEN 'apple' THEN 50
                             WHEN 'xiaomiSports' THEN 30 WHEN 'xiaomiMijia' THEN 30
                             WHEN 'hutool' THEN 20 WHEN 'manual' THEN 10
                             ELSE 0 END)
                          AND (keep.ingested_at < dup.ingested_at
                               OR (keep.ingested_at = dup.ingested_at AND keep.sample_uuid < dup.sample_uuid))
                        )
                      )
                  )
                """)
            // 2. 部分唯一索引：每个仍在活跃状态的“规范读数” (hk_type, start_at, value, unit) 至多一条。
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_raw_active_reading_unique
                ON health_samples_raw(hk_type, start_at, value, unit)
                WHERE is_deleted = 0
                """)
        }

        // MARK: v8 — 用 ROUND(value,3) 容差替代 v7 的精确 double 匹配
        //
        // v7 用 (hk_type, start_at, value, unit) 的 **精确 double 相等** 做去重，在真机上发现
        // 仍拦不住“同一物理读数被两个 App 写入”的情况：两个 App（小米体重秤/米家 与 小米运动/Zepp）
        // 记录**同一次称重**时，底层存的值在 float 低精度位上有细微差异（如 82.84999847412109 vs
        // 82.84999999999999，都显示为 82.8），精确值不相等 → 唯一索引和折叠逻辑都漏掉，界面出现重复条目。
        //
        // v8 把“同一读数”的判定换成 ROUND(value, 3)（0.001 桶，足以吸收 ~1e-6 的浮点表示噪声，又不会
        // 合并真正不同的取值），并重建唯一索引为 ROUND 表达式索引，让同步层既有的 `INSERT OR IGNORE`
        // 在再次碰到同一物理读数时自动跳过。
        //
        // 注意：v7 已应用的库（或新装先跑 v7）先建了精确值索引，这里先折叠近重复，再 DROP 旧的精确索引
        // 并换成 ROUND 表达式索引 —— 索引名保持一致以便只保留一份去重约束。
        migrator.registerMigration("v8_round_dedup_raw_samples") { db in
            // 1. 折叠既有近重复：把“存在严格更优活跃孪生行（同 hk_type + 同 start_at + 同 ROUND(value,3)
            //    + 同 unit）”的每一行软删除，仅保留每组最佳（更高来源优先级 → 更早 ingested_at →
            //    更小 sample_uuid）。优先级 CASE 与 v7 / SourceAttribution.Origin.cumulativePriority 一致。
            try db.execute(sql: """
                UPDATE health_samples_raw AS dup
                SET is_deleted = 1
                WHERE dup.is_deleted = 0
                  AND EXISTS (
                    SELECT 1 FROM health_samples_raw AS keep
                    WHERE keep.is_deleted = 0
                      AND keep.hk_type = dup.hk_type
                      AND keep.start_at = dup.start_at
                      AND ROUND(keep.value, 3) = ROUND(dup.value, 3)
                      AND keep.unit = dup.unit
                      AND (
                        (CASE COALESCE(keep.source_origin, 'unknown')
                           WHEN 'garmin' THEN 100 WHEN 'apple' THEN 50
                           WHEN 'xiaomiSports' THEN 30 WHEN 'xiaomiMijia' THEN 30
                           WHEN 'hutool' THEN 20 WHEN 'manual' THEN 10
                           ELSE 0 END
                        ) > (CASE COALESCE(dup.source_origin, 'unknown')
                           WHEN 'garmin' THEN 100 WHEN 'apple' THEN 50
                           WHEN 'xiaomiSports' THEN 30 WHEN 'xiaomiMijia' THEN 30
                           WHEN 'hutool' THEN 20 WHEN 'manual' THEN 10
                           ELSE 0 END)
                        OR (
                          (CASE COALESCE(keep.source_origin, 'unknown')
                             WHEN 'garmin' THEN 100 WHEN 'apple' THEN 50
                             WHEN 'xiaomiSports' THEN 30 WHEN 'xiaomiMijia' THEN 30
                             WHEN 'hutool' THEN 20 WHEN 'manual' THEN 10
                             ELSE 0 END
                          ) = (CASE COALESCE(dup.source_origin, 'unknown')
                             WHEN 'garmin' THEN 100 WHEN 'apple' THEN 50
                             WHEN 'xiaomiSports' THEN 30 WHEN 'xiaomiMijia' THEN 30
                             WHEN 'hutool' THEN 20 WHEN 'manual' THEN 10
                             ELSE 0 END)
                          AND (keep.ingested_at < dup.ingested_at
                               OR (keep.ingested_at = dup.ingested_at AND keep.sample_uuid < dup.sample_uuid))
                        )
                      )
                  )
                """)
            // 2. 用 ROUND 表达式唯一索引替换 v7 的精确值索引。
            try db.execute(sql: "DROP INDEX IF EXISTS idx_raw_active_reading_unique")
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_raw_active_reading_unique
                ON health_samples_raw(hk_type, start_at, ROUND(value, 3), unit)
                WHERE is_deleted = 0
                """)
        }

        return migrator
    }

    static func run(on pool: DatabasePool) throws {
        try makeMigrator().migrate(pool)
    }
}
