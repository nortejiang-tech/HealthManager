# STAGE-009：item4-7 真机清单（照片、可访问性、睡眠、observer）

> 作用：为 v0.3 发布门补齐 item4-7 真机门；任何未执行项只可标为 INCOMPLETE，不得推断。
>
> 固定起点：`2e3b038c4d5722d507874feaea90002fc2379e66`（或后续 STAGE-009 合格 checkpoint 后的同一逻辑基线）。
>
> 编写者：主架构师

## 一、执行边界（必须严格执行）

1. 不卸载、不清空数据库、不手改 SQLite，不做 debug seed。
2. 每个步骤都必须保留独立证据目录（脚本输出、图片、日志、xcresult、sqlite diff）：
   - `/tmp/healthmanager-stage009-item45-device-<YYYYMMDD>-attemptNN/`
3. 真实安装前必须复核：
   - 备份可恢复状态
   - 现有 App 的 `com.norte.HealthManager` 与 Team `K8RVJSC4NU`
   - 覆盖安装后的签名身份可闭环到同一 `application-identifier` 前缀
4. 每项先记录“安装前快照”与“安装后快照”（至少一次完整 DB+照片快照）；差分仅对新建/改动/删除的真实测试对象。任何异常先停并转入修复 STAGE。

## 二、共用脚本（统一执行，避免边界漂移）

### 1) 设备安装后只读备份数据库与照片引用

```bash
TS=$(date +%Y%m%d-%H%M%S)
WORKROOT=/tmp/healthmanager-stage009-item45-device-${TS}
mkdir -p "$WORKROOT/reports"

# 1) 将已导出的真实 App 容器路径赋值给 APP_CONTAINER 后再执行
# 常见来源：Xcode Devices and Simulators 的 "Download Container..." 导出路径
# export: com.norte.HealthManager/HealthManager.xcappdata 下的实际应用容器
# APP_CONTAINER=/tmp/.../com.norte.HealthManager

sqlite3 "$APP_CONTAINER/Application Support/HealthManager/health.sqlite" <<'SQL' > "$WORKROOT/reports/db-audit.txt"
.headers on
.mode line
PRAGMA foreign_key_check;
PRAGMA integrity_check;
PRAGMA user_version;
SELECT name FROM sqlite_master WHERE type='table' AND name IN ('meal_records','meal_items','meal_photos');
SELECT 'meal_records_count', COUNT(*) FROM meal_records;
SELECT 'meal_items_count', COUNT(*) FROM meal_items;
SELECT 'meal_photos_count', (SELECT COUNT(*) FROM meal_photos) FROM sqlite_master WHERE type='table' AND name='meal_photos';
SELECT 'sync_jobs_running', COUNT(*) FROM sync_jobs WHERE state IN ('pending','running');
SELECT 'sync_jobs_failed', COUNT(*) FROM sync_jobs WHERE state='failed';
SELECT 'meal_records_with_photo_ref', COUNT(*) FROM meal_records WHERE COALESCE(LENGTH(photo_path),0) > 0;
SELECT 'photo_path_components_count', COUNT(*) FROM (
  SELECT DISTINCT TRIM(value) AS photo_path
  FROM meal_records,
    json_each('["' || REPLACE(COALESCE(photo_path, ''), ',', '","') || '"]')
  WHERE COALESCE(photo_path, '') <> ''
);
SELECT 'health_samples_raw_count', COUNT(*) FROM health_samples_raw;
SELECT 'active_sync_jobs', COUNT(*) FROM sync_jobs WHERE state IN ('pending','running');
SELECT 'active_backfill_reports', COUNT(*) FROM backfill_report WHERE state IN ('pending','running');
SQL

find "$APP_CONTAINER/Library/Caches/MealPhotos" -type f | wc -l > "$WORKROOT/reports/mealphotos-count.txt"
cp "$APP_CONTAINER/../healthmanager-app.json" "$WORKROOT/reports/" 2>/dev/null || true
cp "$APP_CONTAINER/../device-details.json" "$WORKROOT/reports/" 2>/dev/null || true
```

### 2) meals 与照片路径核验（以 `meal_records.photo_path` 为准）

```bash
sqlite3 "$APP_CONTAINER/Application Support/HealthManager/health.sqlite" <<'SQL' > "$WORKROOT/reports/photo-paths.csv"
.headers on
.mode csv
SELECT id, created_at, meal_name, photo_path, hk_sync_id FROM meal_records ORDER BY id DESC;
SQL

sqlite3 "$APP_CONTAINER/Application Support/HealthManager/health.sqlite" <<'SQL' > "$WORKROOT/reports/photo-paths-and-db-orphan-candidates.txt"
.headers on
.mode line
SELECT name FROM sqlite_master WHERE type='table' AND name='meal_photos';
SELECT id, LENGTH(COALESCE(photo_path,'')) AS photo_path_len
FROM meal_records
WHERE COALESCE(photo_path,'') <> ''
ORDER BY id DESC;
SQL

find "$APP_CONTAINER/Library/Caches/MealPhotos" -type f | sed 's#^./##' | sort > "$WORKROOT/reports/photo-files-list.txt"
```

> 注：如确认项目使用 `meal_records.photo_path` 作为唯一引用源，建议以该列拆分后的 `photo_path` 与
> `photo-files-list.txt` 做差异比对；无 `meal_photos` 表时不要求额外连接表。

### 3) HealthKit 事件核验

建议使用 `UI` + `HealthKit` App + 数据库脚本联动。删除/写入/重开后至少执行：

- 同步前后 `health_samples_raw` 与相关 `meal_records.hk_sync_id` 对比
- `HKSample` 真实删除行为通过 Health app“营养”或“健康数据来源”视角人工确认

## 三、Item4：PhotosPicker / 相机生命周期

### 目标
确认“导入/替换/取消/保存/删除”动作后，用户可预见效果正确、数据库引用与真实文件一致、无误删或孤儿扩增。

### 关键动作
1. 安装后选定一个已有真实测试餐次（只改此餐次）打开编辑：
   - 新增照片（相册）
   - 再新增第二张照片（替换为追加或覆盖，按当前交互）
   - 保存
2. 立刻记录：
   - `meal_records.id` 对应行的 `photo_path`
   - `MealPhotos/*` 目录文件数与具体新增文件名
3. 重复导入相机拍照（如支持）并保存
4. 在编辑内触发“移除/清空照片”路径并保存
5. 测试“取消编辑不保存”路径（导入/替换后取消）不应落盘

### 判定

- PASS:
  - 每次保存只变更目标餐次/目标动作涉及的照片引用；
  - 移除动作不保留旧文件引用；新引用与文件同源可追溯；
  - 取消操作不新增/改写 `meal_records.photo_path`；
  - `meal_records.photo_path` 与 `MealPhotos/*` 真实文件差值无新增未引用孤儿（与基线对比可接受 `+1/-1` 等与测试动作一致）。
- FAIL:
  - 照片路径出现空格、路径拼接错误、未解码中文空白或重复；
  - 取消后仍有新增照片被持久化；
  - 删除后文件仍被引用（数据库）或被引用后又被系统删失；
  - 孤儿文件大幅增加且无法与测试动作解释。
- INCOMPLETE: 任一日志、脚本或健康权限无法复现时。

## 四、Item5：VoiceOver、Dynamic Type、44pt hit area 与 sheet 可用性

### 目标
验证核心入口的无障碍可达性与操作可见性，不做视觉推断替代交互确认。

### 关键动作
1. 打开 App 后，进入饮食列表/编辑器与 More：
   - `VoiceOver` 开启，检查从首页到“饮食/用药/趋势/更多/设置”可达性顺序；
   - 核对每个关键控件有可读 `label/value`，不依赖技术标识符文本。
2. 在 Dynamic Type 从标准到最大字号（或接近最大）切换下重复关键动作：
   - 今日汇总卡
   - 餐食证据展开
   - 复用入口
   - 编辑器保存/取消/移除
3. 检查餐食证据、复用、删除相关 sheet 在 44pt 可点区域下可稳定打开与关闭。
4. 检查 `Today` “计划/动作时间”语义未互换读法。

### 判定

- PASS:
  - 关键控件可线性到达（不会“跳出交互树”）；
  - 动作前后可重复完成；
  - 关键命中区域至少覆盖 44pt touch target；
  - 最大字号下无关键文案被截断导致点击失效。
- FAIL:
  - 核心按钮不可达；
  - VO 读数与用户可理解语义冲突（如错误把“计划时刻”读作“动作时刻”）；
  - 列表/按钮在最大字号下点击无效。
- INCOMPLETE:
  - 未执行 VO 打开路径、未录屏或未截图日志，或设备中语言切换异常中断。

## 五、Item6：睡眠数据跨午夜与来源组合验证（真实设备）

### 目标
证实真实 Apple Watch / iPhone / 第三方 sleepAnalysis 在真实数据上：
- 跨午夜归属准确
- inBed/asleep 来源组合不误导
- 详细阶段重叠被合理汇总（或被明确隔离）

### 关键动作
1. 记录 `activity_metrics_daily` 与 `health_samples_raw` 相关行（按当日）
2. 在真实手表/手机/第三方来源下采样至少一个“跨午夜”时段
3. 观察 Dashboard / Today 显示及来源明细是否一致
4. 导出健康样本明细并与应用展示进行逐项比对（至少抽检 5 个跨午夜窗口）

### SQL 采样（示例）

```bash
sqlite3 "$APP_CONTAINER/Application Support/HealthManager/health.sqlite" <<'SQL' > "$WORKROOT/reports/sleep-cross-midnight.csv"
.headers on
.mode csv
SELECT hk_type, source_bundle_id, source_name, start_at, end_at, value, value2, unit, is_deleted
FROM health_samples_raw
WHERE hk_type='HKCategoryTypeIdentifierSleepAnalysis'
ORDER BY start_at DESC
LIMIT 200;

SELECT day_start, sleep_seconds, sleep_efficiency
FROM activity_metrics_daily
ORDER BY day_start DESC
LIMIT 30;
SQL
```

### 判定

- PASS:
  - 跨午夜归属在 UI 与数据库一致；
  - inBed/asleep 不发生类型混淆；
  - 详细阶段重叠与来源组合可解释且不会把 Asleep 外推/重复计入。
- FAIL:
  - 出现双计、来源拼接错误、inBed 计入 Asleep、重复计时；
  - 今日与昨日夜间窗口明显错配。
- INCOMPLETE:
  - 未能拿到真实 sleepAnalysis 的持续样本。

## 六、Item7：后台 observer / 增量同步行为

### 目标
验证 App 覆盖安装后首次启动与持续运行期间，对真实 HealthKit 样本变化响应稳定，不出现重复、长驻 pending/running、或跨进程状态回退。

### 关键动作
1. 安装后先记录首屏 DB 与 sync_jobs
2. 在 Health app 写入/删除一组饮食/活动（非测试关键字段）；
3. 等待 2～10 分钟，观察：
   - observer 是否触发
   - `sync_jobs` 从 running→succeeded/failed 的收敛
   - 是否出现重复同样本 job
4. 再进入应用手动触发 1 次 sync，确认与后台行为一致。

### SQL 采样

```bash
sqlite3 "$APP_CONTAINER/Application Support/HealthManager/health.sqlite" <<'SQL' > "$WORKROOT/reports/sync-jobs-final.txt"
.headers on
.mode line
SELECT COUNT(*) AS active_sync_jobs FROM sync_jobs WHERE state IN ('pending','running');
SELECT id,state,job_type,trigger,start_at,ended_at,error_code,error_message,stats_json
FROM sync_jobs
ORDER BY start_at DESC
LIMIT 80;
SELECT id,state,created_at,ended_at,error_code FROM backfill_report ORDER BY created_at DESC LIMIT 50;
SQL
```

### 判定

- PASS:
  - 真实样本变化后会触发增量路径，最终 `active_sync_jobs=0`；
- FAIL:
  - observer 重复触发导致 job 风暴；
  - 长驻 `pending/running`；
  - 错误 code 不解释导致 UI 与数据库状态不一致；
  - 观察到未授权/禁用类型被吞掉但显示成功。
- INCOMPLETE:
  - 核心日志/测试路径缺失。

## 七、失败与接管规则（与 Coder 协作边界）

1. 单项 FAIL/INCOMPLETE 触发本轮真机完整 PASS 中止；
2. 若是：
   - migration、HealthKit 幂等、照片生命周期、后台 observer、Sleep 数据解释错误；
   则由主架构师接管修复 STAGE；低风险可视化/文案可先给 Coder 单步返工。
3. 每项最终结论必须同步写回 `docs/stages/STAGE-009-v03-release-gate.md` 的「真机清单与状态」节。
