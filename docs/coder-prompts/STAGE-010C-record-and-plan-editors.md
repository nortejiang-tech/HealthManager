# 给内部 Coder：只实现 STAGE-010C

你在共享工作区 `/Users/nortepro/HealthManager` 工作。主会话是架构师和最终验收者。工作区故意保留已验收 PASS 的 STAGE-010A～010B 未提交 diff；只能在其上增量实现，禁止删除、覆盖或回退。

## 唯一任务

严格实现：

```text
docs/stages/STAGE-010C-record-and-plan-editors.md
```

只改餐食新增 / 编辑、最近餐复用、餐食分项证据、用药计划新增 / 编辑与星期选择的视觉组合。不得进入一级页、详情页、设置页或业务层。

## 开工前必须完整阅读

```text
docs/adr/ADR-002-evidence-led-functional-ui-language.md
docs/design/2026-07-16-ui-redesign-design-contract.md
docs/stages/STAGE-010A-ui-foundation-and-root-states.md
docs/stages/STAGE-010B-primary-tab-surfaces.md
docs/stages/STAGE-010C-record-and-plan-editors.md
UI/DesignSystem/HMDesignSystem.swift
UI/Diet/DietView.swift
UI/Diet/MealReuseView.swift
UI/Diet/MealItemEvidenceView.swift
UI/Medication/MedicationView.swift
UITests/MealPersistenceUITests.swift
UITests/MealReuseUITests.swift
Tests/MealEditorDraftTests.swift
Tests/MealReuseTests.swift
Tests/MealItemEvidencePresentationTests.swift
Tests/NotificationScheduleTests.swift
```

并实际查看任务书列出的 5 张 PNG。参考图服从代码和事实合同，不得照抄不存在的数据或能力。

## 允许范围

- `MealEditView` 及紧邻纯视觉子视图；
- `MealReuseView`；
- `MealItemEvidenceView` 的 View 层；
- `MedicationPlanEditView`、`WeekdayPicker` 及紧邻纯视觉子视图；
- 被至少两个本阶段页面立即复用的轻量 design-system 补充；
- 与本阶段直接相关的 Preview / 测试。

先列出预计触碰的 struct / 文件和理由；如果发现需要修改业务层、identifier 语义或 010D+ 页面，停止并报告，不自行扩大范围。

## 硬边界

- 不修改 `Core/`、schema、迁移、query、Store、草稿模型、保存编排、照片存储、copy draft、通知调度器、LLM 客户端 / 解析器、HealthKit、Info.plist、entitlements。
- 不改变任何数据库写入、AI 请求、部分成功合并、照片增删 / 清理、复制、通知授权、计划保存或 dismiss 行为。
- 不改变 `MealItemEvidencePresentation` 的事实映射和字符串。
- 保留所有 `meal-edit-*`、`meal-reuse-*`、`meal-item-evidence-*` identifier；不得复制 identifier。
- 不把 `Form` / `List` 改成会破坏原生滚动、键盘、Picker、DatePicker、Toggle、Menu、PhotosPicker、sheet 或 UI 测试可达性的自定义容器。
- 不新增假数据源、运行时 debug router、第三方 UI 包、自绘 SVG / ASCII / 占位资产。
- 不提交、不 tag、不 push；不运行 reset / checkout / clean。

## 实现要求

1. 视觉层优先抽取小而有语义的子 View；不要大改已有状态与业务函数，不要复制整个编辑器。
2. 使用 010A～010B 的 token / component；新增共享组件必须有两个真实使用点。
3. 保留原生 `Form` / `List`，用 section header/footer、label、tint、background、overlay 和安全的容器层级组织视觉。
4. AI 明确为估算和可选外发；部分失败保留成功结果并只重试失败输入；技术详情降级但可读。
5. 复用页明确原记录不变、生成新草稿；整餐与选择分项都保持真实动作。
6. 证据紧凑态 / 展开态使用来源 tone + 图标 + 文字，人工修订不代表验证升级。
7. 用药计划预览只表达计划，不表达服药动作；星期按钮满足 44×44、VoiceOver label / selected trait。
8. 为范围内页面补充确定性 Preview；Preview 不触发真实数据库、AI、通知授权或写入。
9. 单个 patch 保持可审查；不要机械重写整文件。若预计净增超过约 500 行，先收缩方案而不是继续堆组件。

## 最低验证

先执行：

```bash
xcodegen generate
xcodebuild \
  -project HealthManager.xcodeproj \
  -scheme HealthManager \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -derivedDataPath /tmp/healthmanager-stage010c-coder-build-20260716 \
  build

xcodebuild \
  -project HealthManager.xcodeproj \
  -scheme HealthManager \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -only-testing:HealthManagerTests/MealEditorDraftTests \
  -only-testing:HealthManagerTests/MealReuseTests \
  -only-testing:HealthManagerTests/MealItemEvidencePresentationTests \
  -only-testing:HealthManagerTests/NotificationScheduleTests \
  -only-testing:HealthManagerUITests/MealPersistenceUITests \
  -only-testing:HealthManagerUITests/MealReuseUITests \
  -resultBundlePath /tmp/healthmanager-stage010c-coder-targeted-20260716-attempt01.xcresult \
  test
```

结果路径若存在，使用新的 attempt；禁止覆盖旧证据。用 `xcresulttool` 读取真实统计。主架构师会独立执行全量自动化和视觉验收，因此不要自行把阶段写成 PASS。

## 最终输出

只报告事实：

- 修改文件、结构和为什么在范围内；
- 业务函数 / identifier / 路由如何保持；
- `git diff --check`；
- build 与定向测试 exit code、executed / passed / failed / skipped、xcresult 路径；
- 未由你验证的 dark / Dynamic Type / Simulator 视觉项；
- 明确没有 commit / tag / push。

完成后停止，等待主架构师验收；不要进入 STAGE-010D。
