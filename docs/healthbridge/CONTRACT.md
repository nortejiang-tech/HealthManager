# HealthBridge wire contract v1

Source of truth: shared BridgeCore/Protocol.swift, Source.swift, Receiver.swift and App database migrations. Dates are UNIX seconds in records, local yyyy-MM-dd in daily rows. JSON null stays unknown; existing SQLite booleans encode as 0/1. Row JSON is nested in the record's json string. No photo_path or blobs are serialized. Arbitrary HealthKit metadata is stripped to the six allowed structured fields.

## Entity mapping
| Entity / identity | Transported fields and meaning |
|---|---|
| health_samples_raw / sample_uuid | hk_type, kind, value, unit, start_at/end_at, source_name/source_bundle_id, device_name/device_model, ingested_at, is_deleted, restricted extra_json; only nine allowed types, start_at >= initial historyStart |
| meal_records / id | All persisted scalar fields except photo_path; eaten_at, meal_type, calories_kcal/protein_g/fat_g/carbs_g, notes, provenance/estimate fields preserved |
| meal_items / id | All persisted scalar fields including meal_id, ingredient/amount and stored nutrient/provenance snapshots; references remain scoped to dataset/epoch |
| medication_plans / id | name, dosage_mg, frequency, schedule_json, start_date/end_date, reminder_enabled, notes, created_at; intended regimen only |
| medication_logs / id | plan_id, scheduled_at, action, action_at, dosage_mg, side_effects, notes, created_at; taken/skipped/deferred remain distinct |
| activity_metrics_daily / date | Existing activity/sleep/heart daily projections and sources_json/computed_at; no multi-device raw summing in query layer |
| body_metrics_daily / date | Existing body projections, sources_json/computed_at; not a new body composition computation |
| data_quality_daily / date | Existing quality fields unchanged |

Nine raw types: HKCategoryTypeIdentifierSleepAnalysis; HKQuantityTypeIdentifierStepCount; HKQuantityTypeIdentifierActiveEnergyBurned; HKQuantityTypeIdentifierAppleExerciseTime; HKQuantityTypeIdentifierHeartRate; HKQuantityTypeIdentifierRestingHeartRate; HKQuantityTypeIdentifierHeartRateVariabilitySDNN; HKQuantityTypeIdentifierBodyMass; HKWorkoutTypeIdentifier. Unit remains the App's normalized unit. Sleep/workout details preserve categoryValue, sleepStage, activityType, duration, totalEnergyKcal, totalDistanceMeters when present. UUIDs map as strings; integer keys are stringified and never reused across an epoch boundary.

## Files and state machine
`batches/<epoch>-<12-digit-sequence>/records.jsonl` contains one `{table,key,json}` per line. json=null means explicit deletion. manifest.json is written last, but receiver assumes either file can arrive first.

Manifest: version=1, dataset UUID, epoch UUID, epochStarted, sequence (starts1), snapshot, finalSnapshot, historyStart, timeZone, generatedAt, count, bytes, sha256. SHA-256 is over exact JSONL bytes. There is no claim of cryptographic sender authentication; the selected private iCloud folder and OS account are the trust boundary.

Source writes consistent snapshot, change watermark and durable outbox in one transaction. One batch holds up to1000 records; an empty final batch is valid. Changes after that transaction enter subsequent ordered upsert/tombstone batches. HealthKit anchors are not transmission cursors. A restored database pauses transmission while imports run; new epoch is required before publication.

Receiver checks schema/identities/count/bytes/hash, ordered sequence and snapshot state, then atomically commits rows, progress and receipt data. A snapshot remains invisible until finalSnapshot. Duplicate committed batches replay receipts. Corrupt/missing/future batches preserve the previous replica. Newer snapshot becomes active only after complete receipt of that generation.

`receipts/<epoch>-<sequence>.json`: dataset, epoch, sequence, sha256, receivedAt. Sender marks acknowledged only after matching identity/sequence/hash. Seven-day cleanup is based on observed acknowledgment, not upload time. Unacknowledged files are not automatically removed. Rebuild leaves old transport files rather than deleting an unconfirmed generation.

## Query contract
Every data response includes meta (export/ingest/coverage), query, timeZone and result. health_sync_status returns meta directly. observedCoverage is per HealthKit type; it is not permission status and does not certify a whole day. Records retain individual source attribution. Raw pagination is ordered by start_at then record_key; other lists by record_key. Use one stable replica generation for multi-page comparisons; check meta after paging if synchronization changes it.

Dates are inclusive. Source timezone governs daily queries; sleep uses 18:00 previous civil day through18:00 wake day, with DST-aware calendar arithmetic. Steps/energy and daily HRV use existing stored daily methodology. Night HRV median is separate. Comparison difference is period A mean minus period B mean. No numerical fill for unknown values. Medication date filter is scheduled_at; all plans are returned independently of the log range. Paginated daily meal/log sections can expose nextOffset; use dedicated list tools for remaining records.

`health_daily_summary` also includes `nutrition` and `energyBalance`. Nutrition derives only from the persisted `meal_records` snapshot for that local date: `mealCount`, calories, protein, fat, and carbohydrates are reported; a nutrient total is null if any meal has no finite, non-negative value for that nutrient. `calorieStatus` is `no_meals`, `incomplete`, or `complete`; no meals are never represented as zero intake. Energy balance retains the App formula `basal_energy_kcal + active_energy_kcal - calorie_intake_kcal`. It returns active energy, basal energy, total expenditure, intake, deficit, method, and a status. Deficit is null unless all three inputs are valid; an unknown or invalid input is never imputed. `health_metric_history` and therefore `health_compare` also support `calorie_intake` and `calorie_deficit`, preserving each unknown day as an explicit gap.

CLI: `healthbridge query TOOL --args JSON`; `healthbridge status`; MCP: `healthbridge mcp` over stdio, nine readonly tools. No arbitrary SQL or write-back tools. Full catalog is BridgeToolCatalog.swift and the OpenClaw skill reference. A data query before final initial snapshot returns an explicit error.

## Acceptance fixtures
HealthBridge/Tests/BridgeCoreTests and Tests/HealthBridgeIntegrationTests contain synthetic sources; HealthBridge/scripts/smoke.py creates a temporary transport and database, exercises actual stdio and deletes its temporary fixture. No personal health data is checked in.
