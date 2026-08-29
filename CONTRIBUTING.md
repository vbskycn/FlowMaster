# 参与 FlowMaster 开发

感谢参与 FlowMaster。提交改动前，请先阅读 [AGENTS.md](AGENTS.md) 中的项目边界和数据安全要求。

## 开发环境

- Node.js 18 或更高版本。
- 使用仓库中的 `package-lock.json` 和 `npm ci`。
- Linux/vnstat 行为需要在真实 Linux 环境验证。
- Shell 回归测试需要 Bash；`test/install-linux.test.sh` 使用隔离模拟，不要求 systemd。
- PM2 故障注入测试需要真实 Debian/systemd 环境和 root。

安装依赖并启动开发服务：

```bash
npm ci
npm run dev
```

默认访问 `http://127.0.0.1:10089`。如需覆盖配置，可复制示例文件：

```bash
cp .env.example .env
npm run dev
```

不要提交包含真实令牌、内网地址或生产配置的 `.env`。

## 代码与兼容性

- 保持现有 `/api` 响应兼容；统计结构变化应提供兼容字段和回归测试。
- vnstat 命令必须通过 `execFile` 和参数数组执行，不得拼接 Shell 命令。
- 安装、升级、卸载和测试不得删除 `/var/lib/vnstat`。
- 注释使用中文，重点解释业务原因、边界条件和不直观的取舍。
- 修改应聚焦、可审查、可回滚，不做无关的全仓格式化。
- 不为小问题引入体积大或维护状态不明的依赖。

## 测试

快速检查：

```bash
npm run test:ci
npm audit --audit-level=high
```

Linux Shell 与安装器回归：

```bash
bash -n install.sh
bash -n backup_vnstat.sh
bash -n test/backup-vnstat-lifecycle.test.sh
bash -n test/install-linux.test.sh
bash -n test/pm2-recovery-systemd.test.sh
bash test/backup-vnstat-lifecycle.test.sh
bash test/install-linux.test.sh
```

如果修改 PM2 恢复流程，还必须在真实 Debian/systemd 环境以 root 运行：

```bash
sudo bash test/pm2-recovery-systemd.test.sh
```

该测试会安装隔离的 PM2 5.4.3 测试依赖并创建临时 unit。不得把它指向生产 `PM2_HOME`。

修改 vnstat 解析、日期过滤、单位换算、缓存或接口参数时，必须增加对应回归测试。静态检查不能替代真实 vnstat 命令、API 冒烟或 systemd 行为验证。

## 提交

建议使用清晰的单一目的提交：

- `feat:` 新功能
- `fix:` 修复
- `docs:` 文档
- `refactor:` 重构
- `test:` 测试
- `chore:` 工程维护
- `release: flowmaster v<version>` 正式发布

提交前确认：

1. 相关测试和完整检查已通过。
2. 文档、配置示例和测试与代码同步。
3. 没有提交 `.env`、凭据、临时文件、依赖目录或测试数据。
4. `git diff --check` 无空白错误。
5. `git status` 中没有无关改动。

普通开发阶段不要提前修改版本号。正式发布时以 `package.json` 的 `version` 为唯一版本来源，并同步更新 [CHANGELOG.md](CHANGELOG.md)、标签和 GitHub Release。

## 问题反馈

请通过 [GitHub Issues](https://github.com/vbskycn/FlowMaster/issues) 提交问题，并附上：

- FlowMaster 版本。
- Linux 发行版、Node.js 和 vnstat 版本。
- 相关请求路径或复现步骤。
- `systemctl status` 和 `journalctl` 中经过脱敏的必要片段。

不要公开 `ADMIN_TOKEN`、私钥、密码、完整 `.env` 或其他凭据。
