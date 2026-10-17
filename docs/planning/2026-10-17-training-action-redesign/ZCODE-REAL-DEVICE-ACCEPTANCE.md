# ZCode 交接：HealthManager 锻炼 v2 剩余真机验收

日期：2026-10-18。当前整体状态：**PENDING**。本文件是接手任务书；以下未完成项没有被标为已通过。

## 直接执行的目标

在已经安装 Release 的真实 iPhone 上，用已有真实健康数据，补齐 **33 个参数入口**的逐项交互验收：从锻炼页正常点击参数行中心，进入正确详情，等待读取完成，检查数值／单位／来源／时间／趋势或合理空态，再返回锻炼页。输出逐项结果和证据，使真机参数覆盖从 **1/34** 达到 **34/34**。

用户已要求停止当前 Codex 的镜像／实机通道排查，改由 ZCode 接手。当前轮次只交付本文档，不再控制手机。用户只允许无线连接，希望尽量自主完成，不再反复配对、锁屏或解锁。

可直接给 ZCode 的指令：

> 请执行 `/Users/nortepro/HealthManager/docs/planning/2026-10-17-training-action-redesign/ZCODE-REAL-DEVICE-ACCEPTANCE.md`。沿用已经安装的 Release 和已有验证，只补齐其中 33 个待验收参数的真实 iPhone 交互证据。使用同目录 JSON 清单逐项回填，真实健康数据和截图保存到文档指定的私有目录。先解决你自己的可用控制通道，再继续验收；遇到通道错误要与产品错误分开记录。不要加入训练计划，不要重新安装或重复已通过项目来凑覆盖率。最终提交逐项结果、证据索引及整体 PASS／FAIL／PENDING／BLOCKED 判断。

## 可以沿用的结果

以下为此前实际验收记录，交接时未重跑。具体以 [DEVICE-RELEASE-VALIDATION.md](DEVICE-RELEASE-VALIDATION.md)、[同名 JSON](DEVICE-RELEASE-VALIDATION.json) 和对应私有收据为准。

| 项目 | 结果 | 接手处理 |
|---|---|---|
| 无线配对、签名 Release 安装、启动、安装身份回读 | PASS | 沿用，不重复部署 |
| 准备度、最新设备 VO₂max 的真实数据核对 | PASS | 沿用，不锁死旧数值 |
| 真机状态趋势 7／28／56 天，能力与活动量趋势 | PASS | 沿用已有页面证据 |
| 真机统一参数目录 | PASS | 作为本次验收入口 |
| 真机恢复准备度详情正常中心点击并加载 | PASS，1/34 | 不列入新 33 项；已直接观察，见证据边界说明 |
| 剩余参数的真实 iPhone 详情与返回 | PENDING，0/33 | 本次唯一必达的增量覆盖 |
| 复制真实数据库的隔离模拟器参数详情与返回 | PASS，34/34 | 仅辅助定位，不能抵作真机覆盖 |
| 同一模拟器运动列表、补录打开后取消、4 类原始记录入口 | PASS | 历史证据，避免重跑 |
| 既往 480 单元＋2 UI、独立深色 UI、Release 编译 | PASS | 软件层结果，不能抵作本次真机结果 |

准备度详情的通过来自当时 CUA 直接观察；随后试图保存的 `09-mirror-interruption.png` 只拍到了镜像中断，**不能把它当成详情截图**。该区别已记在 `physical-ui/OBSERVATIONS.json`。本次不要重做已经观察的准备度来替代剩余指标。

## 设备与已安装构建

| 字段 | 已有收据值 |
|---|---|
| 设备 | iPhone Air，iPhone18,4 |
| iOS | 27.2，24B5110a |
| UDID | `00008150-001204800152401C` |
| CoreDevice ID | `EAEB0E85-908F-5482-B719-1BB852BF57AD` |
| Bundle | `com.norte.HealthManager` |
| 版本 | 0.8.1 (17)；旧 Debug 标签相同，不能只凭版本判定身份 |
| 最终构建 | Release，优化 `-O`／whole-module，Apple Development 签名 |
| 最终可执行 SHA-256 | `2e185afda1cf47c8ed1350de83f5b2716599abe86fadddf5d083c430dc5dd896` |
| 可执行 UUID | `FD2FB366-5AB3-3711-8B48-6DC6D2B955CE` |
| 安装 Bundle URL | `file:///private/var/containers/Bundle/Application/69F16E85-01CB-4F67-A133-8FD7BF51AB4C/HealthManager.app/` |

现有构建已经修复参数行空白中心点不到的问题：`UI/Training/TrainingParameterViews.swift` 的链接标签增加 `.contentShape(Rectangle())`。因此验收须包含正常行中心点击，不能只点文字绕过此回归项。

目标源码由 [SOURCE-MANIFEST-RELEASE-FIX.json](SOURCE-MANIFEST-RELEASE-FIX.json) 的 21 文件哈希锁定。仅当安装身份存在新歧义时只读核对已有收据；无需通过重新安装确认。不要安装私有根目录中更早的旧 Release 包。

## 33 项清单

每项均执行下一节的同一套标准。机器可读清单：[ZCODE-REAL-DEVICE-CHECKLIST.json](ZCODE-REAL-DEVICE-CHECKLIST.json)。`readiness` 已完成，不在本表。显示标题与 ID 对照来自 `Core/Training/TrainingMetric.swift`。

### 心率与恢复（6 项）

| ID | 详情标题 | 显示单位 | 真机状态 |
|---|---|---|---|
| `nightHRV` | 夜间 HRV | ms | PENDING |
| `sleepHeart` | 睡眠心率 | bpm | PENDING |
| `load` | 心率负荷 · 实验 | bpm·min | PENDING |
| `heart` | 心率 | bpm | PENDING |
| `restingHeart` | 静息心率 | bpm | PENDING |
| `dayHRV` | 全天 HRV | ms | PENDING |

### 心肺与跑步表现（5 项）

| ID | 详情标题 | 显示单位 | 真机状态 |
|---|---|---|---|
| `vo2` | VO₂max · 设备估计 | ml/kg/min | PENDING |
| `runPace` | 跑步配速 | 分′秒″/km（内部秒/km） | PENDING |
| `runHeart` | 跑步平均心率 | bpm | PENDING |
| `recovery60` | 运动后1分钟心率下降 | bpm | PENDING |
| `recovery120` | 运动后2分钟心率下降 | bpm | PENDING |

### 活动量（8 项）

| ID | 详情标题 | 显示单位 | 真机状态 |
|---|---|---|---|
| `steps` | 步数 | 步 | PENDING |
| `distance` | 步行与跑步距离 | km | PENDING |
| `activeEnergy` | 活动能量 | kcal | PENDING |
| `exercise` | Apple 锻炼分钟 | 分钟 | PENDING |
| `stand` | 站立分钟 | 分钟 | PENDING |
| `flights` | 爬楼层数 | 层 | PENDING |
| `runDistance` | 已记录跑步距离 | km | PENDING |
| `runMinutes` | 已记录跑步时长 | 分钟 | PENDING |

### 睡眠（5 项）

| ID | 详情标题 | 显示单位 | 真机状态 |
|---|---|---|---|
| `mainSleep` | 主睡眠时长 | 小时 | PENDING |
| `totalSleep` | 总睡眠时长 | 小时 | PENDING |
| `coreSleep` | 主睡眠 · 核心阶段 | 小时 | PENDING |
| `deepSleep` | 主睡眠 · 深睡阶段 | 小时 | PENDING |
| `remSleep` | 主睡眠 · REM 阶段 | 小时 | PENDING |

### 身体关联（4 项）

| ID | 详情标题 | 显示单位 | 真机状态 |
|---|---|---|---|
| `weight` | 体重 | kg | PENDING |
| `bodyFat` | 体脂率 | % | PENDING |
| `leanMass` | 瘦体重 | kg | PENDING |
| `bmi` | BMI | kg/m² | PENDING |

### 其他生理参数（5 项）

| ID | 详情标题 | 显示单位 | 真机状态 |
|---|---|---|---|
| `respiratory` | 呼吸频率 | 次/分 | PENDING |
| `oxygen` | 血氧饱和度 | % | PENDING |
| `systolic` | 收缩压 | mmHg | PENDING |
| `diastolic` | 舒张压 | mmHg | PENDING |
| `temperature` | 体温 | ℃ | PENDING |

## 每项完成标准与操作顺序

1. 在真实 iPhone 的 HealthManager 打开「锻炼 → 全部参数」。可搜索标题或滚动定位；搜索可能命中多个条目，先确认实际目标。
2. 点击目标参数行的正常中心区域，确认进入与该 ID 对应的详情；不能把停留在目录、误入相邻项目或只点文字视为完成中心点击。
3. 等待「正在读取参数…」结束，看到内容及「本次读取／回溯计算：…」。初次读取可给约 90 秒观察时间；若仍未完成，记录等待时长、画面及工具状态，先判断 UI 操作是否真正送达。90 秒是排查触发点，不是未经测量的性能承诺。
4. 检查正确标题、单位、解释口径、当前数据窗口及测量时间／来源。有数据时检查显示是否合理、有无明显倍率或格式错误；目录与详情比较须对齐窗口与时间。默认详情窗口为 4 周，目录最新摘要可来自近 8 周，两处差异不能直接判错。
5. 检查趋势内容与该参数一致；有数据应能正常渲染且时间轴合理。真实窗口确无数据时，清晰空态也可通过；区分正常缺测、仍在加载与「参数暂未更新：…」错误。
6. 返回，确认导航标题重新为「锻炼」，且可以继续定位下一参数。返回后目录可能保留滚动位置，搜索框不在当前可见区域并不表示返回失败。
7. 将该项逐个检查结果、观察时间和证据路径写入清单，再测下一项。不要只在最后写一个 33/33 总数。

每个入口至少保留已加载详情的截图，以及能证明「行中心点击 → 正确详情 → 返回锻炼」的操作日志或录像时间点。工具给出了点击成功回执、打开了详情容器 ID，均不足以单独证明加载完成。

「相关原始记录」「来源与数据质量」「年」属于详情内次级入口。此轮 33 项的必达覆盖是参数行至详情再返回；既有模拟器次级入口结果已列明。若顺手补验真机次级入口，单列附加结果，不能用它代替缺失的参数主路径，也不要求为凑数量逐个重跑全部次级入口。原始记录按钮仅对 `sampleType != nil` 的指标存在，派生指标没有此按钮属于正常。

可使用的 Accessibility ID：

| 对象 | ID／标志 |
|---|---|
| 页面分区 | `training-sections`：总览／趋势／全部参数 |
| 搜索框 | `training-parameter-search` |
| 参数行 | `training-parameter-<id>` |
| 参数详情 | `training-metric-<id>` |
| 窗口选择 | `training-window`：7天／4周／8周 |
| 完成加载标志 | 文本前缀 `本次读取／回溯计算：` |
| 加载错误标志 | 文本前缀 `参数暂未更新：` |
| 相关原始记录 | `training-raw-records` |

## 数值和空态的判断边界

真实数据会同步增加，且日期已从 10 月 17 日切到 18 日。不要沿用旧截图的准备度、VO₂max 等固定数值作为当前断言。已有真实数据库副本只用于辅助核对，不代表此刻手机数据。

- 夜间 HRV 是主睡眠内同来源 SDNN 中位数，全天 HRV 是日汇总平均值；睡眠心率与静息心率也不是同一统计量，不能要求它们相等。
- 心率负荷为实验指标，只累加有覆盖且可计算的部分，单位 bpm·min。缺测不能填 0；负荷不能直接叫疲劳，也不能生成「疲劳＝100－准备度」。
- 配速内部为秒/km，显示成分′秒″/km 正常；不能把秒数直接当作分钟。跑步平均心率需要至少 70% 同来源覆盖，不足时缺值合理。
- 运动后 1／2 分钟心率下降采用目标时刻 ±15 秒读数，可出现负值，不应自动截断为 0。
- Apple 锻炼分钟不等于 Workout 时长；步行与跑步距离不等于已记录跑步距离。没有跑步记录不能解释成没有运动。
- 主睡眠按 18:00–次日 18:00 识别，午睡不并入；总睡眠与主睡眠口径不同。缺睡眠阶段时留空，不编造深睡／REM 时长。
- 留意原始米到 km、秒到小时，以及体脂率／血氧比例到百分比的换算。单位校验不通过的原始记录不能进入趋势。
- 设备 VO₂max、睡眠分期保留「设备估计」语义；准备度保留实验与可信度说明。此轮验收不对医学有效性背书。
- 「近8周暂无记录」和详情当前 4 周空态可以同时合理存在；只要读取已经成功完成、提示明确且与实际数据一致，就可记 `PASS` 并注明 `valid_empty`。禁止通过写入合成数据消除空态。

## 可沿用的通道排查结论

这里是已观察事实，**根因仍未解决**。ZCode 可使用其实际可用且获准的通道，先做一次小范围输入确认，再跑 33 项；不要盲目重复既有失败操作。

- 无线配对、安装链路已成功；镜像显示／输入通道与开发部署通道是两条链，镜像失败不等于安装失败。
- 既往三次实体 XCTest 在业务测试开始前发生控制连接／DTX 拒绝，尚未执行参数用例，不能据此判产品失败。本阶段没有新增真机 XCTest 重跑。
- CUA 的 `noWindowsAvailable` 曾同时出现在 iPhone 镜像和普通系统设置窗口的坐标点击。Mac 当时未锁屏，ScreenCapture 与 PostEvent 预检均为 true，因此不能直接归因为手机未解锁或新权限缺失。
- 镜像窗口已从外接屏移到内置屏的正坐标；重置 CUA 后一度能点 Connect，随后镜像内容操作仍被「应用已变化，请重新查询」保护拒绝或超时。移屏没有被证明解决根因。
- Device Hub 的 View Screen 会唤醒／保持实体屏幕活动。此前直接 Lock、立即退出且不打开预览，才回读到手机已锁屏和背光关闭。这是历史观察，不代表接手时仍处于相同状态。
- 「iPhone 使用中」会中断镜像。用户曾把手机放下供测试；接手时可先自主读回现状，不能把历史状态当成永久授权或持续在线保证。
- 当时只有 Xcode 27.1（27A9275），手机 iOS 27.2。版本差异只是待验证线索，尚无因果证据；不要把升级 Xcode 当成已证明的解决办法。
- 私有 `remaining-physical-routes/MirrorInput.swift`／`mirror-input` 只是编译并 dry-run probe 的原生事件替代原型，**没有执行事件**。上一轮对该替代技术的授权问题未获得答复，随后用户终止排查；阅读交接不意味着可以自动执行 `--execute`。接手工具选择遵守 ZCode 自身权限与本任务授权。

不得为了接通测试而卸载 App、清空数据库、重新灌入健康数据、改动证书／系统权限／网络安全设置。优先复用已有连接和签名。只有确认存在无法自主完成的物理或系统持有人操作时，才一次说明必要操作及阻断证据，避免重复要求配对／解锁。

## 文件地图与私有证据

应用数据流：`HealthKit 已入库原始记录／日汇总／运动记录 → TrainingSnapshotLoader／TrainingParameterLoader／TrainingCalculator → TrainingSnapshot → 锻炼总览／趋势／全部参数 → TrainingMetricDetail`。本轮主要验证最后两步在物理设备上的交互与显示，计算逻辑与源码无需重写。

仓库内可公开于本项目的记录：

- [DEVICE-RELEASE-VALIDATION.md](DEVICE-RELEASE-VALIDATION.md)／[JSON](DEVICE-RELEASE-VALIDATION.json)：安装与本轮真实数据的权威结果。
- [HANDOFF.md](HANDOFF.md)：实施上下文与回滚边界。
- [SOURCE-MANIFEST-RELEASE-FIX.json](SOURCE-MANIFEST-RELEASE-FIX.json)：最终源码哈希。
- [WIRELESS-RESUME-VALIDATION.md](WIRELESS-RESUME-VALIDATION.md)：先前无线续接记录。

私有证据根目录：

```text
/Users/nortepro/.codex/visualizations/2026/10/17/healthmanager-v2-release-device-validation
```

| 相对私有根目录的路径 | 用途 |
|---|---|
| `parameter-hit-region-fix/release-install-receipt.json` | 最终安装收据 |
| `parameter-hit-region-fix/release-launch-receipt.json` | 启动收据 |
| `parameter-hit-region-fix/release-app-readback.json` | 已安装身份回读 |
| `parameter-hit-region-fix/release-package-verification.json` | 签名／构建身份 |
| `parameter-hit-region-fix/signed-release/HealthManager.app` | 最终已安装包的保留副本 |
| `parameter-hit-region-fix/physical-ui/OBSERVATIONS.json` | 既有真机观察与截图边界 |
| `parameter-hit-region-fix/ui-data-crosschecks.json` | 既有真实数据核对 |
| `parameter-hit-region-fix/copied-real-data-ui-summary.json` | 模拟器 34/34 结果 |
| `parameter-hit-region-fix/copied-real-data-ui-attachments/manifest.json` | 模拟器附件索引 |
| `copied-real-data-probe/` | 成功的隔离模拟器用例；旧数值断言不可直接套到当前手机 |
| `readonly-device-probe/HealthManager_v2_installed-artifacts.xctestrun` | `UseDestinationArtifacts=true`，旨在复用已安装目标；控制通道此前仍失败 |
| `remaining-physical-routes/INPUT-CHANNEL-DIAGNOSIS.json` | 本阶段只读诊断结果，新增参数覆盖 0 |
| `zcode-physical-acceptance/` | 建议 ZCode 新建的私有输出目录 |

避免直接使用旧 `exact-release-standard.xctestrun`：其普通部署流程可能重新安装较早产物。`seed-v2-qa.py` 是合成 QA 工具，**不能用于真机或真实数据库**。

成功的复制真实数据模拟器原生结果路径：

```text
/Users/nortepro/Library/Developer/XcodeBuildMCP/workspaces/HealthManager-8bdea649e903/result-bundles/test_sim_2026-10-17T15-28-49-516Z_pid99068_113c6081.xcresult
```

该用例最终 1 passed／0 failed／0 skipped，内部覆盖 34 参数；工具外层 300 秒超时，但原生 Xcode 322.424 秒成功，已读回结果，无需因外层超时重跑。

## 回填格式与最终通过条件

复制或回填同目录 JSON 清单。每项保留 `id`，将七个 `checks` 逐项记录为 PASS／FAIL／PENDING，填写整体 `status`、`observed_at`、`evidence_paths` 和简短 `notes`。若需记录真实数值、测量时间或来源详情，写进私有 JSON；仓库摘要只引用路径和判断。返回证据可为操作日志／录像片段索引，不强制每项另存返回截图。

`PASS` 仅表示该验收路径及数据展示有证据；无数据时注明 `valid_empty`。产品实际错误为 `FAIL`；未执行或证据不足为 `PENDING`；缺少无法自主取得的权限、凭据或必要物理操作才用 `BLOCKED`，注明阻断点。自动化／镜像框架失败单列工具问题，不能冒充参数功能失败。

整体 **PASS** 需要同时满足：

- 新清单 33 个不同 ID 全部完成，七项检查均有证据支持，无遗留加载错误、误路由或返回失败。
- 真机总覆盖明确写为「既有准备度 1 + 本次其余 33 = 34/34」，模拟器结果单独列出。
- 所有证据来自目标 iPhone 的已安装目标 Release；若修复导致构建变化，另记新身份与受影响回归，不能混用不同构建凑出一套结果。
- 输出 `ZCODE-REAL-DEVICE-RESULT.md/.json`，包含逐项状态、开始／完成时间、设备／构建引用、截图与日志索引、失败原因、遗留项及环境变化。未完成就保留实际完成数，不写全量通过。
- 保留现有 dirty worktree、数据库与安装前备份；不 reset／stash／clean／批量暂存／提交／推送。私人健康数值和截图不得进入仓库。

若发现产品缺陷，先留证据并明确复现条件，再做必要修复和对应验证；不要因工具通道故障改动已经通过的计算器。当前目标不包含新增训练计划、重做评分、扩展传感器采集、临床有效性研究或全量历史重验。

## 环境与回滚边界

已保留修复前源码、旧签名包及两份安装前数据库备份，未执行数据库恢复或 App 回退。原 SSID Haeuschen_5G 已恢复，IPv4 手动配置未改；先前为无线开发把 IPv6 从 Off 改为 LinkLocal 后保留。最近核实 VoiceOver 为关闭，未授予新的辅助功能权限。此轮镜像窗口移到内置屏；最后使用直接退出 Device Hub，模拟器当前启动状态未重新核实，接手不依赖它。

上述为最后观察／记录，不能当成接手瞬间的实时状态。若需要回滚，限定到实际新增改动；无需为本次文档交接执行任何环境恢复或重部署。
