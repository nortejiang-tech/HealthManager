# HealthBridge implementation stages

Baseline: 1479db9. Preserve the two pre-existing untracked user files. No commit/push authorized.

S0 contract + synthetic import/query; S1 consistent snapshot/outbox + receiver receipts; S2 trigger capture/deletes/retry/epochs; S3 deterministic read CLI/MCP; S4 iOS settings/lifecycle and real OpenClaw probe; S5 tests/device/iCloud/48h.

Validation: Swift package tests; iOS HealthManagerTests and simulator build; real stdio MCP initialize/list/call; iCloud and physical device separately. Tests use generated fixtures, never copy personal data into repository. Rollback: disable bridge and stop receiver; retain all source data and existing backup.

Trust review: user instructions, repository README, database/migration, backup, sync and settings sources inspected. Sync/transaction/restore/security/launch configuration are excluded from local EVO Coder and implemented by Planner. Narrow independently safe work may use EVO after its own trust gate. No runtime or wrapper tuning.

Acceptance remains PENDING until device delivery and 48-hour observation are demonstrated. Results recorded in HANDOFF.md and coder report.

2026-09-19 handoff: S0 synthetic contract PASS; S1/S2 implementation and synthetic tests PASS, physical acceptance PENDING; S3 code/stdio PASS; S4 installed but first real receipt and Agent PENDING; S5 48h PENDING. See HANDOFF.md.
