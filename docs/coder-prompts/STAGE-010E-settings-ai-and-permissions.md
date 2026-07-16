# 给内部 Coder：只实现 STAGE-010E

你在共享工作区 `/Users/nortepro/HealthManager` 工作。主会话是架构师和最终验收者。工作区故意保留 STAGE-010A～010D 已验收但未提交的 diff；必须在其上增量实现，禁止删除、覆盖或回退。

## 唯一目标

只实现 `docs/stages/STAGE-010E-settings-ai-and-permissions.md`：改造设置、AI 双通道、兼容接口 / Profile 和 Apple 健康权限下钻，准确表达本地保存、可选外发、Keychain 和权限证据边界；不改变配置、网络、HealthKit、数据库、通知或对账合同。

## 必须先读并实际查看

完整阅读 ADR-002、设计合同、010D accepted 结果、本阶段任务书、`SettingsView.swift`、`LLMSettingsView.swift` 与共享设计系统；实际查看 18、19、23、25 四张参考 PNG。

## 范围硬门

只修改任务书白名单。禁止修改 `Core/`、LLMConfig / Client、Keychain、HealthKit manager / catalog、schema、同步 / 对账 / 通知实现或 010F+ 页面。开始前先列预计触碰的文件 / struct 与纯视图理由；若需要业务改动立即停止并报告。

## 实现要求

1. 复用 accepted token / component；不堆卡，不逐行造表面。
2. 所有既有按钮、sheet、保存、取消、Profile / preset、测试连接、导出、阈值、通知与 onboarding 重置调用关系保持。
3. 文本和图像通道分别说明输入范围、provider / 模型 / Key 与测试状态；不得把一个通道的结果冒充另一个。
4. 没有样本不等于没有读取权限；逐类型读取必须写“最近检测到数据 / 暂无可判定证据”等真实证据状态。写回授权单独使用现有可观察状态。
5. 添加接口不存 Key、不自动启用或发送；Profile 不存 Key；失败不覆盖已保存配置。
6. 不为截图写入 provider、Key、样本、权限或 production fixture。使用 SF Symbols 和系统控件，Dynamic Type 下关键动作可滚动到达。

## 最低验证

- `xcodegen generate`；独立 DerivedData build；
- 任务书列出的定向 tests + `HealthManagerUITests/SmokeTests`；
- `git diff --check`；用 `xcresulttool` 报真实计数和路径。

只报告修改范围、合同保持、自动化证据和未验证边界；不要自行宣布 PASS，不 commit / tag / push，完成后停止，不进入 010F。
