# HealthManager 锻炼 v2：最新实施与实机验收交接

> **2026-10-18 最新交接：用户已终止本轮镜像／实机通道排查，改由 ZCode 完成验收。** 请先读 [ZCODE-REAL-DEVICE-ACCEPTANCE.md](ZCODE-REAL-DEVICE-ACCEPTANCE.md) 及 [33 项 JSON 清单](ZCODE-REAL-DEVICE-CHECKLIST.json)。本阶段新增真机参数覆盖 0，仍为 1/34；已有安装和核心结果沿用。下文环境状态是前一阶段记录，最后一次直接退出 Device Hub 后模拟器状态未重新核实；最新环境边界以新交接为准。原生事件替代原型仅 dry-run，未获执行授权，也未执行事件。

## 当前状态

**整体 PENDING**。无线配对已成功，真正的签名 Release 已安装到 iPhone Air／iOS 27.2，安装、启动和身份回读均 PASS。真机准备度、最新设备 VO₂max、7／28／56 天状态趋势及能力／活动量趋势已直接操作并保存截图。全部 34 个参数入口在复制真实数据库的独立 iOS 26.5 模拟器上 PASS；真机只直接观察准备度详情 1/34，其余 33 个入口仍缺逐项交互证据。

当前权威状态是 [DEVICE-RELEASE-VALIDATION.md](DEVICE-RELEASE-VALIDATION.md) 及同名 JSON。此前“等待配对”“尚未安装”的记录已被新收据取代，不能继续让用户重复配对、找线或重新确认同一权限。

## 最终安装身份与源码

- Bundle `com.norte.HealthManager`，版本0.8.1(17)。旧 Debug 版本标签相同，需以实际签名 Release 构建与安装收据链识别。
- 最终可执行文件SHA-256：`2e185afda1cf47c8ed1350de83f5b2716599abe86fadddf5d083c430dc5dd896`，UUID `FD2FB366-5AB3-3711-8B48-6DC6D2B955CE`。
- 本轮真实数据 UI 验收发现参数行空白中心点击失效，点文字正常。只在 `UI/Training/TrainingParameterViews.swift` 的链接标签添加 `.contentShape(Rectangle())`，修复包已重新安装。全部 34 个正常中心点击在真实数据副本上通过；实机准备度中心点击也进入了已加载详情。
- 最终21文件源码哈希为 `SOURCE-MANIFEST-RELEASE-FIX.json`。相对原 `SOURCE-MANIFEST.json` 只有上述1个文件预期变化，其余20个一致。
- Git main基线0cfc55b；既有v2改动和3个私人未跟踪文件均保留，未暂存、提交或推送。

## 实现与产品约束

准备度睡后锚点、56天回溯和142天输入边界由 `Core/Training/TrainingCalculator.swift`／`TrainingSnapshotLoader.swift` 实现。34指标及来源、单位、序列由 `TrainingMetric.swift`／`TrainingParameterLoader.swift` 实现。页面为总览／趋势／全部参数，共享参数详情和原始记录入口；运动列表及补录位于锻炼中，其他运动参数也接到统一详情。

不加训练计划、课表或打卡；不派生“疲劳=100-准备度”，不把负荷等同疲劳；范围不取中点，缺测不填0，设备估计与实验模型分开。个人常见范围须此前28日内至少14个同来源有效单点，P25–P75排除当前点。历史是根据当前已入库数据回算，不是当时保存的分数。此前软件验收480单元＋2UI、独立深色UI和Release编译属于历史软件证据，不能当作本轮全量实机PASS。

## 当前阻碍与剩余工作

原生实机XCTest三次均在业务测试启动前因DTX控制通道拒绝失败，根因未解决。镜像接续后一度恢复点击，完成核心真机页面与准备度详情；随后iPhone-in-use中断，使用已配对Device Hub锁屏和重连后可查看画面，坐标输入又返回noWindowsAvailable。XcodeBuildMCP snapshot_ui要求simulatorId，不能代替真机UI控制。

只在获得稳定输入路由后续查其余33个真实iPhone参数详情，逐项等待读取完成并返回。不要把副本34/34计成真机34/34；也不要因工具报错改动已通过的计算器或重灌手机数据。已完成的配对、签名、安装与数据核对无需重复。

## 私有证据与复现

私有证据根目录：`/Users/nortepro/.codex/visualizations/2026/10/17/healthmanager-v2-release-device-validation`，最终修复与新安装位于其 `parameter-hit-region-fix/`。真实数据库、健康数值和截图只放这里，不进仓库或本地Coder输入。

- 两份安装前备份及只读quick_check均通过；无真实数据灌入、重置、App卸载或手工HealthKit写入。正常同步会增加本机数据。
- `parameter-hit-region-fix/physical-ui/OBSERVATIONS.json` 区分已观察页面与镜像中断，`09-mirror-interruption.png` 不是参数详情截图。
- 原生成功xcresult：`/Users/nortepro/Library/Developer/XcodeBuildMCP/workspaces/HealthManager-8bdea649e903/result-bundles/test_sim_2026-10-17T15-28-49-516Z_pid99068_113c6081.xcresult`，1 passed／0 failed／0 skipped，34个参数详情及运动／补录取消／4类原始记录入口。MCP传输300秒超时，但Xcode在322.424秒成功，已读回原生结果，无需重跑。
- 真实数据副本模拟器365C26F6-4B88-4CD7-9833-08A88DC3FB76，iPhone Air／iOS26.5，现Shutdown。临时工程 `/tmp/healthmanager-v2-realdata-sim-20261017/HealthManager.xcodeproj`，Release，DerivedData `/tmp/HealthManager-v2-copied-real-data-build`；最终只读验收源、工程配置已另存私有 `copied-real-data-probe/`。
- 仅隔离模拟器通过启动参数保留已请求授权的本地状态，不伪造HealthKit授权或生成样本；禁止把这些参数用于真机验收。
- 原QA模拟器29729D20-7BF0-4206-9FCD-84576508885D已恢复Booted，数据未替换；默认MCP profile已恢复。

## 环境与回滚

Mac原SSID Haeuschen_5G已恢复，IPv4手动配置不变。IPv6从Off改为LinkLocal后保留以支持无线开发，未完全回退原网络设置。VoiceOver已核实关闭，临时控制服务已卸载，无新辅助功能权限授权。Device Hub最后用“Quit and Keep Simulators Running”退出，Accessibility Inspector已退出。

修复前源文件、原签名Release包、两次安装前数据库备份均保留；没有执行代码／App回退或数据库恢复。仅回退本次一行修饰器即可撤销小修，禁止整树reset/stash/clean。无需安装或修改其他开发工具、权限或模型配置。

## EVO-Coder

本次续接1次窄范围实现调用，4.98秒、3回合、3工具，精确一行修复直接接受，Planner独立验证通过；部署、签名与私有健康数据未交给Coder。详见 `EVO-CODER-PARAMETER-HIT-REGION-REPORT.md/.json`。此前实施阶段2次监督器调用保留在原实施报告，属于不同阶段。
