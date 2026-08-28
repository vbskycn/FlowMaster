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
- 提交前至少运行 `npm run test:ci`、`bash -n install.sh`、`bash -n backup_vnstat.sh` 和 `npm audit --audit-level=high`。
- 修改 vnstat 解析、日期过滤、单位换算、缓存或接口参数时必须补回归测试。
- Linux/vnstat 行为应在真实 Linux 环境验证；静态检查不能替代真实命令和 API 冒烟测试。

## 部署与安全

- 生产环境优先通过 HTTPS 反向代理访问，只配置必要的 `CORS_ORIGINS`。
- 公网部署应设置 `ADMIN_TOKEN`，并限制端口访问来源。
- vnstat 命令必须通过 `execFile` 参数数组执行，禁止重新引入 Shell 字符串拼接。
- 错误详情只进入服务端日志，对外返回稳定、非敏感的错误信息。
