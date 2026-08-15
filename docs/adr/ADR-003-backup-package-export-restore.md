# ADR-003：以本地备份包作为数据导出与重装恢复机制

> 状态：Accepted
>
> 日期：2026-08-16
>
> 接受依据：用户于 2026-08-16 逐项拍板——同意备份包方案；只导出解析后数据、不导出原始样本；默认明文；照片不随备份导出；恢复入口为引导页 + 设置页；导出时机为退后台自动 + 手动按钮

## 1. 背景

用户提出三项需求：

1. 历史数据的保存地址可自定义（例如 iCloud Drive 文件夹），以便电脑上的 agent 读取；
2. 所有保存的数据结构化、标准化；
3. 重装 App 后可以回读之前的数据，避免历史数据丢失。

现状：全部数据存本地 SQLite（`Application Support/HealthManager/health.sqlite`，WAL），卸载即清除。README 隐私章节当前写明"卸载 App = 清除所有本地数据"。

**关键约束**：SQLite 运行库（WAL 机制）不能被直接放进 iCloud Drive。iCloud 按整文件同步，多进程/多设备同时写入会引发同步冲突与文件损坏——这是已被广泛验证的坑。因此"把数据库文件路径指到 iCloud"不可行，必须采用备份包方案。

## 2. 决策

### 2.1 备份包模式

App 把解析后的数据写成标准文件，放入用户选定的文件夹（通常是 iCloud Drive，App 将其视为普通本地文件夹）；重装后通过同一文件夹恢复。运行库本身始终留在沙盒内。

备份包目录结构：

```
HealthManagerBackup/
├── manifest.json          # format_version、app_version、exported_at、每文件记录数 + 校验和
├── meal_records.jsonl     # 每行一条 JSON，字段名与 docs/export-schema.md 一致
├── meal_items.jsonl
├── activity_metrics_daily.jsonl
├── body_metrics_daily.jsonl
├── medication_plans.jsonl
├── medication_logs.jsonl
├── source_coverage_daily.jsonl
├── data_quality_daily.jsonl
├── missing_data_alerts.jsonl
├── daily_summaries.jsonl
├── weekly_summaries.jsonl
└── README.md              # 写给外部 agent 的格式说明
```

### 2.2 导出范围（14 张表 → 导出 11 张）

| 导出 | 不导出 |
|---|---|
| activity_metrics_daily、body_metrics_daily | health_samples_raw（原始样本，用户明确不要） |
| meal_records、meal_items | sync_jobs、backfill_report（纯运维数据） |
| medication_plans、medication_logs | sync_anchors（重装后增量同步以 nil 锚点自然补齐，sample_uuid 去重保证不重复） |
| source_coverage_daily、data_quality_daily、missing_data_alerts | |
| daily_summaries、weekly_summaries | |

### 2.3 餐食照片不导出

照片留在 App 沙盒（`Application Support/MealPhotos/`），不进备份包。`meal_records.photo_path` 仍照常导出，恢复后文件不存在的照片位置显示「照片已丢失」占位，不做静默删除。

### 2.4 明文存储

备份内容默认明文。设置页与隐私说明如实表述：数据写入用户自行选择的文件夹（含 iCloud Drive 时由用户 Apple 账号保护），App 自身不上传。

### 2.5 向前兼容契约

- **格式只增不改**：导出的字段名一经发布永不改名、不删除语义；新增数据只追加字段。
- **manifest 版本驱动**：导入器按 `format_version` 走升级链；旧版本格式导入前自动迁移；遇到比当前 App 更新的未知版本，明确报错并拒绝导入，绝不猜测。
- **导入幂等**：只补缺、不覆盖（按主键），恢复流程可安全重跑。
- **回环测试**：自动化测试执行「导出 → 全新数据库导入 → 逐行逐字段比对」，作为格式变更的强制保证。

### 2.6 恢复入口与触发时机

- 重装后首次启动：引导页增加「恢复历史数据」步骤（选择备份文件夹 → 校验 manifest → 预览 → 导入）；
- 设置页保留手动恢复入口；
- 导出触发：退到后台自动导出 + 手动「立即备份」按钮；不做「每次记录后立即导出」（保持省电，如未来 agent 需要准实时读取，以设置开关追加）。

### 2.7 App 配置快照与投影表恢复语义

- 备份包包含 `settings.json`：对账阈值、仪表盘卡片布局、AI 非敏感配置（不含 API Key，密钥留在 Keychain）。
- 五张投影表（activity/body_metrics_daily、source_coverage_daily、data_quality_daily、missing_data_alerts）恢复时用覆盖语义；其余用户创作表只补缺、不覆盖。原因：重装后无原始样本时启动补算会先写空投影行，只补缺会被空行挡住（2026-08-16 真机恢复已实测该缺陷并修复）。
- 备份位置书签存 Keychain（卸载重装后仍有效），不进备份包。

## 3. 已考虑方案

### 方案 A：数据库文件直接放 iCloud

不可行——WAL 文件级同步冲突会损坏数据（见背景关键约束）。

### 方案 B：备份包（本 ADR 选择）

运行库留在本地，导出物为稳定的、版本化的 JSONL + manifest。既满足 agent 可读、重装可恢复，又隔离了 SQLite 运行文件与云同步的冲突风险。

## 4. 后果

1. 设置页与引导页需要新增「数据备份位置」选择、立即备份、恢复历史数据等 UI；文案遵循 ADR-002 第 5 条（不得出现"任何数据都不会上传"类绝对表述）。
2. 新增导出/导入模块与字段字典文档 `docs/export-schema.md`（供外部 agent 与未来开发者共同遵守）。
3. 重装后照片缺失，需要一处占位 UI 改动。
4. 原始样本不导出意味着：恢复后历史详情仍可通过 HealthKit 增量补齐（数据由 Apple 健康云同步），App 本地不再保留未解析的原始行——这是用户明确接受的取舍。
5. 范围外：不迁移 SQLite 文件本身、不做备份加密、不接入第三方云存储、不改变 HealthKit 数据本身的存储位置。
