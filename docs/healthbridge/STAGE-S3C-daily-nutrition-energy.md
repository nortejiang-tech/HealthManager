# S3C — Daily nutrition and energy balance read contract

Status: SOFTWARE PASS; live health-agent tool-trace acceptance PENDING.

## Goal

Make the already-exported meal records and daily energy projections usable by
the read-only Bridge: `health_daily_summary` will expose deterministic daily
nutrition totals and the existing HealthManager calorie-balance result;
`health_metric_history` will expose daily calorie intake and calorie deficit
series for descriptive analysis.

## Baseline and trust gate

Baseline is `1479db9` plus the existing uncommitted HealthBridge work. The
Planner reviewed `HealthBridge/Sources/BridgeCore/Query.swift`,
`BridgeToolCatalog.swift`, `Protocol.swift`, the App's
`MealNutritionEvidence.swift`, `MealNutritionProjection.swift`, dashboard
calculation and current package tests. These are repository sources authored
in this workspace; no external README, generated prompt, personal database,
credential, or health-record content is exposed to the Coder. Trust gate:
PASS. Existing user files and unrelated dirty changes remain outside scope.

## Contract

- Meal detail remains paginated through `health_meals`; no photos or blobs are
  introduced.
- `nutrition` is calculated from `meal_records` in the source timezone. Each
  nutrient total is known only when every meal for that nutrient has a finite,
  non-negative stored value. `calorieStatus` is `no_meals`, `incomplete`, or
  `complete`.
- `energyBalance` uses the App's existing formula:
  `basal_energy_kcal + active_energy_kcal - calorie_intake_kcal`.
  It returns no deficit when any required input is unknown or invalid and
  names the missing-input reason; it never substitutes zero.
- `calorie_intake` and `calorie_deficit` history retain every requested day;
  missing values remain explicit gaps. `health_compare` inherits these metrics
  through the same history service.
- The source wire format, migration schema, iCloud transport, receiver
  ordering, and OpenClaw configuration are out of scope.

## Acceptance and verification

Synthetic source -> exporter -> receiver -> query tests must prove:

1. two complete meals and valid basal/activity values produce totals,
   expenditure, and `deficit = basal + active - intake`;
2. one unknown meal calorie produces `incomplete` and a null deficit;
3. intake/deficit history preserves a missing day instead of interpolating;
4. existing package tests remain green.

Verification commands (offline dependency cache only):

```sh
swift test --package-path HealthBridge --skip-update --filter BridgeCoreTests/testDailyNutritionAndEnergyBalanceReadContract
swift test --package-path HealthBridge --skip-update
```

## Routing, risk, and rollback

The Coder phase is one reviewed production file (`Query.swift`) with a
Planner-authored failing test. It has no transport, database migration,
security, deployment, credential, or write capability. The Planner will
independently review the diff and rerun both commands. If the Coder guard
fails after a write, preserve the diff and return to Planner; do not overwrite
it automatically. Rollback removes only the new query fields and metrics;
existing meals, medication records, iCloud batches, and local replicas remain
untouched.

## Result — 2026-09-20

The Planner-authored red tests first reproduced the missing `nutrition` field.
They now prove complete daily totals and balance, partial meal calories, zero
meal records, invalid activity energy, and a date-range gap. The complete
BridgeCore suite passed 15/15. A release CLI was atomically installed at the
existing HealthManagerBridge path; a real available replica returned the new
summary sections and a calorie-deficit history with only numbers or nulls.
No personal record values were emitted during verification.

The iOS Simulator build passed with code signing disabled. The source Skill
and the installed `acl-rehab-assistant` copy match. Its workspace rule now
requires a status command and the applicable Bridge query before answering an
actual-record question. No-delivery agent runs loaded the rule, but their
trajectory contains no tool-call event; their self-reported execution is not
accepted as proof. A real health-agent tool-call trace therefore remains
PENDING. This does not affect the installed CLI or the Mac replica query
acceptance.
