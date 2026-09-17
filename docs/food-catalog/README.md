# 离线食品目录（food_catalog_v1.json）构建记录

## 来源

- 机构：日本文部科学省（MEXT）
- 数据集：《日本食品标准成分表（八订）增补2023年》，含 2026-03-27 勘误
- 下载文件：[第2章データ（xlsx）](https://www.mext.go.jp/content/20260327-mxt_kagsei-mext-000029402_02.xlsx)
- 正誤表：[20260327-mxt_kagsei-mext-000029402_16.xlsx](https://www.mext.go.jp/content/20260327-mxt_kagsei-mext-000029402_16.xlsx)
- 下载日期：2026-09-17
- 源文件 SHA-256：`0d5a77077dd6cd91cbc2e6e317b8b218a38728c409eed452f1c10635a0d3099c`
- 使用条件：二次利用须注明出处（文部科学省《日本食品标准成分表（八订）增补2023年》）；App 内「营养表」来源说明页已署名。

## 构建

```bash
python3 docs/food-catalog/build_catalog.py <下载的xlsx路径>
```

生成 `Resources/FoodCatalog/food_catalog_v1.json`（41 条，每 100 g 可食部分）。

## 取值口径

| 字段 | 官方列（成分識別子） | 说明 |
|---|---|---|
| kcal | ENERC_KCAL | 原表能量，不做 4/4/9 重算 |
| proteinG | PROT- | たんぱく質（普通列，非氨基酸组成量） |
| fatG | FAT- | 脂質（非脂肪酸当量列） |
| carbsG | CHOCDF- | 炭水化物（表头印刷列，含纤维） |
| fiberG | FIB- | 食物繊維総量 |
| sodiumMg | NA | ナトリウム |

`-` → `unmeasured`（未测定，App 显示 "—"）；`Tr` → `trace`（微量，不写 0）；`(x)` → `estimated`（官方推定值，展示时注明）。

## 更换/更新数据包时

1. 重新下载官方文件并核对勘误版本；
2. 记录新 SHA-256 与下载日期于本文件与目录 JSON 的 `source` 字段；
3. 目录更新不得改变任何已保存餐次的历史快照（ADR-001/ADR-004）；
4. 资源文件写入失败时保留现有版本，不得把空资源当成功更新。
