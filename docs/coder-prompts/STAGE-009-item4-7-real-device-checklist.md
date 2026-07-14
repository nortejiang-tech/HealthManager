# 给 Coder 的提示词：STAGE-009 item4-7 真机清单执行

你是执行员（非实现员）。只做真机 item4-7 验证与证据采集，不改产品代码，不改迁移，不提交，不 merge，不 push。每一步按证据输出，不可自行宣告 PASS。

## 0. 固定起点与停止条件

工作目录：`/Users/nortepro/HealthManager`

先执行并上报：

```bash
cd /Users/nortepro/HealthManager
git status --short
git branch --show-current
git rev-parse HEAD
```

预期：

- 分支：`codex/health-planning-20260713`
- 工作树清晰

任一不符，先报告并停止，不做继续动作。

## 1. 先读以下文件

1. `docs/stages/STAGE-009-v03-release-gate.md`
2. `docs/stages/STAGE-009-item4-7-real-device-checklist.md`
3. `NEXT_TASK.md`
4. `docs/stages/STAGE-009R2-healthkit-nutrition-clear-recovery.md`（确认 item3 结果不重复执行）

说明：当前真实 DB 核对时请直接使用 `hk_type` 与 `source_bundle_id` 字段（非 `sample_type`/`source_bundle`）。

## 2. 只读约束与边界

不允许：

- 卸载、清库、删除用户真实数据；
- 修改任何代码、文档（除日志/截图说明）；
- 声称真机 INCOMPLETE 为 PASS。

允许：

- 复现安装前后快照、执行 xcuitest、手工 UI 操作、保存日志与附件；
- 通过系统日志/Health app 辅助核验。

## 3. 交付目标（只做 item4-7）

- item4：照片导入/替换/取消/保存/删除生命周期；
- item5：VoiceOver 读序、最大字号、44pt 命中、sheet 可操作；
- item6：真实 sleepAnalysis 跨午夜、inBed/asleep 与来源组合；
- item7：真实 HealthKit 样本变化后的 observer 增量同步收敛。

每项结论只可为 PASS / FAIL / INCOMPLETE。

## 4. 执行输出（每项都要返回）

### 4.1 统一证据目录

每项都必须创建独立或按轮次目录：

- `/tmp/healthmanager-stage009-item45-device-<YYYYMMDD>-attemptXX/`

目录至少包含：

- `*.xcresult`（有 UI 操作时）
- `reports/*.txt`（SQL 输出）
- `screens/`（关键截图）
- `notes.md`（动作时序和异常）

### 4.2 item4：照片生命周期（必做）

1. 选一个真实非系统/无关餐次，进入编辑；
2. 导入照片 -> 保存 -> 记录 `photo_path`；
3. 替换照片或新增照片 -> 保存 -> 记录 `photo_path` 差异；
4. 触发取消路径 -> 确认无落盘；
5. 删除照片 -> 保存 -> 检查 `photo_path` 与文件目录；
6. 复制 DB 与 `MealPhotos/*` 清单（按 `STAGE-009-item4-7-real-device-checklist.md` 执行）。

### 4.3 item5：VO / Dynamic Type / 44pt

1. 启用 VoiceOver 后执行核心路径；
2. 切最大字号（或最大可用字号）复测：
   - 今日
   - 饮食列表
   - 饮食编辑
   - 证据展开与复用入口
3. 输出 VO 读音关键点与可触达截图；
4. 记录失败则附屏幕录像帧位置。

### 4.4 item6：sleepAnalysis 真实性

1. 导出健康样本摘要 + `activity_metrics_daily`；
2. 复核跨午夜样本与应用显示一致；
3. 抽检至少 5 个跨午夜窗口（日志或截图注记窗口时间）；
4. 记录来源组合（Apple Watch/iPhone/第三方）是否可解释。

### 4.5 item7：observer 与增量 sync

1. 在应用前后台场景下，产生真实 HealthKit 样本变化；
2. 复核 `sync_jobs` 与 `backfill_report`；
3. 记录 active jobs 变化收敛过程；
4. 手动触发一次 sync，对比 observer 路径与手动路径结果一致性。

## 5. 你要回填给主架构师的内容

按以下 JSON 结构回传（字段不能为空）：

```json
{
  "attempt": "",
  "coverage": {
    "item4": "PASS|FAIL|INCOMPLETE",
    "item5": "PASS|FAIL|INCOMPLETE",
    "item6": "PASS|FAIL|INCOMPLETE",
    "item7": "PASS|FAIL|INCOMPLETE"
  },
  "artifact_root": "/tmp/healthmanager-stage009-item45-device-...",
  "fail_details": [
    {"item": "itemX", "evidence": "路径/文件/日志", "risk": "一句话"}
  ],
  "notes": "重要观察点与是否建议主架构师接管"
}
```

并附：

- item4-7 执行后的 git status；
- 关键截图/日志路径；
- 若有 INCOMPLETE，说明确切缺失条件（比如系统权限、系统版本、日志不可复现）。

## 6. 禁止词

- 不要写“理论上会通过”
- 不要写“看起来没问题”
- 不要把 Simulator 结果替代真机结论
- 不要在未执行情况下写 PASS
