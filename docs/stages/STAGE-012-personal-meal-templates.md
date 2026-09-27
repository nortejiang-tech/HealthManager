# STAGE-012 个人固定菜品与常吃选择

## 目标

在「我的常吃」中创建、编辑和调用独立固定菜品；用现有饮食记录频次提供可编辑推荐；在餐次编辑器中多选常吃食物、个人配方和固定菜品。

## 基线与范围

- 起点：`main` 的 `9deac34e605163275d24fb3ffde52c8ad1a36bab`；保留既有 HealthBridge 报告及所有未跟踪文件。
- 现有饮食 AI、MealItemDraft、PersonalFoodStore、MealReuse 和备份 formatVersion 3 为复用基线。
- 允许修改 App、Core、UI、数据库迁移、备份清单与字段字典、现有备份格式兼容断言，以及本 ADR/STAGE/EVO 报告。
- 禁止修改既有迁移、HealthKit 同步语义、餐次历史数据、照片持久化合同、AI 请求/响应合同；禁止提交、tag、push 或清理已有文件。

## 设计约束

1. 固定菜品与历史餐次、个人配方是不同实体。保存顺序、克数、营养快照和 provenance；null 仍表示未知。
2. 保存和读取模板都由独立 Store 承担。模板写入不得调用餐次保存协调器、HealthKit 或健康同步。
3. 同一餐次编辑器表单复用拍照/文字 AI 与分项编辑；固定菜品保存只写个人模板，并在保存后清理本次临时照片。
4. 频次推荐来自 `FrequentFoodsQuery` 已有的逐餐去重结果。至少 2 餐且模板名称尚未存在时显示建议；点击后打开带最近分项快照的模板编辑器，不静默创建。
5. 餐次选择器允许同时勾选常吃食物、个人配方和固定菜品，确认后仅追加到当前草稿；实际记录仍走现有保存链。
6. 只新增 v15 表，不改旧迁移；备份新增 JSONL 表并将格式升为 v4，兼容 v1-v3 导入。
7. 不保存模板照片、时间、备注、父级汇总或 HealthKit ID。

## 预计完成标准

- 固定菜品可以从常吃页创建、编辑、删除和加入饮食编辑器。
- 固定菜品编辑器可用现有照片/文字 AI、手工分项编辑和个人食物选择入口。
- 高频候选与已匹配食物按频次显示固定菜品建议；已有同名模板不重复推荐。
- 餐次编辑器可多选常吃食物、配方和模板；取消不修改当前餐次，确认选择只改草稿。
- 模板完整保留 provenance、置信度、未知营养和用户修订标记，不携带照片或旧餐次身份。
- v15 迁移为纯新增表；formatVersion 4 导出/导入模板，旧备份不含模板时仍可恢复。
- `git diff --check` 与 iOS 编译通过。按本轮上游开发指令，不新增或运行测试。
- 未执行真实设备、备份恢复或 UI 交互时，相关验收保持 `PENDING`。

## 风险与回滚

- 新增表与备份文件是向前兼容扩展；新 App 可以导入旧格式，旧 App 按现有合同拒绝 v4。
- 回滚代码可移除新 UI/Store/备份支持；迁移为 additive，不删除或改写用户数据。
- 实际安装后的迁移和备份往返需在后续真机验收中确认。

## 验证命令

- `git diff --check`
- iOS Debug 编译（不运行测试）

## 结果

- **代码实现：完成。** 新增独立固定菜品快照 Store 和 v15 表；复用餐次 AI/分项编辑，支持模板管理、高频候选建议，以及饮食编辑器多选常吃食物、待确认候选、个人配方和固定菜品。所选模板分项按原样追加，保留有意重复的同名分项。
- **静态检查：PASS。** `git diff --check` 无输出；EVO-Coder JSON 报告可解析。
- **iOS Debug Simulator 编译：PASS。** 命令：`xcodebuild -project HealthManager.xcodeproj -scheme HealthManager -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`；退出码 0，`BUILD SUCCEEDED`。构建日志有一条 App Intents 元数据跳过提示，因为 target 未依赖 `AppIntents.framework`，不影响编译。
- **双轴代码审查：** Spec 无发现；Standards 的选择去重数据丢失问题已修复，最近分项查询的重复读取已收拢。仅余低严重度命名 smell：现有测试文件 `BackupV3Tests.swift` 仍覆盖 v4 断言。
- **测试：NOT RUN。** 本轮未新增或运行测试；已有备份兼容性断言随格式升级调整。
- **真机签名构建与安装：PASS。** 2026-09-23 对 NortePro 的 iPhone 完成签名 Debug 构建与 `devicectl` 覆盖安装；安装后读回 bundle `com.norte.HealthManager`、版本 `0.8.1 (16)`。未卸载、未启动 App。
- **UI / 真机交互：PENDING。** App 未启动，尚未操作新增界面；v15 迁移尚未在真机上执行。
- **迁移实装和备份往返：PENDING。** 尚未执行真实库 v15 迁移、v4 导出/恢复或 v1-v3 备份恢复验收。
- **EVO-Coder：未调用。** 数据库迁移与备份契约变更由 Planner 直接实现；调用与指标记录见 `docs/planning/2026-09-23-fixed-meal-templates/EVO-CODER-REPORT.md` 和同名 JSON。

整体阶段状态：`PENDING`，真机签名安装已通过，仍等待首次启动后的 UI/v15 迁移和备份恢复验收；代码构建与静态检查已经通过。
