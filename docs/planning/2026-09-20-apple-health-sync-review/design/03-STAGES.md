# 阶段计划与依赖

截至 2026-09-20，S01–S12 已完成 Planner 软件验收，其中 S10B 因未签名测试宿主 Keychain `-34018` 保持 PENDING；S13 已完成软件回归，等待真机与同一 Keychain 环境门。普通 Coder 阶段上限为3个production文件+1个聚焦测试文件；高风险阶段的同样文件预算不代表可路由本地。

| 阶段 | 目标 | 前置 | 执行边界 | 当前状态 |
|---|---|---|---|---|
| [S01](prompts/S01.md) | 首屏移除无用 raw 全表读取 | 预检 | LOW_MEDIUM | PASS |
| [S02](prompts/S02.md) | 首屏阶段计时 | S01 | LOW_MEDIUM | PASS |
| [S03](prompts/S03.md) | 纯请求合并与公平调度状态 | S02 | LOW_MEDIUM | PASS |
| [S04A](prompts/S04A.md) | HealthKit错误分类 | S03 | LOW_MEDIUM | PASS |
| [S04B](prompts/S04B.md) | 可取消且有deadline的HK查询 | S04A | PLANNER_OWNED | PASS |
| [S05](prompts/S05.md) | durable work和原子页提交 | S03, S04A | PLANNER_OWNED | PASS |
| [S06](prompts/S06.md) | 分页增量执行器 | S04B, S05 | PLANNER_OWNED | PASS |
| [S07](prompts/S07.md) | 唯一runner接入现有SyncEngine | S06 | PLANNER_OWNED | PASS |
| [S08A](prompts/S08A.md) | 启动与授权就绪补触发 | S07 | PLANNER_OWNED | PASS |
| [S08B](prompts/S08B.md) | Observer与后台机会适配 | S08A | PLANNER_OWNED | PASS |
| [S09](prompts/S09.md) | 按受影响日期投影 | S07, S05 | PLANNER_OWNED | PASS |
| [S10](prompts/S10.md) | 手动两次同步最终状态 | S07, S09 | LOW_MEDIUM_AFTER_SEAM_REVIEW | PASS |
| [S10B](prompts/S10B.md) | 备份恢复与新同步互锁 | S09, S08A | PLANNER_OWNED | PENDING |
| [S11A](prompts/S11A.md) | Bridge payload读取与维护有界化 | S09 | PLANNER_OWNED | PASS |
| [S11B](prompts/S11B.md) | 首轮本地加载后再安排维护 | S02, S08A, S10, S11A, S10B | LOW_MEDIUM_AFTER_SEAM_REVIEW | PASS |
| [S12](prompts/S12.md) | 真实阶段状态与显示 | S09, S10, S08B | LOW_MEDIUM_AFTER_SEAM_REVIEW | PASS |
| [S13](prompts/S13.md) | 软件回归与真实设备验收 | S01, S02, S03, S04A, S04B, S05, S06, S07, S08A, S08B, S09, S10, S10B, S11A, S11B, S12 | PLANNER_ACCEPTANCE | PENDING |

## 路由含义

- LOW_MEDIUM：普通窄阶段；本地EVO仍须通过完整输入信任门，或由用户手动选择的云端便宜Coder按同样边界实施。
- LOW_MEDIUM_AFTER_SEAM_REVIEW：依赖外部/恢复接口已经固定并经过Planner独立审查，之后才是普通实现。
- PLANNER_OWNED：取消竞态、恢复、事务或跨系统合同，按当前全局AGENTS由Planner主导；不能因想省成本改为未经审查的本地Coder任务。
- PLANNER_ACCEPTANCE：独立软件/真机验收，不是生产实现派单。

## 依赖与并发

推荐执行顺序按上表串行。可独立的纯模块不意味着授权在同一dirty工作区开多个Agent；本包不自动委派。S05/S04B等关键接口通过后，S06–S09才有真实接线基础。S10B是备份恢复保护门，不能在最终验收中省略。

每阶段需完成对应prompt的全部验收及04矩阵条款，记录accepted文件哈希/真实签名。Planner发现>3production文件或同时涉及新schema与外部副作用的复杂实现时，再拆子阶段；不要为遵守数字把相邻模块塞进巨型文件。

## 审查记录模板

```json
{"stage":"S01","coder_state":"CODER_DONE_PENDING_REVIEW","review":"PENDING","accepted_baseline":null,"changed_paths":[],"tests":[],"unverified":[],"next_stage_activated":false}
```

正式review状态：PASS/FAIL/PENDING/BLOCKED。PENDING表示缺关键验证，BLOCKED表示缺权限/凭据/决定且无法继续；测试失败使用FAIL，不混为环境阻塞。S13真实设备通过前，整个重构保持IMPLEMENTATION_PENDING或ACCEPTANCE_PENDING。
