# S1/S2 — Snapshot, outbox and receiver transaction review

Status: implementation exists, independent acceptance PENDING.

Process note: the initial implementation was written directly by Planner before detailed phase task sheets were complete. This file records that deviation, not a retroactive Coder receipt. User reiterated Planner–Coder structure; subsequent Coder stages use isolated reviewed fixtures and structured receipts.

Owner/routing: Planner owns transactions, recovery and deployment per explicit high-risk exclusions. Current review tasks: snapshot consistency, durable outbox vs file publication, upsert/delete capture in same transaction, epoch ordering, immutable receipt replay, restore suspension, bounded memory, directory authorization. No credentials or external generated instructions are sent to Coder.

Acceptance: snapshot is invisible until final batch; missing/out-of-order/corrupt data cannot advance cursor; duplicates do not change counts; historical edits and deletes propagate; restoring source cannot publish a partially imported dataset; only explicit resumption or successful restore releases suspension. Source/receiver outbox cursors are independent of HK anchors.

Verification commands: swift test --package-path HealthBridge --skip-update; xcodebuild test -project HealthManager.xcodeproj -scheme HealthManager -destination 'platform=iOS Simulator,id=8C45134B-B1F4-4C82-BBB9-F5C713D82846' -only-testing:HealthManagerTests -parallel-testing-enabled NO (local dependency cache). Actual execution receipts are in reports and HANDOFF; command invocation alone is not PASS.

Risk: high; no EVO routing. Rollback: disable bridge, stop receiver; never revert user tables or old migration definitions. Real iCloud/device/48h gates remain separate.
