# 给内部 Coder：STAGE-010F 卡片编辑与剩余状态

你只执行 `/Users/nortepro/HealthManager/docs/stages/STAGE-010F-card-editor-and-residual-states.md`，不得进入 010G / 010H。主会话是架构师与最终验收者。

开始前必须读取：

1. `docs/stages/STAGE-010F-card-editor-and-residual-states.md`
2. `docs/design/2026-07-16-ui-redesign-design-contract.md`
3. `docs/adr/ADR-002-evidence-led-functional-ui-language.md`
4. `docs/design/assets/ui-redesign-2026-07-16/17-dashboard-card-editor.png`
5. `UI/Dashboard/DashboardCardEditor.swift`
6. `UI/Dashboard/DashboardLayout.swift`，只读，用于保持 store 合同

只修改任务书白名单。`DashboardLayout.swift` / `DashboardLayoutStore` 只读；禁止修改 Core、数据库、HealthKit、同步、通知、LLM、loader、模型或计算合同。若剩余状态修复需要新业务状态或 manager 行为，停止该项并报告，不得自行扩张。

实现要求：

- 保留 `store.hide` / `show` / `move` / `resetToDefaults` 和 dismiss 的现有调用关系；不新增确认或保存步骤。
- 用真实 store 数量与顺序；隐藏只影响首页展示且不删除数据，恢复默认不是破坏性操作。
- 复用既有 token、系统 List / move 控件与 SF Symbols；所有图标按钮至少 44 pt 并有准确 accessibility label。
- visible / hidden 空状态、light / dark / accessibility-large 可滚动可达；不硬编码参考图数据，不新增装饰或假状态。
- 先记录跨页源码审计的具体剩余缺口，只修纯视图能闭环的项。

完成后运行独立 build、定向测试、正式 Smoke、全量测试、`git diff --check`，并用 iPhone 17 / iOS 26.5 Simulator 取得 default / hidden-change 的 light、dark、accessibility-large 运行态；把 reference 与同状态 runtime 放进同一张组合图再判断。临时视觉 test 结束前删除并重新生成工程。

只报告修改范围、合同保持、自动化证据和未验证边界；不要自行宣布 PASS，不 commit / tag / push，完成后停止，不进入 010G。
