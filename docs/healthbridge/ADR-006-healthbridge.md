# ADR-006: iCloud transport for a read-only personal health replica

Status: Accepted by user, implementation verification pending.

## Context
HealthManager 0.7.1 / 1479db9 already collects normalized HealthKit samples and has a JSONL backup contract. The user selected hybrid storage and iCloud Drive transport, one year of health history, all meals/medications, and full read access for OpenClaw. Existing backup and nutrition writeback must remain intact.

## Decision
Use a separate HealthBridgeSync directory, immutable SHA-256 checked batches, transactional mutation capture and durable export outbox. Publish a snapshot only after its final batch; follow with ordered idempotent deltas. Receiver receipts acknowledge committed ingestion, never just upload. Keep both live databases outside iCloud. The bridge query surface is read-only and cloud model use is permitted. No photo files, credentials, or App endpoint configuration are exported.

Shared Swift core owns the wire contract, exporter, receiver, and deterministic queries. macOS executable uses official MCP Swift SDK 0.12.1 and GRDB 6.29.3, resolved transitives locked in Package.resolved. iOS compiles the shared core without MCP dependencies.

## Consequences
iCloud is asynchronous. Physical-device tests and 48-hour observation are separate acceptance gates. Incomplete transport leaves the previous valid replica queryable. Database restore or explicit rebuild starts a fresh epoch; stale epochs cannot replace a newer committed one. One source dataset is accepted per receiver; switching requires explicit local configuration. Full raw Apple Health fidelity is not claimed.

## Toolchain compatibility evidence
Official SDK 0.11.0 fails Swift 6.4 compilation in NetworkTransport continuation isolation. Official tag 0.12.1 contains the MainFlag fix, inspected locally via git diff. Pin 0.12.1 rather than weaken concurrency checks or patch vendored source. Documentation plugin branch transitive is pinned to a revision in Package.resolved and is not invoked by application builds.
