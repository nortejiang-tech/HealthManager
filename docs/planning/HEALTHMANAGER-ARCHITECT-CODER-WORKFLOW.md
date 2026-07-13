# HealthManager 主架构师—Coder 协作与迭代总图

> 建立日期：2026-07-13
>
> 当前产品基线：v0.2.5 / main / HEAD 8c03941
>
> 角色约定：本会话负责架构、任务书、提示词和独立验收；Coder 会话只实现当前已批准 STAGE。

## 1. 这套协作解决什么问题

HealthManager 后续开发会跨会话、跨模型接力。为了避免便宜模型在缺少上下文时扩大范围、重做架构或把部分测试成功写成整体通过，所有非小修复都执行以下闭环：

1. 主架构师固定需求边界，必要时写 Proposed ADR。
2. 主架构师先写 STAGE 任务书，再生成一条自包含的 Coder 提示词。
3. Coder 只修改当前 STAGE 允许的文件，不自行扩产品范围、不提交 Git。
4. Coder 返回实际改动、命令和结果，不自行宣布架构验收通过。
5. 主架构师直接检查共享工作区的状态、diff、实现和测试，给出 PASS / FAIL / INCOMPLETE。
6. 只有 PASS 才生成下一阶段提示词。后续精确提示词按已验收代码即时生成，不提前假设 Coder 会怎样实现。

依据的方法论：

- [ENGINEERING-METHODOLOGY.md](</Users/nortepro/Library/Mobile Documents/com~apple~CloudDocs/Personal/ENGINEERING-METHODOLOGY.md>)
- [竞品研究与本产品路线](../research/2026-07-13-health-app-competitor-primary-research.md)

## 2. 三方职责

### 主架构师会话

- 决定产品边界、模块、接口、seam、数据不变量和失败语义。
- 对不可逆或跨阶段决策写 ADR；证据不足时只允许 Proposed。
- 把工作拆成可独立验收的 STAGE，并为每一阶段生成提示词。
- 每次验收重新读取真实 git diff 和运行结果，不接受“应该能过”。
- 维护 STAGE 的正式状态和最终 HANDOFF。
- 当 Coder 不能满足质量门槛时，向用户申请接管；没有得到同意前不擅自扩大职责。

### Coder 会话

- 只实现提示词指定的一个 STAGE。
- 不改变 ADR，不重新定义需求，不顺手做相邻功能。
- 不修改已应用迁移；数据库变更只能追加新迁移。
- 不删除或覆盖主架构师生成的 docs 文件。
- 不提交、不打 tag、不 push，除非之后得到用户明确授权。
- 只报告实际执行证据，不把未运行项写成 PASS。

### 用户

- 把当前 STAGE 的提示词交给 Coder。
- Coder 完成后回到本会话，发送“Coder 已完成 STAGE-XXX”；可以附上 Coder 最终输出，但不是必须，因为工作区共享。
- 决定是否批准主架构师接管高风险技术点，以及是否创建阶段提交。

## 3. 固定验收协议

### 3.1 三态结论

- PASS：范围内所有完成标准都有可复现证据。
- FAIL：已经验证，至少一个必需条件不成立。
- INCOMPLETE：缺少真机、数据或外部条件，不能作出结论。

总体状态取最弱子项，不能用一个通过的单测掩盖迁移、构建或运行时失败。

### 3.2 主架构师每阶段必查

1. git status 是否出现越界文件、覆盖用户改动或破坏性操作。
2. diff 是否只解决当前目标，是否修改了已应用迁移。
3. 新模块是否把复杂性收在一个小接口后，而不是把数据库逻辑继续散落到 View。
4. 错误和未知值是否显式；不得把 nil 静默变成 0，不得提前报告成功。
5. 数据写入、删除和 HealthKit 往返是否保持幂等与无损。
6. 定向测试、全量单元测试、构建或 UI/真机验证是否与 STAGE 的验证边界一致。
7. 文档中的 PASS / FAIL / INCOMPLETE 是否与真实证据一致。

### 3.3 修复与接管门槛

默认允许 Coder 接受一次针对性返工提示。出现下列任一情况，主架构师直接申请接管，而不是继续让便宜模型试错：

- 同一结构性缺陷在一次返工后仍重复出现。
- 修改已应用迁移、造成数据丢失风险或破坏 HealthKit 幂等语义。
- 通过在 UI、数据库和同步层复制逻辑来“修好测试”，没有形成清晰 seam。
- 测试无法稳定复现并涉及并发、迁移恢复、跨进程/HealthKit 后置条件。
- 需要建立动态能量模型、数据许可/导入架构或跨域统计推断等高判断密度实现。
- Coder 的补丁需要主架构师重写核心部分才能达到标准。

小型语法、命名、漏测或单文件范围问题优先给 Coder 一次精确返工机会。

## 4. 当前已验证基线

2026-07-13 在未修改功能代码的 main 上实测：

- Xcode 26.6（17F113）
- iPhone 17 Simulator，iOS 26.5
- HealthManagerTests：112 tests，0 failures
- HealthManagerUITests：1 test，0 failures
- xcodebuild 结果：TEST SUCCEEDED
- 结果包：/Users/nortepro/Library/Developer/Xcode/DerivedData/HealthManager-ggcivopbkrhyayfzwvojpwacksqd/Logs/Test/Test-HealthManager-2026.07.13_22-19-58-+0800.xcresult

任何阶段新增失败时，先区分既有环境/工具失败与被测代码失败。

## 5. 近期阶段图：v0.3“可信记录基础”

| 阶段 | 目标 | 依赖 | 主要执行者 | 风险 |
|---|---|---|---|---|
| ADR-001 | 决定餐食分项采用规范化快照表与 MealStore seam | 已完成竞品和代码基线 | 主架构师 + 用户确认 | 高判断、低代码 |
| STAGE-001 | 追加 meal_items schema、记录类型和迁移测试 | ADR-001 Accepted | Coder | 中 |
| STAGE-002 | 建立 MealStore 深模块，原子 load/save/delete 和总量投影 | STAGE-001 PASS | Coder；架构师严审 | 中高 |
| STAGE-003 | 把 EditableNutritionItem 从 View 抽成可测试的 MealItemDraft | STAGE-002 PASS | Coder | 低中 |
| STAGE-004 | MealEditView 真正加载/保存分项，保持照片与 HealthKit 语义 | STAGE-003 PASS | Coder；必要时接管 | 高 |
| STAGE-005A | 最近餐、常用克数、整餐/选中项复制的查询与复制语义 | STAGE-004 PASS | Coder | 中 |
| STAGE-005B | 在饮食界面加入低摩擦复用入口 | STAGE-005A PASS | Coder | 中 |
| STAGE-006 | 展示手工/AI/数据库/标签来源、置信度和用户修订状态 | STAGE-005B PASS | Coder | 中 |
| STAGE-007A | 今日/饮食/用药/趋势/更多信息架构原型 | STAGE-006 PASS | 主架构师 + 用户试用 | 产品判断 |
| STAGE-007B | 仅按已确认原型调整导航，不删除诊断能力 | STAGE-007A Accepted | Coder | 中 |
| STAGE-008 | 睡眠效率正确计算或在证据不足时隐藏 | 可与导航后串行 | Coder | 中 |
| STAGE-009 | 数据迁移、全量测试、Simulator/真机边界和 v0.3 HANDOFF | 前述全部 | 主架构师 | 发布门 |

这一路线不加入社区、电商、广告、课程平台、自动目标或下一餐教练。

## 6. 后续阶段图

### v0.4：有来源的数据与个人记忆

1. 新 ADR：FoodDataSource seam、数据许可、离线策略和版本化。
2. 食品目录与用户自建/标签条目的统一候选模型。
3. 营养标签 OCR、条码候选与每份/每 100g 校验。
4. 本地个人纠正记忆。
5. App Intent、Shortcut、组件和可选 Watch 快捷动作。
6. 一条可行动的今日简报。
7. 个人能量消耗 shadow mode；该阶段默认由主架构师实现或严密主导。

### v0.5：只有实验通过后才进入

- 用户主动开启的热量/宏量目标和下一餐建议。
- 有完整来源时的微量营养素。
- 训练日/休息日模板、食谱与采购清单。
- 跨睡眠/活动/饮食/体重/用药的相关性提示。
- 明确授权的家庭或专业人士共享。

## 7. Coder 提示词生成规则

每个提示词必须包含：

1. 唯一 STAGE 编号和唯一目标。
2. 预期起点、必须先读的 ADR/STAGE/代码文件。
3. 允许修改与禁止修改的范围。
4. 模块、接口、seam、不变量、失败语义和迁移纪律。
5. 可执行测试命令及本阶段不验证什么。
6. 输出格式、无提交要求、遇到越界情况的停止条件。

后续提示词不提前批量固化。只有前一阶段由主架构师正式 PASS 后，才根据真实 accepted diff 生成下一条，避免下游提示词建立在不存在的实现上。

当前可交给 Coder 的第一条提示词：

- [STAGE-001 Coder 提示词](../coder-prompts/STAGE-001-meal-items-schema.md)

对应任务书：

- [STAGE-001 任务书](../stages/STAGE-001-meal-items-schema.md)

对应架构决策：

- [ADR-001](../adr/ADR-001-normalized-meal-item-snapshots.md)

## 8. Git 与文档纪律

- 当前默认不提交。Coder 完成后保持 diff，交由主架构师验收。
- PASS 后主架构师会给出是否适合创建 checkpoint 的意见；commit/tag/push 仍需用户明确授权。
- Coder 不得使用 reset --hard、checkout --、clean 或删除未跟踪 docs。
- STAGE 的正式结果由主架构师回填；Coder 最终消息只是执行证据。
- 一轮跨多个 STAGE 的工作结束时，主架构师生成 HANDOFF，集中记录验证矩阵、架构现状与技术债。

## 9. 2026-07-13 夜间连续执行授权

用户已回复“全部按建议执行”，本轮追加以下临时授权：

- ADR-001 Accepted。
- STAGE-007 采用“今日 / 饮食 / 用药 / 趋势 / 更多”五栏方向；不删除现有能力，来源、同步中心、设置与诊断入口收纳至“更多”。
- 优先通过 Codex CLI 指定 `gpt-5.3-codex-spark` 承担 Coder；不可用或额度耗尽时可切换到当前账户可用的较低成本模型。
- Coder 一次针对性返工仍不达标，或遇到迁移、HealthKit 幂等、并发恢复等高风险点时，主架构师可直接接管，不再等待用户确认。
- 每个正式 PASS 阶段可在 `codex/health-planning-20260713` 创建 checkpoint commit 并 push。
- 今晚禁止合并 `main`、打 tag 或发布正式版本。
- STAGE-009 完成软件、迁移、全量测试和 Simulator 验证；真机验证如未执行必须标为 INCOMPLETE，并进入次日 HANDOFF。
