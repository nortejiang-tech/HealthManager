#!/usr/bin/env python3
"""Synthetic rendering fixture. Restricted to this task's disposable simulator.

Run only after tests and after stopping the QA app. Never writes Apple Health,
real-device data, the Mac HealthBridge replica, or an arbitrary database path.
"""
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo
import json
import sqlite3
import subprocess

SIMULATOR = "29729D20-7BF0-4206-9FCD-84576508885D"
BUNDLE = "com.norte.HealthManager"
devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "-j"]))
device = next(d for values in devices["devices"].values() for d in values if d["udid"] == SIMULATOR)
assert device["name"] == "HealthManager-Training-QA-20261015", "Not the dedicated QA simulator"
root = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", SIMULATOR, BUNDLE, "data"], text=True).strip()).resolve()
assert f"CoreSimulator/Devices/{SIMULATOR}/data/Containers/Data/Application/" in str(root), "Unexpected app container"
db_path = root / "Library/Application Support/HealthManager/health.sqlite"
assert db_path.is_file(), "Launch the QA app once before seeding"

zone = ZoneInfo("Asia/Shanghai")
now = datetime.now(zone)
today = now.replace(hour=0, minute=0, second=0, microsecond=0)
rows = []


def add(identity, kind, value, start, end=None, extra=None):
    end = end or start
    assert end <= now, "Fixture would include future samples"
    types = {
        "heart": ("HKQuantityTypeIdentifierHeartRate", "quantity", "count/min"),
        "hrv": ("HKQuantityTypeIdentifierHeartRateVariabilitySDNN", "quantity", "ms"),
        "resting": ("HKQuantityTypeIdentifierRestingHeartRate", "quantity", "count/min"),
        "sleep": ("HKCategoryTypeIdentifierSleepAnalysis", "category", "category"),
        "workout": ("HKWorkoutTypeIdentifier", "workout", "second"),
    }
    hk_type, record_kind, unit = types[kind]
    rows.append(("qa-training-" + identity, hk_type, record_kind, value, unit,
                 int(start.timestamp()), int(end.timestamp()), "QA 合成数据", "qa.training.watch",
                 "QA Watch", "synthetic", int(min(now, end + timedelta(seconds=1)).timestamp()),
                 0, json.dumps(extra, ensure_ascii=False) if extra else None, "apple"))


for day in range(1, 25):
    wake_day = today - timedelta(days=day)
    date = wake_day.date().isoformat()
    start = wake_day - timedelta(hours=2)
    hours = 6.5 if day == 1 else 7.3 + (day % 4) * .2
    end = start + timedelta(hours=hours)
    add(f"sleep-{date}", "sleep", 3, start, end, {"categoryValue": 3, "sleepStage": "core"})
    for index, minute in enumerate((60, 180, 300)):
        add(f"hrv-{date}-{index}", "hrv", 35 + (24 - day) * .3 + index, start + timedelta(minutes=minute))
    for minute in range(0, int(hours * 60), 20):
        add(f"sleep-heart-{date}-{minute}", "heart", 51 + day % 3,
            start + timedelta(minutes=minute), extra={"metadata": {"HKHeartRateMotionContext": "1"}})
    add(f"resting-{date}", "resting", 60, wake_day + timedelta(hours=7))

for day in (1, 3, 6, 9, 12, 15, 18):
    start = today - timedelta(days=day) + timedelta(hours=18)
    date = start.date().isoformat()
    seconds = 27 * 60 if day == 1 else 30 * 60
    end = start + timedelta(seconds=seconds)
    add(f"run-{date}", "workout", seconds, start, end,
        {"activityType": 37, "duration": seconds, "totalDistanceMeters": 5000})
    for second in range(0, seconds, 10):
        add(f"run-heart-{date}-{second}", "heart", 142 + day % 4, start + timedelta(seconds=second))
    for second, pulse in ((0, 145), (60, 115), (120, 100)):
        add(f"post-heart-{date}-{second}", "heart", pulse, end + timedelta(seconds=second))

# One low-coverage walk exercises the explicitly incomplete-load score range.
walk_start = today - timedelta(days=1) + timedelta(hours=7)
add("walk-limited", "workout", 900, walk_start, walk_start + timedelta(minutes=15),
    {"activityType": 52, "duration": 900, "totalDistanceMeters": 1100})
for minute in (0, 7, 14):
    add(f"walk-heart-{minute}", "heart", 95, walk_start + timedelta(minutes=minute))

# Intraday windows use only synthetic, non-workout measurements.
for minute in range(0, 24 * 60, 5):
    time = today - timedelta(days=1) + timedelta(minutes=minute)
    if time > now:
        continue
    if 18 <= time.hour < 19 or time.hour < 7:
        continue
    add(f"day-heart-{minute}", "heart", 66 + (minute // 30) % 10, time,
        extra={"metadata": {"HKHeartRateMotionContext": "1"}})

with sqlite3.connect(db_path) as db:
    db.executemany("""
        INSERT OR REPLACE INTO health_samples_raw
        (sample_uuid,hk_type,kind,value,unit,start_at,end_at,source_name,source_bundle_id,
         device_name,device_model,ingested_at,is_deleted,extra_json,source_origin)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, rows)
    for day in range(1, 25):
        date = (today - timedelta(days=day)).date().isoformat()
        db.execute("""
            INSERT INTO body_metrics_daily(date,weight_kg,body_fat_pct,lean_mass_kg,computed_at)
            VALUES (?,?,?,?,?) ON CONFLICT(date) DO UPDATE SET
            weight_kg=excluded.weight_kg,body_fat_pct=excluded.body_fat_pct,lean_mass_kg=excluded.lean_mass_kg
            """, (date, 72.0 + day * .02, .18 + day * .0002, 59, int(now.timestamp())))
        db.execute("""
            INSERT INTO activity_metrics_daily(date,vo2_max,resting_hr_bpm,computed_at)
            VALUES (?,?,?,?) ON CONFLICT(date) DO UPDATE SET vo2_max=excluded.vo2_max,resting_hr_bpm=excluded.resting_hr_bpm
            """, (date, 38 + (24 - day) * .08, 60, int(now.timestamp())))
print(json.dumps({"dataset": "synthetic QA only", "simulator": SIMULATOR, "rawRecords": len(rows)}))
