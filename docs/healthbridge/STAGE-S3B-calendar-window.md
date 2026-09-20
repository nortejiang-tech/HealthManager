# S3B — Calendar-correct sleep window
Status: READY; independent acceptance PENDING.

Problem: sleep windows must use local civil 18:00 boundaries even on DST transition days, rather than fixed 24-hour arithmetic.
Owner: Planner specifies contract and immutable acceptance harness; EVO Coder implements one Foundation-only Swift file. Existing query/integration/SQLite files are excluded. Scope: BridgeCalendarWindow.sleep(wakeDate:timeZone:) -> DateInterval, throwing on invalid yyyy-MM-dd or timezone.
Trust gate: PASS; all three fixture inputs (prompt, WindowChecks.swift, verify.sh) authored/reviewed by Planner. Workspace /private/tmp/healthbridge-coder-s3b contains no external docs, repo, credentials or user data. Only one output is writable.
Tests: ordinary Shanghai day, US spring 23-hour night, US autumn 25-hour night, exact UTC endpoints, malformed/nonexistent dates and timezone. Preinstalled Swift; no network or dependencies.
Risk: low deterministic utility. Prior S3A guard violation was reviewed; new prompt explicitly requires relative paths and zero-based verify index and immediate stop on guard error. This is a separate stage, not automatic fallback or overwrite of failed work.
Rollback: remove utility and Planner callsite adaptation only. Current code baseline remains uncommitted and preserved.
