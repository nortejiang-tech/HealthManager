# USDA 真实检索验证证据（2026-09-18）

## 验证内容

按方案 §8.1 要求执行的一次真实官方搜索与详情取回（非模拟样本）：

- **搜索**：`GET /foods/search?query=dark chocolate 70-85%&dataType=Foundation,SR Legacy,FNDDS&pageSize=5`
  - 命中 314 条；首条 `SR Legacy #170273`：Chocolate, dark, 70-85% cacao solids
  - 注意第 3 条 `Oil, sunflower…` 说明结果含形态差异候选——与 App 的候选降级展示逻辑一致
- **详情**：`GET /food/170273`（SR Legacy，发布 4/1/2019）

## 详情字段映射核对（USDA nutrient ID → App 字段）

| nutrient ID | 名称 | 官方值 | App 字段 |
|---|---|---|---|
| 1008 | Energy | 598.0 kcal | nutrients.kcal（measured，能量规则 energy-1008-kcal） |
| 1003 | Protein | 7.79 g | proteinG |
| 1004 | Total lipid (fat) | 42.63 g | fatG |
| 1005 | Carbohydrate, by difference | 45.9 g | carbsG |
| 1079 | Fiber, total dietary | 10.9 g | fiberG |
| 1093 | Sodium, Na | 20.0 mg | sodiumMg |

与 `Tests/USDASearchAndSuggestionTests` 的固定样本（同 ID 同值）一致：
映射器对该 ID 产出 `usda-170273`、basis=per100g、分类 sweetsSnacks、
版本标签 `FDC-SR Legacy-published-2019-04-01`。

## 说明

- 验证使用 data.gov `DEMO_KEY`（限流共享），生产使用在「设置 → 食材资料库」配置的个人 key；
- 原始响应 JSON 存于本目录（`search-*.json` / `food-*-detail-*.json`），SHA-256 见 git；
- 真机「黑巧克力」端到端添加流程仍属 §8.2 真机验收范围。
