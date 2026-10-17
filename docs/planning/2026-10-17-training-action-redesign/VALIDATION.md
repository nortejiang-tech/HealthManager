# 锻炼页 v2 · 实施与验证报告

日期：2026-10-17（Asia/Shanghai）

**本次开发与本地软件验收：PASS。真实 iPhone 安装、实际健康数据体验与完整 VoiceOver 朗读验收：PENDING。**

## 已交付行为

- 锻炼页分为「总览／趋势／全部参数」，没有训练计划、课表、目标完成率或每日打卡。
- 准备度沿用实验权重，升级为 v2 每日主睡眠结束锚点；显示单点或可能范围、时点、上次可比差值、此前28天个人常见范围和近7天小图。范围不取中点、缺测不填0。
- 历史窗口56天，读取142天输入以覆盖个人参照、夜间基线、训练负荷与其静息基线和跨夜缓冲。各历史锚点只使用此前已发生的记录；延迟入库后回溯重算明确标注，不宣称当时已知。
- VO₂max 使用实际原始测量日期、单位及来源／设备字段；显示同来源4周、8周区间变化。相似跑步保留配速和心率的独立单位、前后样本数、日期、来源及未控制条件。
- 34个参数由统一标识、单位、定义、读取和详情入口管理。涵盖活动量、心率与恢复、能力、睡眠阶段与时段、体成分和其他生理参数；原始记录可查测量／入库时间及设备。未知参数不虚构数值。
- 「更多→运动记录」迁入锻炼，保留全部记录、手工补录及单次详情。独立读取较早运动记录，避免被8周总览窗口截断。
- 全局趋势摘要进入同一参数详情。既有体重等指标保留年视图、滚动和捏合缩放；不会把新的准备度历史伪称为支持一年。扩展历史关闭“数值升降代表健康好坏”的方向色提示。

## 最终证据

| 验收项 | 结果 | 证据 |
| --- | --- | --- |
| 全量单元测试 | PASS：480项，0失败 | 最终482项运行中的480个单元用例 |
| 年视图与捏合缩放原测试 | PASS | 未修改原缩放测试；新统一详情仍可进入年视图并缩放／重置 |
| 锻炼页浅色、超大字号 | PASS | 同一UI用例内部验证两种显示模式，覆盖分区、趋势窗口、参数搜索、详情、原始记录、手工补录、入口迁移 |
| 深色模式 | PASS：单独复跑1项UI用例，0失败 | 模拟器真实切换深色，运行截图已导出 |
| 全局UI回归 | 首轮10/11通过；1项回归已修复并复测通过 | 包含饮食保存／复用、全局导航、同步诊断和健康桥接设置。年视图入口回归在最终运行中通过 |
| iPhone Release 编译 | PASS | Release-iphoneos，CODE_SIGNING_ALLOWED=NO；没有签名或安装声明 |
| 差异及范围 | PASS | git diff --check；SOURCE-MANIFEST.json 对21个相关源／测试／项目规格文件记录SHA256 |

最终合并运行：**482项通过、0失败、0跳过**（480单元 + 2个UI用例），125.0秒。
深色复跑：**1项通过、0失败、0跳过**，46.6秒。相同UI用例在不同显示模式复跑，不把它计成新的独立用例。

专项覆盖包括：睡后运动不回写准备度、最早历史点的基线完整性、独立历史复算一致、个人参照排除当前点、晚到数据的“当时不可用／现在可重算”、来源切换、未知来源停止跑步比较、范围不产生精确差值、较早单次运动晚到入库、分位数溢出、零分母、实际VO₂max日期和单位，以及汇总数据不借用睡眠来源。

### 结果文件

- [最终测试结果包](/Users/nortepro/Library/Developer/XcodeBuildMCP/workspaces/HealthManager-8bdea649e903/result-bundles/test_sim_2026-10-17T13-08-00-603Z_pid99068_7803580e.xcresult)
- [最终测试日志](/Users/nortepro/Library/Developer/XcodeBuildMCP/workspaces/HealthManager-8bdea649e903/logs/test_sim_2026-10-17T13-08-00-603Z_pid99068_d54be16f.log)
- [深色模式结果包](/Users/nortepro/Library/Developer/XcodeBuildMCP/workspaces/HealthManager-8bdea649e903/result-bundles/test_sim_2026-10-17T13-11-28-233Z_pid99068_84a5e5a3.xcresult)
- [Release编译摘要](/Users/nortepro/HealthManager/docs/planning/2026-10-17-training-action-redesign/RELEASE-BUILD-SUMMARY.txt)
- [机器可读验收记录](/Users/nortepro/HealthManager/docs/planning/2026-10-17-training-action-redesign/VALIDATION.json)

### 实际运行截图

全部来自专用模拟器的**合成QA数据**，不是用户健康结论。

- [总览（浅色）](/Users/nortepro/.codex/visualizations/2026/10/17/01a149ba-5d06-78b2-a602-52bed459a33f/screenshots/v2-light-overview.png)
- [准备度趋势](/Users/nortepro/.codex/visualizations/2026/10/17/01a149ba-5d06-78b2-a602-52bed459a33f/screenshots/v2-light-readiness-history.png)
- [VO₂max参数详情](/Users/nortepro/.codex/visualizations/2026/10/17/01a149ba-5d06-78b2-a602-52bed459a33f/screenshots/v2-light-parameter-detail.png)
- [原始记录](/Users/nortepro/.codex/visualizations/2026/10/17/01a149ba-5d06-78b2-a602-52bed459a33f/screenshots/v2-light-raw-records.png)
- [超大字号](/Users/nortepro/.codex/visualizations/2026/10/17/01a149ba-5d06-78b2-a602-52bed459a33f/screenshots/v2-large-overview.png)
- [深色总览](/Users/nortepro/.codex/visualizations/2026/10/17/01a149ba-5d06-78b2-a602-52bed459a33f/screenshots/v2-dark-overview.png)
- [保留年视图缩放](/Users/nortepro/.codex/visualizations/2026/10/17/01a149ba-5d06-78b2-a602-52bed459a33f/screenshots/year-pinched-zoom.png)

## 过程中发现并处理的问题

1. 最早历史点测试最初期望28个参照点，但夹具仅提供足够19个单点的训练历史；扩充合成训练历史后验证通过。
2. 全局UI回归发现统一详情后旧「年」入口不可达；恢复到共享详情入口，复用既有年视图，原缩放测试未经弱化而重新通过。
3. 本地 Coder 数学辅助函数对异号极端浮点值的插值可能溢出；Planner 修正并加入独立极值检查。
4. 原工程远程依赖准备阶段卡在 GRDB 的 SQLiteCustom 子模块下载。使用临时QA工程将依赖定位到已缓存GRDB 6.29.3，业务源文件仍直接引用本仓库。缓存HEAD为 `2cf6c756e1e5ef6901ebae16576a7e4e4b834622`，工作树与HEAD无差异；没有修改仓库依赖声明。一次完整UI回归超过MCP的300秒等待上限，但底层测试继续到结束；从实际日志确认其10通过／1失败，随后针对回归复测。

## 环境与边界

- 仓库基线：`main @ 0cfc55b5b2f9d504ad6e7e4039349badf8a68f1a`。
- QA工程：`/tmp/healthmanager-training-v2-qa-project/HealthManager.xcodeproj`；App/Core/UI/Tests等为指向本仓库的链接，只把包依赖改为本机同版本缓存。
- 模拟器：`HealthManager-Training-QA-20261015` / `29729D20-7BF0-4206-9FCD-84576508885D`，iOS 26.5。
- Debug产物：`/tmp/HealthManager-training-v2-build/Build/Products/Debug-iphonesimulator/HealthManager.app`。
- Release产物：`/tmp/HealthManager-training-v2-release/Build/Products/Release-iphoneos/HealthManager.app`，未签名。
- 旧代码已有营养／个人食材模块的Swift并发及未使用变量警告，本次训练改动无新增编译警告。
- 未做数据库迁移。QA种数脚本只能写指定专用模拟器，不写Apple健康、真实iPhone或Mac健康副本。
- 未提交、未推送、未部署真实设备；原有3个私人未跟踪文件未触碰。

实验评分的生理有效性、真实穿戴数据的个人长期校准、后台／锁屏同步和实际耗电不由本轮软件测试证明。来源字段不能识别全部设备／固件算法变化；日汇总可能含多来源。完整VoiceOver朗读与真实手机体验仍待验收。

## 回滚与下一步

本轮未执行回滚，改动保留在工作区。可按 SOURCE-MANIFEST.json 和明确的新增文件清单，仅逆向本次源文件差异；无数据库结构需要回退。不得使用整树reset、stash或批量清理，以免影响原有私人文件。

下一步是对该已验证源码进行真机签名安装与真实数据验收；这不等于已经安装完成。后续若继续，应先核对本报告与源码指纹，不重复把历史软件测试当作新设备证据。
