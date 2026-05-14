# NEXT_TASK

> V1 已交付（7 个 Round 全部完成）；V2 自主迭代（2026-05-15）完成大部分 v2 候选，见 WORKLOG 末尾「V2 自主交付」节。剩余 v3 候选：
> 1. 饮食照片 AI 识别（拍照已接通，识别留 v3，需要本地 Vision 或离线模型）
> 2. 日周报接 LLM（PRD 要求不联网；等用户决策走 Apple Intelligence / 本地 GGUF / 用户提供 key）
> 3. SourcesView 改读 `health_samples_raw.source_origin`（v2 已落列，UI 层迁移留作清理任务）
> 4. iPad / Mac Catalyst 适配（当前 `TARGETED_DEVICE_FAMILY=1`）

## V1 状态

详见 `WORKLOG.md` 末尾「V1 交付摘要」节。简要：

- 38 个 Swift 文件，`swiftc -typecheck` 0 errors / 0 warnings
- PRD F-001 / F-001A / F-002 / F-003 / F-004 / F-005 / F-006 / R-001 全部完成
- 14 张表（PRD 12 + 2 辅助）全部写入路径打通
- 5 主 tab + 5 二级页面

## v2 候选（按价值排序）

### 高价值
1. **饮食照片 AI 识别**
   - 用 Vision + 后续接 LLM
   - `MealRecord.photoPath` 已留位
   - 暂未实现的 UX：拍照 → 自动识别 calories / macros 草稿 → 用户修正 → 保存

2. **用药系统通知**
   - `MedicationPlan.reminderEnabled` 已留位
   - 需要 `UNUserNotificationCenter` 调度 + 推送授权流
   - `medication_plans.schedule_json` 用来存周几/时间

3. **日周报接 LLM**
   - 当前 `SummaryGenerator.Generated` 接口与 LLM 输出兼容
   - 替换 `renderDaily` / `buildWeeklyReport` 内部即可；UI 无需改
   - 走 Apple Intelligence 或本地 GGUF / Ollama 桥；不要发到云

### 中价值
4. **对账阈值可编辑**
   - `DailyReconciler.Config` 改为从 UserDefaults 读
   - SettingsView 新增「对账」section 让用户调阈值

5. **来源归因落到 raw 行**
   - 当前 `SourceAttribution.classify` 是查询侧
   - 写入时同时存归一化 `source_origin` 列到 `health_samples_raw`（v2 migration）
   - 让 SourcesView 不再依赖动态分类

6. **单元测试**
   - HKQueryAnchor NSKeyedArchiver 编解码 round-trip
   - DailyReconciler 三个分数的边界（满分 / 零分 / 中段）
   - SyncStateMachine 全部 transition

### 低价值
7. **应用图标 / 启动屏视觉**
   - 当前 AppIcon/AccentColor 是 xcassets 占位

8. **Mac Catalyst / iPad 适配**
   - 当前 `TARGETED_DEVICE_FAMILY=1`（仅 iPhone）

9. **设置页打开 Apple Health 深链**
   - 通过 `URL(string: "x-apple-health://")` 跳到健康 App 让用户改授权

## 工程提醒
- 任何修改 `Migrations.swift` 已应用迁移都是 ❌；要加新表/列时新增 `v2_*` 迁移
- 引入新依赖前评估：当前只有 GRDB，包大小可控
- `xcodegen generate` 在改 `project.yml` / 新增源目录后必跑
- `swiftc -typecheck` 标准验证命令见 `WORKLOG.md` 末尾
