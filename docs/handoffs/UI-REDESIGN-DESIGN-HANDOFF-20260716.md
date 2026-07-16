# 交接文档：HealthManager 全页面 UI 改版设计阶段

> 日期：2026-07-16
>
> 代码基线：`main` @ `3e657fa`
>
> 设计阶段：PASS
>
> 实现阶段：STAGE-010A～010H PASS（2026-07-16 补记）

> 本文保留为设计阶段历史交接；完成后的代码、验证与边界以 [最终实施交接](UI-REDESIGN-IMPLEMENTATION-HANDOFF-20260716.md) 为准。

## 1. 本轮做了什么

| 项 | 内容 | 状态 | 产物 |
|---|---|---|---|
| 产品边界复核 | 结合现有代码、既有竞品研究和 v0.3 事实合同排除不可证明能力 | PASS | ADR-002、设计合同 |
| 视觉方向探索 | 从常规、概念化、极简三轮收敛到“基线叙事 + 局部决策透镜” | PASS | ADR-002 |
| 五个一级页面 | 今日、饮食、用药、趋势、更多均有目标 | PASS | 01–05 参考图 |
| 记录 / 编辑 | 餐食、证据、复用、用药计划、活动补录有目标 | PASS | 06–07、15–16、22、29 |
| 证据 / 运维 | 指标、活动、质量、来源、同步、告警、总结、运动有目标 | PASS | 08–14、24–26 |
| 设置 / AI / 权限 | 数据去向、双通道 AI、接口、授权和不可用状态有目标 | PASS | 18–23、25 |
| 跨页面状态 | 空白、加载、权限、失败、部分成功、未知和估算均有合同 | PASS | 21、25–29 |
| 视觉资产固化 | 29 张筛选后的参考图复制进仓库稳定目录 | PASS | `docs/design/assets/ui-redesign-2026-07-16/` |
| 实施拆解 | 010A～010H 路线和逐阶段 Coder 提示词 | PASS | 设计合同、STAGE-010A～010H、Coder prompts |

## 2. 关键决策（接手必读）

1. **一个页面最多一个表达性结构。** 其他内容靠排版、空白和分隔线组织，不把全部内容卡片化。
2. **四个语义色表达证据状态，而不是健康好坏。** 蓝=比较，青绿=确认事实，橙=缺失 / 处理，紫=估算 / 外部可选。
3. **现有 `CardTheme` 继续表达指标家族。** 新语义层不能替换它，也不能让指标色承担确认 / 失败语义。
4. **视觉稿不是事实合同。** Today 主参考、饮食主参考和日报参考中存在刻意标记的结构型示例；必须按设计合同纠正，不得逐字照抄。
5. **默认本地与可选外发同时成立。** 设置页必须准确解释聚合文本和用户选择图片的外发边界。
6. **未知、权限和估算保持诚实。** 不把无样本当无授权，不把人工修订当验证，不把 `nil` 当 `0`，不推断缺餐或漏服。

## 3. 架构现状

```text
现有业务事实 / Store / Loader
          │
          ├── 指标家族身份 ──> CardTheme（保留）
          │
          └── 证据状态 ─────> 新 HM semantic tone
                                │
                                ├── Editorial header
                                ├── Evidence / provenance rail
                                ├── Decision lens
                                ├── Empty / loading / recovery
                                └── 页面按阶段迁移
```

新 UI 层只能格式化和组织既有事实，不在 View 中重做 SQL、聚合、营养、能量、权限或同步判断。

## 4. 视觉资产边界

稳定目录：

```text
docs/design/assets/ui-redesign-2026-07-16/
```

目录含 29 张 PNG 和一份逐图使用说明。明确排除：

- 错误地给饮食摄入加号的活动详情；
- 使用“良好 / 一致”无依据结论的数据质量初稿；
- 健康天气、牵强编织和纯系统列表方向。

三张“structure-only”参考必须按 README 纠偏：

- Today：不实现“午餐尚未记录”或自动试算；
- 饮食：不生成固定晚餐空节点；
- 日报 / 周报：不照抄“适中 / 与基线一致”等 AI 结论；
- 添加 AI 接口：普通提交不用警告橙。

## 5. 验证矩阵

| 验证 | 当前结果 | 证据 / 边界 |
|---|---|---|
| 当前 app 只读 smoke | PASS：1/1，0 failure | `/tmp/healthmanager-redesign-audit-20260716.xcresult`；iPhone 17 Pro / iOS 26.5 |
| 当前页面截图巡检 | PASS（作为设计输入） | `/tmp/healthmanager-redesign-audit-attachments-20260716/` |
| 稳定参考资产数量 | PASS：29 | `find docs/design/assets/ui-redesign-2026-07-16 -name '*.png'` |
| 设计合同覆盖页与状态 | PASS | 设计合同第 5～6 节 |
| 最终 source code build / tests | PASS | STAGE-010H 正式构建成功、定向 87 / 87、清理后全量 258 / 258 |
| 改版运行时视觉 | PASS | 010A～010G 分阶段参考 / runtime 对照、dark、Dynamic Type、Reduce Motion；010H 关键修复复验 1 / 1 |
| 真机改版验证 | NOT RUN | 本轮明确不做；Simulator 不外推真实 iPhone VoiceOver、触觉、系统权限面板或真实 AI 请求 |

## 6. 文件地图

- 决策：[ADR-002](../adr/ADR-002-evidence-led-functional-ui-language.md)
- 全页面合同：[2026-07-16 UI redesign contract](../design/2026-07-16-ui-redesign-design-contract.md)
- 视觉索引：[assets README](../design/assets/ui-redesign-2026-07-16/README.md)
- 首阶段任务书：[STAGE-010A](../stages/STAGE-010A-ui-foundation-and-root-states.md)
- 首阶段验收协议：[STAGE-010A architect acceptance](../stages/STAGE-010A-architect-acceptance-protocol.md)
- 首阶段提示词：[STAGE-010A Coder prompt](../coder-prompts/STAGE-010A-ui-foundation-and-root-states.md)
- 协作规则：[HealthManager architect–Coder workflow](../planning/HEALTHMANAGER-ARCHITECT-CODER-WORKFLOW.md)

## 7. 实施完成补记

实施最终按 010A 根状态、010B 一级页、010C 编辑、010D 趋势 / 证据 / 运维、010E 设置 / AI / 权限、010F 残余状态与卡片编辑、010G 跨页无障碍 / 深色 / 动效、010H 最终审查与交接顺序完成。每个阶段均在前一阶段 PASS 后推进；没有一次性跨越业务边界改写全 App。

## 8. 当前状态

010A～010H 已全部 PASS。当前没有必须继续的 Coder 动作；可选的真机验证、checkpoint 或 release 只在用户明确授权后执行。见 [最终实施交接](UI-REDESIGN-IMPLEMENTATION-HANDOFF-20260716.md) 与仓库根目录 `NEXT_TASK.md`。
