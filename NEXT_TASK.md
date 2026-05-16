# NEXT_TASK

> 当前状态：V6 / beta-1 之后，Codex 已完成「活动能量口径 + 活动详情 + 手动活动补录」以及「活动卡片能量化 + 步数 HKStatistics 对齐」修正。`SourcesView` 已读 `health_samples_raw.source_origin`，AI 饮食识别 / LLM 摘要 / 用药通知 / 对账阈值 UI 都已落地，不再列为待办。

## 近期优先级

1. **导航入口整理**
   - 当前主 tab 仍是 仪表盘 / 饮食 / 用药 / 来源 / 同步中心。
   - `SummaryView` 入口在「仪表盘 → 数据质量 / 同步明细 / 报告」里，设置入口在同步中心右上角，后续建议重新设计成更自然的一级或二级入口。

2. **饮食 items 持久化**
   - 当前 `meal_records` 只存合计 calories/protein/fat/carbs。
   - AI 估算出来的多菜品 items 仍是编辑期结构；若要编辑已有餐次时保留分项，需要新增迁移（例如 `items_json`）。

3. **睡眠效率**
   - `sleep_efficiency` 目前仍可能为空。
   - 要么基于 inBed/asleep 阶段计算效率，要么在 UI 中弱化/隐藏该字段，避免被误读为异常。

4. **应用图标 / 视觉收尾**
   - 当前 AppIcon 已有占位图。
   - 用户提到过绿蓝渐变圆 + 体脂秤 + 光圈原图，后续可替换正式图标。

## 工程提醒

- 任何修改 `Migrations.swift` 已应用迁移都是禁止项；要加表/列时新增 `v?_...` migration。
- 新增源文件或改 `project.yml` 后必须跑 `xcodegen generate`。
- 当前依赖只有 GRDB；引入新依赖前先评估包大小和维护成本。
- API key 绝不进 repo；LLM 配置走 Keychain，模拟器 Keychain 失败时会 fallback 到 UserDefaults。
- 用户偏好中文沟通、简洁交付、每轮跑 build/test 验证。
