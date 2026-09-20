# S13 晚间真机验收清单

当前状态：`PENDING`。软件回归证据见 [STAGE-RESULTS.md](STAGE-RESULTS.md)；这份清单只包含必须连接、解锁或操作真机的部分。不要在开始前安装候选版：当前手机上的 0.8.1（16）是唯一可直接测量的真实基线。

## 1. 开始条件和停止条件

开始条件：

- NortePro 的 iPhone 已连接、解锁、Developer Mode 可用；低电量模式关闭，电量与热状态记录下来。
- 当前 0.8.1（16）可以正常打开，已有健康数据和 HealthBridge 配置保持原样。
- 不执行历史回补、Bridge reset、删除记录或新建测试健康样本。

立即停止：

- App 启动后迁移失败、记录数量明显下降、Bridge dataset/epoch 意外变化。
- 自动同步过程中出现持续崩溃、无限 spinner、同一类型无界重试或需要 reset 才能继续。
- 备份恢复或 Keychain 验证提示会覆盖真实数据，而尚未取得可回滚备份。

## 2. 安装前先测真实基线

对手机上现有 0.8.1（16）做 20 次**进程冷启动**。每轮先完全终止 App 进程，再启动；不要把从后台切回算作冷启动。记录：

| 轮次 | 版本 | Bridge 开关 | 启动到首批有效卡片秒数 | 卡片是否先于同步完成 | 异常 |
|---:|---|---|---:|---|---|
| 1–20 | 0.8.1 (16) | 开/关实际值 |  |  |  |

基线版本没有本轮新增的 `startup` 里程碑，因此 `snapshotAvailable` 记为 `unavailable`，不要估造。20 轮完成后保存原始单次值；p95 用排序后的第 19 个样本，不用平均值替代。

## 3. 安装候选版前的数据保全快照

在不修改数据的前提下记录：

- App 版本/build、数据库可见记录总览、最近一天与一条较老日期的关键卡片值。
- HealthBridge 当前 dataset、epoch、最高 outbox sequence、最高 acknowledged sequence、pending 数。
- `sync_anchors` 类型数量及每类 anchor 是否存在；只保存存在性/摘要，不导出凭据或健康正文到聊天。
- 饮食记录数量与非空 `hk_sync_id` 数量；选 2 条历史饮食记录记下日期和 syncID 摘要。
- 当前备份导出可完成；保留备份文件，不立即做破坏性恢复。

取得这些证据后再覆盖安装候选版。安装不是发布；不改版本 tag、不提交、不推送。

## 4. 候选版 20 次冷启动

同一设备、同一数据量、相同 Bridge 开关和尽量相近的电量/热状态，做 20 次进程冷启动。Console 过滤：

```text
subsystem == "com.norte.HealthManager" AND category == "startup"
```

每轮保存同一个 `session` 的 `database_ready`、`environment_ready`、`recovery_ready`、`initial_snapshot_requested` 和 `snapshot_available`/`initial_snapshot_error` 的 `elapsedMs`。另记录肉眼/录屏的首批有效卡片可见时间：

| 轮次 | snapshotAvailable ms | 首批有效卡片 ms | 首次新数据可见 ms | initialSnapshotError | 异常 |
|---:|---:|---:|---:|---|---|
| 1–20 |  |  |  |  |  |

验收目标：已有本地数据的首批有效卡片 p95 ≤ 1 秒，并且在 HealthKit 或 Bridge 延迟时仍先展示。分别计算 `snapshotAvailable` 和实际卡片可见的 p50/p95/max。

## 5. 自动追新与恢复，每个场景 3 轮

只使用真实外部来源自然产生的数据，或已存在记录的只读观察；不向真实健康库写入/删除伪造测试记录。

### A. 前台自动追新

1. 让 Garmin/米家/手表等真实来源产生并写入一条可识别的新记录。
2. 打开 HealthManager，保持在趋势页；不点击“立即同步”。
3. 记录外部来源到 Apple Health 的时间、Apple Health 到本 App 卡片更新的时间和同步中心最终状态。
4. 小批量、HealthKit 正常可读且无历史回补时，App 内增量可见目标 p95 ≤ 3 秒。

### B. 锁屏失败后解锁恢复

1. 锁屏并等待真实来源产生/写入更新。
2. 确认系统投递机会发生时设备仍锁定；不手动同步。
3. 解锁并进入 App，检查同步中心先显示等待解锁或持久待办，随后自动收敛。
4. 检查没有对 28 类逐个重复三次查询，也没有把锁屏说成“全部权限拒绝”。

### C. 后台预算中断后前台恢复

1. 在有 pending work 时把 App 送入后台，让系统机会或调试触发开始。
2. 在任务未完成时使其到期/中断，然后重新进入前台。
3. 检查 pending generation 和 dirty dates 仍在，前台自动续跑；不点击手动同步。
4. 正常 completion 与 expiration 只能完成一次，最终状态不能虚报 completed。

每个场景记录 3 轮：请求时间、HealthKit 可读时间、本地 raw 提交时间、投影完成/卡片可见时间、最终 pending/deferred/failed 类型。

## 6. Keychain 与恢复门

软件套件中唯一失败是未签名测试宿主的 Keychain `-34018`。在候选真机上验证：

1. 读取当前备份位置与 HealthBridge bookmark，确认升级后仍有效。
2. 在不覆盖真实备份的测试目录上执行选择目录、保存、重启后读取、清除/重新选择 round-trip。
3. 开始一次隔离恢复时，确认 runner 先排空；成功后 marker 清除且原 pending 保留。
4. 失败/取消恢复时 marker 必须保留，不允许晚到 HealthKit callback 覆盖恢复值。

恢复验证必须使用可回滚副本；不要为了让测试通过清除真实 anchors 或 HealthBridge outbox。

## 7. 安装后数据保全复核

与第 3 节逐项对照：

- raw UUID 集合摘要和记录数的差异能由期间真实新增/删除解释。
- anchors 仍存在，时间只因真实同步推进。
- 两条饮食记录及其 `hk_sync_id` 未丢失；新增写回没有制造重复。
- 历史删除仍生效；120 天前的真实变化可以投影到对应旧日期。
- HealthBridge dataset/epoch 未因升级改变；acknowledged sequence 单调不退，未确认批次可继续发布。
- 备份恢复的 daily aggregate 在没有 raw 覆盖时没有被清空。

## 8. 终态判定

- `PASS`：20 次候选冷启动达到目标；三类自动恢复各 3 轮收敛；Keychain round-trip 和数据保全通过；没有依赖手动同步补救。
- `PENDING`：系统没有给后台机会、外部来源没有产生可辨识记录，或证据轮数不足。
- `FAIL`：确认漏请求、无限等待、晚回调覆盖、数据丢失、错误清空汇总、虚报完成或冷启动目标显著未达。

完成后把原始 20 轮数据、3×3 场景记录和对照摘要补入 `STAGE-RESULTS.md` S13；不要只写平均值或“体感变快”。
