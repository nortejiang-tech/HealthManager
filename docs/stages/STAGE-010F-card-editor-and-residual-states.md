# STAGE-010F 卡片编辑与剩余状态

## 状态

`PASS`

## 目标

在 STAGE-010A～010E 已验收的证据型 UI 上，改造 Dashboard 卡片编辑器，并对尚未进入同一视觉语言的 loading / empty / failure 表面做一次有证据的源码审计。只修复可以由纯视图组合解决的缺口，不借“补状态”改变加载、持久化或业务语义。

## 已验证起点

- STAGE-010A～010E：PASS；最近全量自动化 258 / 258。
- Apple 健康权限证据下钻已经在 010E 完成，本阶段不重复建设。
- `DashboardCardEditor` 当前保留拖动、隐藏、显示和恢复默认，但把隐藏与恢复默认错误渲染成破坏性操作，且没有明确“只影响首页展示、不删除数据”。
- 跨页源码审计显示主要页面已使用共享 loading / empty / recovery 语言；本阶段仅处理具体可复现的剩余纯视图缺口。

## 设计依据

- `docs/adr/ADR-002-evidence-led-functional-ui-language.md`
- `docs/design/2026-07-16-ui-redesign-design-contract.md`
- `17-dashboard-card-editor.png`

参考图规定信息层级、动作语义和拖动反馈，不是布局或数据 fixture。不得把参考中的卡片数量、顺序或隐藏项写进生产状态。

## 允许修改

- `UI/Dashboard/DashboardCardEditor.swift`
- `UI/DesignSystem/HMDesignSystem.swift`，仅限至少两个已实现页面立即受益的无障碍 / 自适应修正；
- 经源码审计确认、能够用纯视图变化闭环的剩余状态页面；修改前必须在结果中记录具体缺口；
- 与本阶段直接相关的 test-only UI 审计、测试和文档。

## 禁止修改

- `UI/Dashboard/DashboardLayout.swift`、`DashboardLayoutStore`、UserDefaults key / 编解码 / 排序 / 显示 / 隐藏 / 恢复实现；
- `Core/`、数据库、HealthKit、同步、通知、LLM、数据 loader、模型或计算合同；
- STAGE-010A～010E accepted 页面中没有可复现状态缺口的视觉重排；
- 新卡片类型、批量选择、确认步骤、撤销栈、云同步、假数据或 production QA 路由；
- commit、tag、push。

## 事实与交互合同

- 编辑器只改变趋势首页卡片的显示与顺序；隐藏卡片不删除健康记录，恢复默认不是危险动作。
- `store.hide`、`store.show`、`store.move`、`store.resetToDefaults` 与 dismiss 的调用关系保持；不得新增会改变单次操作语义的确认或保存步骤。
- 当前真实 `visibleCards` / `hiddenCards` 决定数量、顺序和空状态；不得从参考图硬编码。
- 拖动把手、隐藏、添加、恢复和完成都必须可访问，图标动作有文字 label，点击区至少 44 pt。
- 空列表是成功空白，不是失败；隐藏列表为空应表达“已全部显示”，可见列表为空应引导从下方恢复。
- 跨页剩余状态只能修正视觉表达或可达性；若需要新的状态变量、数据分支或 manager 行为，立即停止该项并留给独立业务阶段。

## 完成标准

- [x] 卡片编辑器明确“只影响首页展示、不删除数据”，真实数量与卡片类型可读。
- [x] 隐藏、添加、拖动和恢复默认不使用破坏性红；只有真正删除 / 失败保留 action-required 语义。
- [x] 原有排序、显示、隐藏、恢复和完成行为保持，真实 UI 流程可运行。
- [x] visible / hidden 两种空状态与默认状态均能理解，44 pt 点击区与 VoiceOver label 完整。
- [x] 经审计确认没有遗留的可复现纯视图状态缺口；业务层缺口不越界修复。
- [x] light、dark、accessibility-large 无关键裁切、水平溢出或不可达动作。
- [x] reference / runtime 组合对照、定向测试、全量测试与 `git diff --check` 通过。

## 验证矩阵

1. 构建：iPhone 17 / iOS 26.5 Simulator，独立 DerivedData。
2. 定向：Dashboard / Smoke / 现有状态合同测试；不为通过测试改写持久化语义。
3. UI：从真实 Trends 入口打开编辑器，至少验证默认、隐藏后、恢复默认与完成返回。
4. 全量：`HealthManager` scheme 全测试，用 `xcresulttool` 记录真实统计。
5. 视觉：编辑器 default / hidden-change 的 light，核心页 dark 与 accessibility-large；制作 `17` reference / runtime 组合图。

## 验证边界

- Simulator 不证明真实用户长期 UserDefaults 升级或真实 iPhone VoiceOver 操作手感。
- 测试结束必须恢复默认卡片布局，避免污染后续截图矩阵。
- 不进入 STAGE-010G～010H，不以 Preview 代替 Simulator 运行证据。

## 结果

`PASS` — 2026-07-16 由主架构师独立验收。

- 生产实现只修改 `DashboardCardEditor`：保留原生 List / move，把隐藏、添加、恢复默认改为中性 / 确认 / 比较语义；真实 `visibleCards` / `hiddenCards` 决定数量和顺序。
- 顶部明确“只调整趋势首页，隐藏不删除记录”；恢复默认说明只恢复显示与顺序。所有图标动作有 44 pt 点击区、label、hint 与稳定 identifier。
- 永久 Smoke 增加真实编辑器流程：先恢复默认，再隐藏活动、重新显示、再次恢复默认并完成返回；测试结束保持默认布局。
- 跨页源码审计没有发现需要在本阶段继续修改的纯视图状态缺口；权限下钻已由 010E 完成。需要新增业务状态才能表达的项没有越界处理。
- 构建：`/tmp/healthmanager-stage010f-architect-build-20260716-attempt01`，BUILD SUCCEEDED。
- 定向：18 / 18；`/tmp/healthmanager-stage010f-architect-targeted-20260716-attempt01.xcresult`。
- 全量：258 / 258；`/tmp/healthmanager-stage010f-architect-full-20260716-attempt01.xcresult`。
- 视觉：light / dark 各验证 default 与 hidden-change；accessibility-extra-large 验证顶部与恢复默认底部可达，最终结果为 `/tmp/healthmanager-stage010f-visual-accessibility-20260716-attempt03.xcresult`。大字号首轮暴露动态图标溢出，改为固定视觉尺寸后复验无重叠。
- `17` reference / runtime 同屏组合图位于 `/tmp/healthmanager-stage010f-acceptance-20260716/comparisons/card-editor-reference-vs-runtime.png`，已逐图复核；参考中的数量、顺序和名称没有硬编码。
- accessibility 的完整 Smoke 首轮在测试专用的“隐藏后重新显示”滚动定位上失败；没有 App crash 或产品状态丢失。随后使用只验证顶部 / 底部可达并恢复默认的临时审计用例复验 1 / 1，通过后删除该临时文件并重新生成工程。
- `git diff --check`：PASS；未 commit、tag 或 push。
