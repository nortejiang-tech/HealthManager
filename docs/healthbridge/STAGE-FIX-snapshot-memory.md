# Snapshot crash hotfix

User reports repeated foreground crashes during generating sync data. Live device Jetsam 2026-09-19 22:50:32 identifies HealthManager, reason per-process-limit, active/frontmost, 216064 resident pages at16384 bytes/page (~3.30 GiB). Raw diagnostic remains local temporary, no personal records copied into repository.

Planner-owned: snapshot transaction/resource lifetime, high-risk exclusion from local Coder. Existing dirty worktree preserved. No EVO call; no wrapper changes. Narrow production scope Source.swift, deployment version only if fix accepted; focused package stress regression. No schema or user record change. Hypotheses: autoreleased JSON temporaries; SQLite transaction cache; preceding HealthKit retention. Test actual prepare with60000 synthetic rows, assert memory growth under160MiB and exact61 batches. Verify red before editing implementation, then green and package/iOS regressions. Retain snapshot consistency and durable outbox. Rollback: stop export; never delete source records.

Red: 60000 records growth557875200 bytes >167772160 limit, exact61 batches. After single-variable autoreleasepool change: growth6848512 bytes, test PASS.600000 records: test PASS, peak below fixture setup high-water. This establishes the JSON temporary-retention contribution independently of SQLite/HealthKit. No schema/record changes. Device build0.8.1(16) PASS; installed/sync acceptance pending.

Final software checks: iOS unit331/331 PASS (hotfix-ios-tests.json); package12/12 PASS; signed device build/install PASS; devicectl readback0.8.1(16). Awaiting unlocked foreground retry and true receipt. No repeat historical backfill is required.

Live post-install probe: devicectl launch PASS, same PID20271 remains running on successive checks. iCloud batch directories progressed7→195→392; receiver committed sequences10→16 (10000→16000 records) with complete=0. This is physical partial-transport evidence, not full snapshot acceptance. Transient unreadable/incomplete manifests occur during iCloud arrival. No raw health values recorded.
