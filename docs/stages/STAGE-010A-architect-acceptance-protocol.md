# STAGE-010A 主架构师验收协议

> 状态：PASS（2026-07-16，已逐门执行）
>
> 适用实现：STAGE-010A Coder diff
>
> 判定者：主架构师；Coder 的 `DONE` 只表示交付验收，不等于 PASS

## 1. 验收目标

证明本阶段不仅能编译，而且同时满足：

1. 新 UI 基础没有改变 HealthManager 的业务事实和权限合同；
2. Onboarding、Apple 健康不可用、Today loading / failure 与选定视觉语言一致；
3. light / dark、默认字号 / accessibility-large、Reduce Motion 和可访问性语义没有明显回退；
4. diff 严格停在 STAGE-010A，不提前实现后续页面；
5. unit / UI tests 的通过数量来自新的 `.xcresult`，不是旧日志或 `xcodebuild` 尾行。

四个表面中任一没有可复核视觉证据时，本阶段整体最多为 `INCOMPLETE`。

## 2. 验收前固定事实

- 预期起点：`main` @ `3e657fa`；
- Coder 开始前只有本轮设计 docs / PNG 改动，没有 Swift 或工程实现 diff；
- 目标环境：iPhone 17 / iOS 26.5 / portrait / `zh-Hans` / `zh_CN` / `Asia/Shanghai`；
- 对照依据优先级：真实代码与数据合同 → 设计合同 → ADR-002 → PNG；
- STAGE-010A 不验证 Today loaded、五个一级页面或真实 HealthKit 数据。

若验收时 HEAD、未知代码 diff 或目标 Runtime 已改变，先记录差异并重新判断起点，不能静默沿用本协议中的基线陈述。

## 3. 判定规则

- `PASS`：该门要求和原始证据全部存在，且没有反例；
- `FAIL`：代码或运行结果明确违反合同；
- `INCOMPLETE`：未执行、证据缺失、工具阻塞，或只能从间接证据推断；
- 任一硬门 `FAIL`，STAGE-010A 整体 `FAIL`；
- 任一硬门 `INCOMPLETE`，STAGE-010A 整体最多 `INCOMPLETE`；
- 只有 G0～G9 全部 `PASS`，才能把任务书状态改成 `PASS` 并生成 STAGE-010B 最终提示词。

## 4. 验收矩阵

| 门 | 硬性要求 | PASS 证据 | 失败示例 |
|---|---|---|---|
| G0 起点 | Coder 基于预期 HEAD 和已知 docs diff 开始 | Coder preflight 原文；主架构师复查 HEAD / status | 删除或覆盖设计资产；混入未知代码 |
| G1 范围 | 只改任务书允许的文件；project diff 仅为 XcodeGen 机械纳入 | `git diff --name-status`、逐文件 diff、project diff | 修改 `Core/`、schema、同步、LLM、Today loaded 或其他页面 |
| G2 设计基础 | token 轻量、动态、被真实复用；`CardTheme` 责任不变 | 代码审查；使用点清单；无死组件 | 第二套指标主题、强制浅色、全局批量迁移 |
| G3 Onboarding | 数据路径、读取 / 按需写回、第三方和 AI 边界准确；原动作 seam 不变 | 源码 diff；light / dark / 大字号截图；可访问性树或检查结果 | “数据绝不外发”；改变权限集合；错误不可见 |
| G4 Health unavailable | 不再归因“用户拒绝”；重新检测和本地数据说明准确 | 源码 diff；三组截图；按钮实际仍接 refresh seam | 虚构设置深链；改 `AuthorizationGate` 判断 |
| G5 Today loading | 中性、无虚假值 / 来源 / 缺失；保留最终布局节奏；Reduce Motion 无 shimmer | 三组截图；Reduce Motion 运行记录；identifier 检查 | 只有居中 spinner；出现真实数值或错误语义色 |
| G6 Today failure | 显示真实 message、重试、技术信息；保留 identifier；不改 state machine | 三组截图；可访问性树；重试 closure 测试或代码证据 | 使用 `CardTheme` 表达通用失败；清空有效内容；吞掉错误 |
| G7 视觉对照 | 克制但有辨识度；层级、留白、语义色和参考一致，未照抄错误事实 | 同视口参考 / 实现对照图；每张原图实际打开审阅 | 逐像素照抄错误文案；卡片套卡片；装饰性炫技 |
| G8 无障碍 | 44 pt 点击区；颜色非唯一信号；默认 / 大字号无关键裁切；读序合理 | accessibility-large 截图；可访问性树 / Inspector 记录；代码审查 | 固定高度裁切；图标按钮无 label；仅靠颜色 |
| G9 构建测试 | 新结果包，0 failed；计数、warning / error、设备和 OS 可复核 | 命令、exit code、`.xcresult`、`xcresulttool` JSON、status / diff | 只报尾行；复用旧 result；失败后仍写 PASS |

## 5. 必须取得的视觉证据

四个表面：

1. Onboarding；
2. Apple 健康不可用；
3. Today loading；
4. Today failure（使用明确的展示错误文案，不伪装真实线上错误）。

每个表面至少保留以下三种状态，共 12 张：

- light + 默认 `large`；
- dark + 默认 `large`；
- light + `accessibility-large`（或 SwiftUI `.accessibility2`，必须记录实际值）。

约束：

- 使用同一 iPhone 17 portrait 视口；记录 Simulator 名称、UDID、iOS、语言、区域、时区、外观和字号；
- Onboarding 可使用 disposable Simulator 的真实首次启动；不可稳定到达的状态使用编译通过的纯展示 Preview；
- 为 Preview 拆分纯展示 content 时，production shell 仍持有 `EnvironmentObject`、异步动作和业务状态；
- 不允许新增生产 debug router、假权限、数据库 seeder 或运行时 fixture；
- 每张导出图必须由主架构师实际打开检查，空白、加载中、裁切或错误窗口的图片作废；
- `20-onboarding.png`、`21-health-unavailable.png`、`28-today-loading.png` 与对应 light/default 实现截图组成同视口对照图；failure 按共享恢复组件合同审查；
- 截图只能证明可见结果，不单独证明 VoiceOver、对比度或 Reduce Motion。

建议归档目录：

```text
/tmp/healthmanager-stage010a-acceptance-20260716/
  environment.txt
  screenshots/
  comparisons/
  accessibility/
  test-summary.json
  build-results.json
  git-evidence.txt
```

## 6. 主架构师执行顺序

### 6.1 Diff 与范围

```bash
cd /Users/nortepro/HealthManager
git status --short --branch
git rev-parse --short HEAD
git diff --name-status
git diff --stat
git diff --check
```

随后逐文件阅读 diff；搜索 `Core/`、migration、HealthKit 请求、同步、LLM、Today loaded 和五栏页面是否出现越界变化。不能只依赖文件名清单。

### 6.2 生成工程并运行新测试

若 Coder 新增 Swift 文件：

```bash
xcodegen generate
```

使用从未存在的新 attempt 路径：

```bash
xcodebuild \
  -project HealthManager.xcodeproj \
  -scheme HealthManager \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -resultBundlePath /tmp/healthmanager-stage010a-final-20260716-attemptNN.xcresult \
  test
```

读取机器结果：

```bash
xcrun xcresulttool get test-results summary \
  --path /tmp/healthmanager-stage010a-final-20260716-attemptNN.xcresult

xcrun xcresulttool get build-results \
  --path /tmp/healthmanager-stage010a-final-20260716-attemptNN.xcresult
```

记录实际 executed / passed / failed / skipped、warning / error、destination 与 exit code。`test` 已包含本轮构建；如出现增量污染、工程纳入异常或 warning 漂移，再用独立 DerivedData 增加冷构建，不能用冷构建替代全量 test。

### 6.3 视觉与无障碍审查

1. 先检查 Coder 提供的 Preview / 截图是否能从当前 diff 重现；
2. 主架构师独立渲染或运行四个表面，不直接接受 Coder 的目视结论；
3. 导出 12 张状态图，并按第 5 节制作三张参考对照；
4. 检查标题层级、空白、语义色、按钮权重、长文案换行、状态栏 / 安全区和 TabBar 边界；
5. 检查 accessibility label / value / hint、读序、44 pt、颜色外信号；
6. 开启 Reduce Motion 重新观察 loading，确认没有持续 shimmer；
7. 对 token 实际值重新计算正文对比度，不从颜色名称推断合规。

## 7. 不允许外推的结论

STAGE-010A 即使 PASS，也不能证明：

- 五个一级页面或任何 loaded 页面完成改版；
- 真实 iPhone HealthKit 授权、数据读取或同步正确；
- 全 App dark mode、Dynamic Type、VoiceOver 或 WCAG 合规；
- STAGE-010B～010F 可以跳过；
- 29 张参考图已经全部实现。

## 8. 正式结果模板

```text
STAGE-010A 主架构师结论：PASS / FAIL / INCOMPLETE

实现基线：
验收 diff：

G0 起点：
G1 范围：
G2 设计基础：
G3 Onboarding：
G4 Health unavailable：
G5 Today loading：
G6 Today failure：
G7 视觉对照：
G8 无障碍：
G9 构建测试：

测试：
- command / exit code
- executed / passed / failed / skipped
- warnings / errors
- xcresult

视觉证据：
- 环境
- screenshot / comparison / accessibility 路径

边界与残余风险：
下一步：
```

## 9. 2026-07-16 正式判定

STAGE-010A 主架构师结论：`PASS`。

| 门 | 结果 | 证据摘要 |
|---|---|---|
| G0 起点 | PASS | HEAD `3e657fa`；既有 docs / PNG 输入均保留。 |
| G1 范围 | PASS | 只涉及 DesignSystem、Onboarding、Root denied surface、Today loading / failure 及规划文档；无 Core / schema / loaded diff。 |
| G2 设计基础 | PASS | 动态语义 token 和 7 个被真实使用的共享基础类型；`CardTheme` 未改；验收轮已删除死组件 / token。 |
| G3 Onboarding | PASS | 数据路径、读取 / 按需写回、第三方、AI 边界准确；request / refresh seam 保持；三组截图已打开。 |
| G4 Health unavailable | PASS | 不再归因用户拒绝；重试仍调用 `refreshAuthorizationGate()`；默认首屏可见主动作；三组截图已打开。 |
| G5 Today loading | PASS | 静态中性骨架、无值 / 来源 / 缺失语义、无 shimmer；三组截图已打开。 |
| G6 Today failure | PASS | 真实 message、折叠 / 可复制技术信息、重试与既有 identifier 保留；state machine diff 为零。 |
| G7 视觉对照 | PASS | `20`、`21`、`28` 与 runtime 同视口 hstack 对照已实际打开；修复了不可用页纵向误布局和标签断行后无 P0 / P1 / P2。 |
| G8 无障碍 | PASS | 44 pt 动作、图标 + 文字、无固定文本高度；accessibility-large 使用真实 `content_size=accessibility-large` 取证，内容在 ScrollView 中可达。 |
| G9 构建测试 | PASS | 新结果包 258 / 258，0 failed / skipped，build succeeded，0 error，1 个既有 warning。 |

视觉与测试路径：

```text
/tmp/healthmanager-stage010a-acceptance-20260716/screenshots/
/tmp/healthmanager-stage010a-acceptance-20260716/comparisons/
/tmp/healthmanager-stage010a-architect-final-20260716-attempt01.xcresult
```

验收用 `-HM_STAGE010A_*` 临时展示入口只存在于取证构建；12 张截图完成后已从源码删除。随后重新 XcodeGen，并在不含该入口的正式 diff 上执行上述 258 项全量测试。
