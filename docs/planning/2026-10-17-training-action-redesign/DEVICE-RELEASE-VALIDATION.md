# Release 安装与真实数据验收

更新：2026-10-17T15:46:38.932523+00:00。整体 **PENDING**：Release 已成功无线安装，真机准备度、能力及趋势已直接验证；其余 33 个参数入口的真机逐项交互尚未完成。本报告取代此前等待配对、尚未安装的状态记录。

## 当前结果

| 验收项 | 结果 | 证据与边界 |
| --- | --- | --- |
| 签名 Release 构建、安装、启动、安装身份回读 | PASS | iPhone Air／iOS 27.2；安装收据、启动进程及新 bundle URL 相互匹配 |
| 准备度真实数据显示与算术核对 | PASS | 真机直接显示；私有数据库只读回算与独立算术核对一致。实验指标的医学有效性不由本次验收证明 |
| 能力指标 | PASS | 真机 VO₂max 显示、单位及设备估计标记已看见，与最新原始记录舍入值一致 |
| 趋势 | PASS | 真机状态 7 天、4 周、8 周，以及能力、活动量类别均直接切换并截图；56 天回溯重算另有证据 |
| 统一目录与准备度详情 | PASS | 真机目录已显示；修复后点准备度行中央打开已加载的详情 |
| 全部 34 个参数详情 | PASS（真实数据副本） | 独立 iPhone Air／iOS 26.5 Simulator，复制真实数据库，正常中心点击、逐项等待读取完成；不能替代 iOS 27.2 真机全部入口验收 |
| 真机全部参数详情 | PENDING | 直接观察 1/34；其余 33 项尚缺直接交互证据 |
| 运动列表、打开补录后取消、4 类原始记录入口 | PASS（真实数据副本） | 单个连续 UI case 共完成 34 个参数，最后返回锻炼页；未保存补录 |
| 血氧换算、呼吸显示、血压／体温缺测状态 | PASS（真实数据副本） | 从成功 UI 附件再次核对；缺测显示“此期间暂无记录”，不填 0 |
| 原生实机 XCTest 执行框架 | FAIL | 3 次均在业务测试启动前断开 DTX 控制通道；不是业务断言失败 |

## 本次修复

真实数据页面验收复现：普通样式参数链接点中间空白区不跳转，点左侧文字可以进入详情。在 `UI/Training/TrainingParameterViews.swift:34` 的标签容器增加 `.contentShape(Rectangle())`。这是本轮唯一产品源码修改；原有 v2 dirty worktree 和 3 个私人未跟踪文件保持原状。

Planner 独立比较了修改前备份和修改后源文件，仅一行修饰器变化；Swift 语法检查、签名 Release 构建、真实数据副本全部入口 UI case 均通过。修复包已再次安装到 iPhone。原始 21 文件清单中其余 20 个哈希不变；最终全部 21 文件对应 `SOURCE-MANIFEST-RELEASE-FIX.json`。

## 安装身份

- Bundle：`com.norte.HealthManager`，`0.8.1 (17)`。旧 Debug 使用相同版本号，因此不能只靠版本号证明 Release。
- 最终可执行文件 SHA-256：`2e185afda1cf47c8ed1350de83f5b2716599abe86fadddf5d083c430dc5dd896`。
- 最终 UUID：`FD2FB366-5AB3-3711-8B48-6DC6D2B955CE`。
- 编译证据含 `Release-iphoneos`、`-O` 与整模块优化；Apple Development 签名，HealthKit 和后台交付权益验证通过。此安装不代表 App Store／TestFlight 发布。
- 最终签名包：[HealthManager.app](/Users/nortepro/.codex/visualizations/2026/10/17/healthmanager-v2-release-device-validation/parameter-hit-region-fix/signed-release/HealthManager.app)。
- 私有安装、启动和身份回读收据分别为 `parameter-hit-region-fix/release-install-receipt.json`、`release-launch-receipt.json`、`release-app-readback.json`。

## 实机操作边界

镜像在接续后短暂恢复坐标点击，完成了核心页面、趋势和准备度详情的直接操作。随后出现 iPhone-in-use 中断；通过已配对 Device Hub 锁屏并重连后，图像可读取，但坐标输入再次返回 `noWindowsAvailable`。XcodeBuildMCP 的 UI 快照只接受 simulatorId，未能提供真机替代入口。不能把这类工具错误解释为剩余参数入口正常，也不能把模拟器通过数计入真机通过数。

完整成功的真实数据副本 UI case 由原生 xcresult 确认：1 passed／0 failed／0 skipped。MCP 请求 300 秒超时，底层 Xcode 在 322.424 秒完成成功；已读取 xcresult 和终端成功标记，未因传输超时重复跑测试。此前两次诊断失败也保留：首次暴露点击区域缺陷；第二次验证文字可进入详情，并暴露测试对滚出屏幕搜索框的错误断言，该断言已改为检查导航栏。

## 证据与隐私

全部手机数据库、真实健康值、截图、测试源及原生结果保存在权限受限的私有目录，不写入仓库：

- [私有证据根目录](/Users/nortepro/.codex/visualizations/2026/10/17/healthmanager-v2-release-device-validation)。
- [最终 UI case 原生摘要](/Users/nortepro/.codex/visualizations/2026/10/17/healthmanager-v2-release-device-validation/parameter-hit-region-fix/copied-real-data-ui-summary.json)。
- [实机截图与观察说明](/Users/nortepro/.codex/visualizations/2026/10/17/healthmanager-v2-release-device-validation/parameter-hit-region-fix/physical-ui/OBSERVATIONS.json)。
- [真机准备度截图](/Users/nortepro/.codex/visualizations/2026/10/17/healthmanager-v2-release-device-validation/parameter-hit-region-fix/physical-ui/01-readiness.png)。
- [真机能力趋势截图](/Users/nortepro/.codex/visualizations/2026/10/17/healthmanager-v2-release-device-validation/parameter-hit-region-fix/physical-ui/06-capability-trend.png)。
- [只读回算与最新快照比较](/Users/nortepro/.codex/visualizations/2026/10/17/healthmanager-v2-release-device-validation/parameter-hit-region-fix/latest-replay-comparison.json)。
- [参数值与缺测状态检查](/Users/nortepro/.codex/visualizations/2026/10/17/healthmanager-v2-release-device-validation/parameter-hit-region-fix/ui-data-crosschecks.json)。

初始真实数据快照回算 117,166 条输入；安装修复前的新快照回算 117,176 条。期间自动同步新增记录；准备度及 56 天准备度历史、跑步比较一致，睡眠阶段按无序集合比较也一致。能力显示按最新手机原始记录另行核对，不把旧快照的数值当成当前值。

## 数据、环境与回滚

首次安装及修复包安装前均保留数据库备份；最新备份 `PRAGMA quick_check` 为 ok。没有卸载 App、重置或给真实数据库灌入测试数据，没有手工向 HealthKit 写入记录。正常自动同步会继续更新 App 自身数据库。

Mac 已回到原 SSID `Haeuschen_5G`，IPv4 配置未改。为维持无线开发发现，IPv6 从 Off 改为 LinkLocal 后保留；因此网络并非完全恢复到任务前配置。VoiceOver 已核实关闭；临时控制服务已卸载，未增加辅助功能授权。原 QA 模拟器恢复 Booted；新增真实数据副本模拟器已 Shutdown，证据留存。MCP 默认配置已恢复。

原始签名 Release 包和一行修复前源文件备份均保留，可只回退本次修饰器或重装原包；没有执行回退、数据库恢复、Git 提交或推送。保留现有工作区修改，不整树 reset／stash／clean。

## 剩余验收

只剩其余 33 个参数入口在真实 iOS 27.2 iPhone 上逐项打开、读完并返回的交互证据。后续应从已配对设备及最终修复包续接，无需重复配对，也不应重灌数据或把本报告标为全量 PASS。

EVO-Coder 本轮 1 次调用，仅实现一行点击区域修复；部署、签名、私有健康数据和最终验收由 Planner 执行。见 [调用报告](EVO-CODER-PARAMETER-HIT-REGION-REPORT.md) 与 [JSON](EVO-CODER-PARAMETER-HIT-REGION-REPORT.json)。
