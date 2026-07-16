# STAGE-011：v0.4.0 全页面 UI 发布

> 日期：2026-07-16
>
> 状态：RELEASE READY
>
> 版本：v0.4.0（build 9）
>
> 用户授权：已明确授权发布并更新真实 iPhone

## 1. 唯一目标

把已通过 STAGE-010A～010H 的全页面 UI 改版，以同一 Bundle ID 和签名身份安全发布为 v0.4.0（build 9），完成真实 iPhone 覆盖安装、数据保持验证、Git 提交、annotated tag、push 与私有仓库 GitHub Release。

本阶段不新增产品功能，不修改 `Core/`、数据库 schema、迁移、HealthKit、同步、通知、营养 / 能量算法或持久化合同。

## 2. 发布内容

- 全页面“基线叙事 + 局部决策透镜”视觉改版及共享 `UI/DesignSystem/`。
- 深色模式、Dynamic Type、Reduce Motion、VoiceOver 描述与图表可读摘要。
- 最终人工反馈：趋势页把“来源 / 整理 / 展示”移至底部；饮食页移除重复的大型新增 / 复用按钮，保留右上角快捷入口。
- `MARKETING_VERSION` / `CFBundleShortVersionString` 提升为 `0.4.0`，build 提升为 `9`。

## 3. 验收门

| 门 | 状态 | 证据 |
|---|---|---|
| 最终人工反馈 Smoke | PASS | 1 / 1；`/tmp/healthmanager-v040-smoke-20260716-attempt01.xcresult` |
| 全量自动化 | PASS | 258 / 258，0 failed，0 skipped；`/tmp/healthmanager-v040-full-20260716-attempt01.xcresult` |
| Simulator Release 构建 | PASS | BUILD SUCCEEDED；`/tmp/healthmanager-v040-sim-release-build-20260716-attempt01.xcresult` |
| 真实 iPhone Release 构建 | PASS | BUILD SUCCEEDED；`/tmp/healthmanager-v040-device-release-build-20260716-attempt01.xcresult` |
| 签名与身份 | PASS | Bundle ID `com.norte.HealthManager`；Team `K8RVJSC4NU`；目标 UDID 已包含在 profile |
| 备份与安装前快照 | PASS | Finder backup finished、Manifest quick_check ok；1.4GB App 数据快照 |
| 真实 iPhone 覆盖安装与启动 | PASS | iPhone Air / iOS 26.5.2；安装后 `0.4.0 (9)`；launch pid 7284 |
| 安装后数据保持 | PASS | quick_check ok；迁移 v1～v5；餐次 119、分项 7、用药计划 1、用药日志 5、孤儿分项 0、活动同步任务 0 |
| Git 产品提交 | PENDING | 发布提交创建后回填 |
| annotated tag 与 push | PENDING | `v0.4.0` 创建并推送后回填 |
| GitHub Release | PENDING | 私有仓库 Release 创建后回填 |

原始样本由安装前 3,354,427 自然增加至安装后 3,354,444；其余关键业务计数保持一致。安装后数据快照位于 `/tmp/healthmanager-v040-postinstall-device-20260716-attempt02/HealthManager`。

## 4. 诚实边界

- 真机已验证覆盖安装、启动、版本与数据库保持；没有在真机重新执行完整 VoiceOver 流程、触觉评价、系统 HealthKit 权限逐类型面板或真实 API Key / 健康照片调用。
- 本版是私有仓库 GitHub Release 加开发者签名 App 的真实 iPhone 覆盖安装，不是公开 App Store 分发。
- `/tmp` 证据可能被系统清理，关键计数和结论已固化在本文件与 [v0.4.0 发布说明](../releases/v0.4.0.md)。

## 5. 剩余发布动作

1. 创建产品发布提交并记录 SHA。
2. 创建 annotated tag `v0.4.0`，push `main` 与 tag。
3. 使用 [v0.4.0 发布说明](../releases/v0.4.0.md) 创建 GitHub Release。
4. 重新启动手机上的 App，更新本文件为 `RELEASED`，并提交 / push 文档收尾。
