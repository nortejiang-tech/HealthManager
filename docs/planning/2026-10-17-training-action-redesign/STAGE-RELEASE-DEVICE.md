# Release 真机部署阶段

状态：**PENDING**（安装 PASS，核心真实数据与趋势 PASS；全量真机参数入口 PENDING）。

目标：无线安装真正签名 Release，验证准备度、能力、趋势及全部运动参数入口；不加训练计划。

基线：main@0cfc55b；保留已有 v2 dirty worktree 和私人未跟踪文件。已完成无线配对、安装前备份及完整性检查、签名 Release 安装与回读、真实数据回算、全部 34 参数的副本 UI 验收，并修复参数行空白区域点击无效。修复包再次安装成功。

风险与回滚：点击修饰器为一行可回退变更；修复前源文件和原始安装包、两次安装前数据库备份留存在私有证据目录。未执行回退、数据库恢复、提交或推送。Mac 原 SSID 已恢复，IPv6 LinkLocal 保留用于无线开发；其他环境恢复项见验收报告。

剩余：33 个真机参数入口的逐项交互。三次实机 XCTest 均在业务启动前失败；镜像短暂恢复后再次 noWindowsAvailable。不得把副本的 34/34 计成真机 34/34。

最终证据以 [DEVICE-RELEASE-VALIDATION.md](DEVICE-RELEASE-VALIDATION.md) 和同名 JSON 为准。
