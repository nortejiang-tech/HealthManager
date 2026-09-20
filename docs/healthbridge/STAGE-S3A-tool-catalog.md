# STAGE S3A — Per-tool MCP metadata

Status: READY for Coder; acceptance PENDING.

Goal: Replace generic identical MCP descriptions with precise per-tool parameter contracts, making Agent tool selection reliable.
Scope: one pure Swift metadata file; no database, transport, credentials, migration or deployment access. Planner will integrate only after independent verification. Non-goals: changing query semantics, SDK, OpenClaw config.
Baseline: implementation under review at HEAD 1479db9 plus Planner diff. Coder sees only /tmp/healthbridge-coder-s3a, not that working tree. Inputs reviewed completely: prompt, CatalogChecks.swift, verify.sh. Origin: current Planner; no external instructions. Trust gate PASS.
Verification: /bin/sh /tmp/healthbridge-coder-s3a/verify.sh, local preinstalled Swift, no network. Acceptance: nine tool identities; required fields; no write tools; clear date/freshness/missing-data/medication semantics; production diff limited to new descriptor file + Planner integration.
Risk: low, isolated immutable data. Route: EVO Coder per global policy; prewrite non-guard failure -> Spark; postwrite/guard failure -> Planner review.
Rollback: remove only the integrated descriptor file and its narrow CLI reference; preserve all pre-existing changes. No commits.
