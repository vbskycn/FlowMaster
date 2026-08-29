# FlowMaster 协作规范

## 项目边界

- 本项目是基于 Node.js、Express 和系统 `vnstat` 的 Linux 网络流量监控服务。
- `package.json` 的 `version` 是产品版本唯一来源；开发阶段不要提前修改版本。
- 保持现有 `/api` 响应兼容；变更统计数据结构时应提供兼容字段和回归测试。

## 数据安全

- 安装、更新或卸载 FlowMaster 时不得删除 `/var/lib/vnstat`。
- 重置 vnstat 数据必须是独立、明确确认并先备份的操作。
- 恢复数据前必须校验备份，并保留可回滚的恢复前快照。
- Shell 中的递归删除只能作用于已经验证的精确临时目录或 FlowMaster 程序目录。

## 开发与测试

- Node.js 最低版本为 18，依赖使用已提交的 `package-lock.json` 和 `npm ci`。
- 提交前至少运行 `npm run test:ci`、`bash -n install.sh`、`bash -n backup_vnstat.sh`、`bash test/backup-vnstat-lifecycle.test.sh`、`bash test/install-linux.test.sh` 和 `npm audit --audit-level=high`。
- 修改 PM2 恢复流程时，还必须在真实 Debian/systemd 环境以 root 运行 `bash test/pm2-recovery-systemd.test.sh`；该测试会安装隔离的 PM2 5.4.3 测试依赖并创建临时 unit，不得指向生产 PM2_HOME。
- 修改 vnstat 解析、日期过滤、单位换算、缓存或接口参数时必须补回归测试。
- Linux/vnstat 行为应在真实 Linux 环境验证；静态检查不能替代真实命令和 API 冒烟测试。

## 部署与安全

- 一键部署使用 `flowmaster.service`，不得重新引入全局 PM2 作为默认进程管理器。
- 旧 PM2 迁移必须有超时且只能移除精确名为 `flowmaster` 的应用；禁止回退到在线 `pm2 delete`、`pm2 stop`、`pm2 save` 或 `pm2 kill`。
- PM2 恢复仅在明确确认并强校验独立 unit、cgroup 与主备保存清单后执行“有界停止 → 离线过滤 → 按需恢复其他应用”。如仍有其他保存应用，必须验证集合与状态不变；如只有 FlowMaster，PM2 unit 应保持停止。
- 冒烟测试的网络请求和临时进程关闭必须有硬超时，脚本退出时必须回收整个临时进程组。
- 生产环境优先通过 HTTPS 反向代理访问，只配置必要的 `CORS_ORIGINS`。
- 公网部署应设置 `ADMIN_TOKEN`，并限制端口访问来源。
- vnstat 命令必须通过 `execFile` 参数数组执行，禁止重新引入 Shell 字符串拼接。
- 错误详情只进入服务端日志，对外返回稳定、非敏感的错误信息。
