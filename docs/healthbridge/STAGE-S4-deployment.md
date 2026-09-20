# S4 — Local receiver and Agent integration

Status: implementation ready; external acceptance PENDING.

Planner-owned (deployment/control plane). Prerequisites: iOS unit 331/331; Mac protocol 10/10; real stdio initialize/list/nine query calls/unknown-tool rejection PASS with synthetic fixture. Dependencies pinned; shared SQLite outside iCloud; no new network listener.

Actions: install built executable in ~/Library/Application Support/HealthManagerBridge/bin; register com.norte.healthbridge.receiver user LaunchAgent with RunAtLoad, WatchPaths and 60-second StartInterval. Select only Health manager/HealthBridgeSync as transport root. Read back process result and empty-store status. Build device app 0.8.0(15), overlay install without uninstall or data reset.

OpenClaw gate: CLI identified existing agent acl-rehab-assistant and a compatible already-installed Node 24.21.0. MCP list reports another process owning state-lifecycle and pending plugin migrations. Do not seize lock, remove state, repair unrelated plugins, or restart Gateway. Prepare managed MCP config and per-agent usage documentation; retry only after lifecycle state clears. Real Agent calls without --deliver, no Feishu messages.

Rollback: bootout only com.norte.healthbridge.receiver, turn off App sync. Keep databases, iCloud files and existing backups. Existing binary/plist is never overwritten unless it was installed by this task and fingerprint matches. No global Node/config updates.

User action: iPhone system folder picker/HealthKit permissions as needed. 48-hour timing starts after first real committed receipt, not synthetic test or service launch.
