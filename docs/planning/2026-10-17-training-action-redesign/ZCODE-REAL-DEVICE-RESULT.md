# ZCode 真机验收结果：33 个剩余参数入口

日期：2026-10-18。执行窗口 00:27–01:32（+08:00）。**整体判定：PASS（33/33）**。

真机参数覆盖：**既有准备度 1 + 本次其余 33 = 34/34**。模拟器（复制真实数据）34/34 为独立结果，见 DEVICE-RELEASE-VALIDATION，不与本结果混用。

## 结论一览

- 33 项全部完成行中心点击 → 正确详情 → 读取完成 → 数值/单位/口径/来源/时间 → 趋势 → 返回的完整闭环。
- 33 项全部渲染真实数据（无 valid_empty 项，数值已脱敏不入仓库），无「参数暂未更新：」错误，无误路由，无返回失败。
- 已安装 Release（0.8.1 (17)，SHA-256 链沿用 DEVICE-RELEASE-VALIDATION）**未被重装/卸载/重签名**；执行前后 `devicectl info apps` 回读一致。

## 使用通道（工具层，与产品结果分开记录）

| 通道 | 结果 |
|---|---|
| XCTest IDE（UseDestinationArtifacts 复用已装目标） | **通道失败**：Runner 启动后 DTX 通道请求被设备端拒绝（`dtxproxy:XCTestDriverInterface` refused → code 74），4 次尝试一致；已排除锁屏（未锁+亮屏复现）、DDI（已挂载且兼容）、CoreDevice 服务重启因素。与上一轮三次 DTX 拒绝同根因，未解决。探针工程与 xctestrun 保留在私有 `zcode-physical-acceptance/probe/`。 |
| iPhone Mirroring 点击转发 + Universal Clipboard 中文搜索 | **成功**：AppleScript `click at`（Mac 点坐标）→ 手机触控；`cmd+V` 粘贴中文搜索词过滤目录。 |
| `devicectl device capture screenshot` | **成功**：33 张 1260×2736 真机原始截图即逐项证据。 |

附带说明：为 XCTest 尝试安装了 `HMZcodeAcceptanceUITests-Runner`（不影响主 App，可随时卸载）；无任何 HealthKit 写入、无数据库改动、无系统权限变更。

## 逐项结果（33/33 PASS）

| # | ID | 详情标题 | 关键观察（截图证据） | 窗口 |
|---|---|---|---|---|
| 1 | nightHRV | 夜间 HRV | 数值/单位/来源/趋势渲染正常（脱敏） | 01:19–01:20 |
| 2 | sleepHeart | 睡眠心率 | 数值/单位/来源/趋势渲染正常（脱敏） | 01:20 |
| 3 | load | 心率负荷 · 实验 | 数值/单位/来源/趋势渲染正常（脱敏） | 01:20 |
| 4 | heart | 心率 | 数值/单位/来源/趋势渲染正常（脱敏） | 01:20–01:21 |
| 5 | restingHeart | 静息心率 | 数值/单位/来源/趋势渲染正常（脱敏） | 01:21 |
| 6 | dayHRV | 全天 HRV | 数值/单位/来源/趋势渲染正常（脱敏） | 01:21–01:22 |
| 7 | vo2 | VO₂max · 设备估计 | 数值/单位/来源/趋势渲染正常（脱敏） | 01:22 |
| 8 | runPace | 跑步配速 | 数值/单位/来源/趋势渲染正常（脱敏） | 01:22 |
| 9 | runHeart | 跑步平均心率 | 数值/单位/来源/趋势渲染正常（脱敏） | 01:22–01:23 |
| 10 | recovery60 | 运动后1分钟心率下降 | 数值/单位/来源/趋势渲染正常（脱敏） | 01:23 |
| 11 | recovery120 | 运动后2分钟心率下降 | 数值/单位/来源/趋势渲染正常（脱敏） | 01:23 |
| 12 | steps | 步数 | 数值/单位/来源/趋势渲染正常（脱敏） | 01:24 |
| 13 | distance | 步行与跑步距离 | 数值/单位/来源/趋势渲染正常（脱敏） | 01:24 |
| 14 | activeEnergy | 活动能量 | 数值/单位/来源/趋势渲染正常（脱敏） | 01:24–01:25 |
| 15 | exercise | Apple 锻炼分钟 | 数值/单位/来源/趋势渲染正常（脱敏） | 01:25 |
| 16 | stand | 站立分钟 | 数值/单位/来源/趋势渲染正常（脱敏） | 01:25 |
| 17 | flights | 爬楼层数 | 数值/单位/来源/趋势渲染正常（脱敏） | 01:25–01:26 |
| 18 | runDistance | 已记录跑步距离 | 数值/单位/来源/趋势渲染正常（脱敏） | 01:26 |
| 19 | runMinutes | 已记录跑步时长 | 数值/单位/来源/趋势渲染正常（脱敏） | 01:26–01:27 |
| 20 | mainSleep | 主睡眠时长 | 数值/单位/来源/趋势渲染正常（脱敏） | 01:27 |
| 21 | totalSleep | 总睡眠时长 | 数值/单位/来源/趋势渲染正常（脱敏） | 01:27 |
| 22 | coreSleep | 主睡眠 · 核心阶段 | 数值/单位/来源/趋势渲染正常（脱敏） | 01:27–01:28 |
| 23 | deepSleep | 主睡眠 · 深睡阶段 | 数值/单位/来源/趋势渲染正常（脱敏） | 01:28 |
| 24 | remSleep | 主睡眠 · REM 阶段 | 数值/单位/来源/趋势渲染正常（脱敏） | 01:28 |
| 25 | weight | 体重 | 数值/单位/来源/趋势渲染正常（脱敏） | 01:17–01:19 |
| 26 | bodyFat | 体脂率 | 数值/单位/来源/趋势渲染正常（脱敏） | 01:28–01:29 |
| 27 | leanMass | 瘦体重 | 数值/单位/来源/趋势渲染正常（脱敏） | 01:29 |
| 28 | bmi | BMI | 数值/单位/来源/趋势渲染正常（脱敏） | 01:29–01:30 |
| 29 | respiratory | 呼吸频率 | 数值/单位/来源/趋势渲染正常（脱敏） | 01:30 |
| 30 | oxygen | 血氧饱和度 | 数值/单位/来源/趋势渲染正常（脱敏） | 01:30 |
| 31 | systolic | 收缩压 | 数值/单位/来源/趋势渲染正常（脱敏） | 01:30–01:31 |
| 32 | diastolic | 舒张压 | 数值/单位/来源/趋势渲染正常（脱敏） | 01:31 |
| 33 | temperature | 体温 | 数值/单位/来源/趋势渲染正常（脱敏） | 01:31 |

### 数值交叉验证

- 瘦体重 ≈ 体重 × (1 − 体脂率)，BMI 与体重身高量级一致，血压两项配对合理，血氧/呼吸/体温在合理范围（具体数值脱敏）。
- 夜间 HRV（主睡眠中位数）与全天 HRV（日汇总）分开统计，未混用。
- 单位换算（体脂 ×100、距离 m→km、睡眠 s→h、配速 秒→分′秒″）显示正确。
- 原始记录按钮仅出现在 sampleType 指标上，派生指标（负荷/配速/跑步心率/恢复/跑步距离/时长）无按钮——与代码口径一致。

### 「读取完成」判定说明

「本次读取／回溯计算：」位于详情页内容流末尾，部分项首屏截图未含该行。判定依据：`TrainingMetricContent` 仅在 snapshot 加载成功后渲染（TrainingParameterViews.swift:82–94），截图出现数值/趋势即证明读取完成；weight、steps 等短页截图直接含该标志。全部截图无「正在读取参数…」ProgressView、无「参数暂未更新：」错误。

## 证据索引（私有目录）

根目录：`/Users/nortepro/.codex/visualizations/2026/10/17/healthmanager-v2-release-device-validation/zcode-physical-acceptance/`

| 路径 | 内容 |
|---|---|
| `evidence/items/NN-<id>-detail.png` | 33 张真机详情截图（1260×2736） |
| `evidence/00-directory-entry.png` | 全部参数目录入口状态 |
| `evidence/items/25-weight-*.png` | 搜索过滤 / 详情 / 返回 三步留样 |
| `logs/session.log` | 每项起止时间戳操作日志 |
| `logs/pre-run-installed-app-state.txt` / `post-run-installed-apps.txt` | 主 App 未重装回读 |
| `ZCODE-REAL-DEVICE-CHECKLIST.completed.json` | 33 项 × 7 检查逐项回填 |
| `ZCODE-REAL-DEVICE-RESULT.json` | 本文档机器可读版 |
| `probe/` | XCTest 探针工程（Runner + UseDestinationArtifacts xctestrun，通道失败留档） |

## 33 项必要性评估（应用户要求）

**结论：代码路径上约 13 项是组内冗余，但本次全量执行成本已付，33 项均有独立证据，无需回退。**

- 34 个入口共享同一行模板（含 contentShape 修复）、同一详情视图、同一加载器；真正不同的只有 7 条数据通路：日汇总（13 项）、夜间睡眠派生（6）、跑步会话派生（4）、原始样本（7）、跑步聚合（2）、负荷（1）、心率中位数（heart）。
- 组内仅差 ID/单位列的项（如 coreSleep/deepSleep/remSleep、systolic/diastolic、recovery60/120、stand/flights、runDistance/runMinutes、restingHeart/dayHRV、leanMass/bmi 等 ≈13 项）在回归覆盖意义上可由代表项替代。
- 不可省的项：特殊格式（runPace 分′秒″、bodyFat ×100、distance m→km、totalSleep s→h、load bpm·min）、特殊来源（血压 correlation、vo2 设备估计）、预期空态（本轮实际全有数据）。
- 成本视角：镜像通道打通后每项约 20 秒，全量与抽样的边际成本差仅约 5–8 分钟，因此按原合同跑满 33 项是更干净的选择；若未来通道再次退化为纯手动，建议按上表分 7 组抽样。

## 遗留

- XCTest IDE 通道 DTX 拒绝根因未定位（Xcode 27.1 vs iOS 27.2 线索未验证）；不影响本验收结论，留档供后续排查。
- 次级入口（原始记录/来源与数据质量/年）真机路径未重跑，沿用既有模拟器 PASS；验收文档允许且不要求。
- 手机上多了一个测试 Runner app（`HMZcodeAcceptanceUITests-Runner`），可自行删除。

---

**脱敏说明**：本文件为仓库公开版，真实健康数值已移除；完整观察值见私有证据（`zcode-physical-acceptance/` 下截图与 RESULT-full.md）。
