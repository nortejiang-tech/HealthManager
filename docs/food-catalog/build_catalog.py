#!/usr/bin/env python3
"""从 MEXT《日本食品标准成分表（八订）增补2023》官方 Excel 构建离线营养目录资源。

输入：MEXT 官网下载的 `20260327-mxt_kagsei-mext-000029402_02.xlsx`（第2章データ）。
输出：`Resources/FoodCatalog/food_catalog_v1.json`。

数据口径（与 docs/planning/02-官方来源与个人食物方案.md 一致）：
- 每条为「每 100 g 可食部分」，采用原表 kcal / たんぱく質 / 脂質 / 炭水化物
  （成分識別子 ENERC_KCAL / PROT- / FAT- / CHOCDF-）四列，不做 4/4/9 重算。
- "-" → unmeasured（未测定，显示 "—"）；"Tr" → trace（微量）；"(x)" → estimated（推定值）。
- 不把 unmeasured/trace 一律写 0；App 端按 flag 分别显示。

运行：python3 build_catalog.py <path-to-xlsx>
"""

import json
import hashlib
import re
import sys
from pathlib import Path

import openpyxl

SOURCE_AGENCY = "MEXT"
SOURCE_TITLE = "日本食品标准成分表（八订）增补2023年"
SOURCE_BASE_URL = "https://fooddb.mext.go.jp/details/details.pl?ITEM_NO={group}_{no}_7"
DOWNLOAD_URL = "https://www.mext.go.jp/content/20260327-mxt_kagsei-mext-000029402_02.xlsx"
ERRATA_URL = "https://www.mext.go.jp/content/20260327-mxt_kagsei-mext-000029402_16.xlsx"

# (食品番号, 中文名, [审核别名], category, preparationState, basis, 中文边界说明)
ENTRIES = [
    # --- 主食 ---
    ("01088", "熟白米饭", ["白米饭", "米饭", "熟米饭"], "staple", "cooked", "per100g",
     "日本短粒粳米·精白米炊饭；含水率随煮制略有差异"),
    ("01085", "糙米饭", ["糙米饭"], "staple", "cooked", "per100g",
     "糙米炊饭"),
    ("01026", "主食面包", ["面包", "吐司"], "staple", "cooked", "per100g",
     "方形主食面包（食パン）"),
    ("01208", "全麦面包", ["全麦吐司"], "staple", "cooked", "per100g",
     "全粒粉パン；官方标注为推定值"),
    ("01048", "煮中华面", ["面条", "煮面", "碱水面"], "staple", "cooked", "per100g",
     "中華めん ゆで；麻辣烫等熟面条候选"),
    ("01039", "煮乌冬面", ["乌冬面"], "staple", "cooked", "per100g",
     "うどん ゆで"),
    # --- 蛋奶豆 ---
    ("12005", "水煮全蛋", ["煮鸡蛋", "白煮蛋", "水煮蛋", "煮蛋"], "eggDairySoy", "cooked", "per100g",
     "全蛋去壳可食部；官方废弃率11%指蛋壳，勿对去壳重量重复扣除"),
    ("12004", "生鸡蛋", ["鸡蛋", "全蛋"], "eggDairySoy", "raw", "per100g",
     "全蛋去壳可食部；用于烹饪配方计算"),
    ("04052", "无调整豆乳", ["豆浆", "无糖豆浆", "豆乳"], "eggDairySoy", "unknown", "per100g",
     "普通豆乳（无调整）；早餐店/品牌无糖豆浆是否对应需单独确认"),
    ("04032", "木绵豆腐", ["北豆腐", "老豆腐", "卤水豆腐"], "eggDairySoy", "unknown", "per100g",
     "加工豆制品（凝固剂型未细分时取此条）"),
    ("04033", "绢豆腐", ["嫩豆腐", "内酯豆腐"], "eggDairySoy", "unknown", "per100g",
     "絹ごし豆腐"),
    ("13003", "普通牛乳", ["牛奶", "牛乳"], "eggDairySoy", "unknown", "per100g",
     "液状乳·普通牛乳；日本成分表按 100 g 口径发布"),
    # --- 肉鱼虾 ---
    ("11220", "鸡胸肉·生", ["鸡胸肉"], "meatSeafood", "raw", "per100g",
     "若どり むね 皮なし 生；去骨去皮可食部"),
    ("11288", "烤鸡胸肉", ["烤鸡胸"], "meatSeafood", "cooked", "per100g",
     "若どり むね 皮なし 焼き"),
    ("11127", "猪里脊·赤肉", ["猪里脊", "里脊", "瘦肉"], "meatSeafood", "raw", "per100g",
     "大型種 ロース 赤肉 生；带脂部位请改用配方层另行估算"),
    ("10415", "南美白对虾·生", ["白灼虾", "虾", "白煮虾"], "meatSeafood", "raw", "per100g",
     "養殖バナメイえび；废弃率20%指虾壳，白灼后重量变化本条不含"),
    # --- 蔬果 / 菌藻 / 薯芋玉米 ---
    ("06226", "大葱·软白", ["大葱", "葱白"], "vegetableFruit", "raw", "per100g",
     "根深ねぎ 葉 軟白 生；废弃率40%指根须与老叶"),
    ("06061", "圆白菜·生", ["包菜", "卷心菜", "圆白菜"], "vegetableFruit", "raw", "per100g",
     "キャベツ 結球葉 生"),
    ("06263", "西兰花·生", ["西兰花", "花椰菜"], "vegetableFruit", "raw", "per100g",
     "花序 生；废弃率35%指茎部硬皮"),
    ("06264", "水煮西兰花", ["煮西兰花"], "vegetableFruit", "cooked", "per100g",
     "花序 ゆで"),
    ("06065", "黄瓜·生", ["黄瓜"], "vegetableFruit", "raw", "per100g",
     "果実 生"),
    ("06245", "青椒·生", ["青椒", "菜椒"], "vegetableFruit", "raw", "per100g",
     "青ピーマン 果実 生"),
    ("06182", "番茄·生", ["西红柿", "番茄"], "vegetableFruit", "raw", "per100g",
     "赤色トマト 果実 生"),
    ("06153", "洋葱·生", ["洋葱"], "vegetableFruit", "raw", "per100g",
     "りん茎 生"),
    ("06312", "生菜·生", ["生菜", "结球生菜"], "vegetableFruit", "raw", "per100g",
     "レタス 土耕栽培 結球葉 生"),
    ("06291", "绿豆芽·生", ["豆芽", "绿豆芽"], "vegetableFruit", "raw", "per100g",
     "りょくとうもやし 生"),
    ("06287", "黄豆芽·生", ["黄豆芽"], "vegetableFruit", "raw", "per100g",
     "だいずもやし 生"),
    ("06233", "大白菜·生", ["白菜", "大白菜"], "vegetableFruit", "raw", "per100g",
     "はくさい 結球葉 生"),
    ("06132", "白萝卜·生", ["萝卜", "白萝卜"], "vegetableFruit", "raw", "per100g",
     "だいこん 根 皮つき 生"),
    ("06160", "青梗菜·生", ["油菜", "青菜", "小油菜"], "vegetableFruit", "raw", "per100g",
     "チンゲンサイ 葉 生；与国内小油菜为近似种，匹配前需人工确认"),
    ("08007", "木耳·水发煮", ["木耳", "黑木耳"], "vegetableFruit", "cooked", "per100g",
     "きくらげ ゆで（泡发水煮）"),
    ("08006", "干木耳", ["干木耳"], "vegetableFruit", "raw", "per100g",
     "きくらげ 乾；按泡发前干重使用"),
    ("06175", "甜玉米·生", ["玉米", "生玉米", "甜玉米"], "vegetableFruit", "raw", "per100g",
     "スイートコーン 未熟種子 生；废弃率50%指玉米芯；糯玉米非此条目"),
    ("06176", "煮甜玉米", ["煮玉米"], "vegetableFruit", "cooked", "per100g",
     "スイートコーン 未熟種子 ゆで；废弃率30%指玉米芯"),
    ("02018", "蒸土豆", ["土豆", "马铃薯", "蒸土豆"], "vegetableFruit", "cooked", "per100g",
     "じゃがいも 塊茎 皮なし 蒸し"),
    # --- 油脂调味 ---
    ("14008", "菜籽油", ["食用油", "炒菜油", "菜油"], "oilSeasoning", "unknown", "per100g",
     "なたね油；纯脂肪"),
    ("14002", "芝麻油", ["香油", "麻油"], "oilSeasoning", "unknown", "per100g",
     "ごま油"),
    ("17007", "浓口酱油", ["酱油", "生抽"], "oilSeasoning", "unknown", "per100g",
     "こいくちしょうゆ"),
    ("17012", "食盐", ["盐", "食盐"], "oilSeasoning", "unknown", "per100g",
     "食塩"),
    # --- 饮料 / 种实 ---
    ("16045", "黑咖啡·冲泡", ["咖啡", "黑咖啡"], "oilSeasoning", "unknown", "per100g",
     "コーヒー 浸出液；无糖无奶冲泡液，日本成分表按 100 g 口径发布"),
    ("05027", "调味炒葵花籽", ["葵花籽", "瓜子"], "vegetableFruit", "cooked", "per100g",
     "ひまわり フライ 味付け；去壳可食部"),
]

CATEGORY_ORDER = ["staple", "eggDairySoy", "meatSeafood", "vegetableFruit", "oilSeasoning"]


def parse_value(raw):
    """MEXT 单元格 → {value, flag}。flag: measured/estimated/trace/unmeasured。"""
    if raw is None:
        return {"value": None, "flag": "unmeasured"}
    s = str(raw).strip()
    if s in ("", "-", "—"):
        return {"value": None, "flag": "unmeasured"}
    if s == "Tr":
        return {"value": None, "flag": "trace"}
    estimated = s.startswith("(") and s.endswith(")")
    num = s[1:-1] if estimated else s
    try:
        value = float(num)
    except ValueError:
        return {"value": None, "flag": "unmeasured"}
    return {"value": value, "flag": "estimated" if estimated else "measured"}


def refuse_value(raw):
    if raw is None:
        return None
    try:
        return float(str(raw).strip())
    except ValueError:
        return None


def main(xlsx_path: str) -> None:
    source_sha = hashlib.sha256(Path(xlsx_path).read_bytes()).hexdigest()
    wb = openpyxl.load_workbook(xlsx_path, read_only=True)
    ws = wb["表全体"]

    wanted = {no: (zh, aliases, cat, state, basis, note) for no, zh, aliases, cat, state, basis, note in ENTRIES}
    found = {}
    for r in ws.iter_rows(min_row=13, max_col=24, values_only=True):
        no = str(r[1] or "").strip()
        if no not in wanted:
            continue
        group = str(r[0] or "").strip()
        found[no] = {
            "id": f"mext-{no}",
            "source": SOURCE_AGENCY,
            "foodNo": no,
            "foodGroup": group,
            "nameZh": wanted[no][0],
            "nameOriginal": re.sub(r"[\u3000\n]+", " ", str(r[3] or "")).strip(),
            "aliases": wanted[no][1],
            "category": wanted[no][2],
            "preparationState": wanted[no][3],
            "basis": wanted[no][4],
            "refusePercent": refuse_value(r[4]),
            "nutrients": {
                "kcal": parse_value(r[6]),
                "proteinG": parse_value(r[9]),
                "fatG": parse_value(r[12]),
                "carbsG": parse_value(r[20]),
                "fiberG": parse_value(r[18]),
                "sodiumMg": parse_value(r[23]),
            },
            "sourceUrl": SOURCE_BASE_URL.format(group=int(group), no=no),
            "note": wanted[no][5],
        }

    missing = [no for no in wanted if no not in found]
    if missing:
        raise SystemExit(f"条目未在官方表中找到: {missing}")

    catalog = {
        "schemaVersion": 1,
        "source": {
            "agency": SOURCE_AGENCY,
            "title": SOURCE_TITLE,
            "edition": "八订增补2023（含2026-03-27勘误）",
            "downloadUrl": DOWNLOAD_URL,
            "errataUrl": ERRATA_URL,
            "downloadedAt": "2026-09-17",
            "fileSha256": source_sha,
            "termsOfUse": "二次利用须注明出处：文部科学省《日本食品标准成分表（八订）增补2023年》",
        },
        "entries": [found[no] for no, *_ in ENTRIES],
    }
    out = Path(__file__).resolve().parents[2] / "Resources" / "FoodCatalog" / "food_catalog_v1.json"
    out.write_text(json.dumps(catalog, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"wrote {out} with {len(found)} entries; source sha256={source_sha}")


if __name__ == "__main__":
    main(sys.argv[1])
