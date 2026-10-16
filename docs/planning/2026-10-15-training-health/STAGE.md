# 运动健康第一版 — 2026-10-15

Status: SOFTWARE / SIMULATOR PASS (2026-10-16). Foreground physical-device core checks and one actual new-data/UI auto-update observation PASS in the evening follow-up. Full physical-device scenarios and physiological calibration remain PENDING. See DEVICE-VALIDATION.md / DEVICE-VERIFICATION.json for the exact scope.

## Scope and acceptance
- Replace only the medication tab with Training; move medication into More, preserving its actions/reminders and a working back button.
- Show recorded running performance, recorded all-workout load, sleep/HRV/heart-rate recovery trends, and an experimental readiness score with formula, timestamp, input coverage and missing reasons.
- Derive from bounded raw HealthKit samples. Never treat missing measurements as recovery, complete wear or zero physiological load. No HealthKit write, existing migration change, medication-domain change, credentials, deployment or Git commit.
- React to imported raw changes, local edits, scene activation and a visible-screen time refresh. Cancel/debounce obsolete work. Last measurement, ingestion and calculation times remain distinct.
- All physiology/measurement definitions and readiness are experimental references; no injury probability, diagnosis, recovery-hour guarantee or exercise clearance.

## Stages and routing
1. Navigation: EVO-Coder in an isolated directory containing only reviewed source files and a Planner-owned verification script; 3 write paths. Planner independently checks the diff and verifies unchanged medication logic.
2. Calculation and loader: Planner handles the higher-judgment, cross-domain inference stage. Read-only on-demand snapshots; no persistent migration required.
3. SwiftUI training screen and details: integrate with existing components, charts, source evidence and refresh events.
4. Verification: focused calculator/loader tests (missing/invalid/future/duplicate/source/gap/time boundaries), project regeneration, full unit suite and simulator UI including More -> medication -> add/cancel/back. Record real-device sync latency and physiological validation as PENDING.

## Final v1 measurement contract
- Running pace: HKWorkout active duration / recorded distance. Heart-rate aggregates are time weighted with a maximum 30-second supported interval; no interpolation across longer gaps. Reject severe pause ambiguity and source mismatch.
- Internal load: integral of positive heart-rate excess above a documented personal resting reference, in bpm·min. It is a transparent experimental load index, not a calibrated energy expenditure. Coverage <70% suppresses the session estimate. Daily/weekly sums are labeled recorded load; any missing session load prevents a complete total.
- Recovery: signed finish-to-60/120-second heart-rate change, nearest observed values within 15 seconds, same source and no overlapping workout. It is not a clinical standardized recovery test.
- Sleep: dominant-source intervals, 18:00-to-18:00 wake-date window, union of asleep stages with conflicting awake excluded. Select the longest main episode; daytime naps cannot replace the main night or mix awake HRV into the night.
- Readiness: current night requires >=3 HRV and >=12 HR samples, both spanning >=1 hour, main sleep <=30 hours old, and >=14 previous qualifying same-source nights in42 days. Baseline excludes evaluated night/future samples. Sleep, one combined autonomic factor (max normalized HRV/pulse deviation, not a sum), and load form the score. Only load missing: withhold single score and show possible bounds for unknown0–15 penalty; this is not a statistical confidence interval. Night evidence insufficient: withhold score and range. Exact v1 parameters are disclosed and unvalidated; see DESIGN.md.
- Source changes do not share physiological baselines; timing/coverage credibility does not represent clinical validity.

## Rollback and handoff
At completion of the software-validation stage, changes were unstaged. The user later explicitly authorized committing this task; subsequent commit status is recorded by Git history. Revert only this task's files after review; preserve the three original untracked items. No production database or device install was planned in this original stage. Source hashes and unchanged medication-business suffix proof are saved. Native signed suite 465/465 passed (463 unit +2 UI, including27 focused training tests); separate true-dark rendering1/1 passed. Largest accessibility typography was corrected and screenshots reviewed. Full evidence in VERIFICATION.json; operational handoff in HANDOFF.md;3 isolated Coder calls and independent acceptance in EVO-CODER-REPORT.md/.json.

Evening follow-up: the device was installed in the authorized later stage, privately backed up and inspected using actual data. Product/test source hashes remain unchanged. Native UI-probe compilation succeeded, but two XCTest launch attempts failed before business assertions; actual iPhone Mirroring observations supplied the core UI evidence. Background/cold-start/power, exact raw-sample/observer-job correlation and the persistent sync-type work item are still PENDING. No new implementation or Coder call was needed; see EVO-CODER-RESUME-REPORT.md/.json.
