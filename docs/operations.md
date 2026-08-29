# FlowMaster 安装与运维指南

本文档集中说明生产安装、升级、安全配置、vnstat 数据保护和故障恢复。快速使用请先阅读根目录 [README](../README.md)。

## 部署模型与路径

一键安装器使用 systemd，而不是全局 PM2。

| 项目 | 默认位置 |
| --- | --- |
| 程序目录 | `/opt/flowmaster` |
| 运行配置 | `/opt/flowmaster/.env` |
| systemd unit | `/etc/systemd/system/flowmaster.service` |
| 管理命令 | `/usr/local/bin/flowmaster` |
| 安装器回滚与归档 | `/var/backups/flowmaster` |
| vnstat 数据 | `/var/lib/vnstat` |
| vnstat 备份 | `/var/backups/flowmaster/vnstat` |

`/var/lib/vnstat` 属于系统 vnstat。FlowMaster 的安装、更新和卸载不得删除或重置它。

## 安装和升级

### 官方地址

```bash
curl -fL --retry 3 --connect-timeout 10 --max-time 120 -o install.sh \
  https://raw.githubusercontent.com/vbskycn/FlowMaster/main/install.sh
chmod +x install.sh
sudo ./install.sh
```

安装器会：

1. 获取互斥锁并检查进程健康。
2. 安装缺失依赖，验证 Node.js 18+、systemd 和 vnstat。
3. 下载源码到隔离暂存目录，并执行 `npm ci --omit=dev` 和语法检查。
4. 在独立进程组内运行有硬超时的临时服务冒烟测试。
5. 安全迁移旧 FlowMaster 进程，仅在检查通过后替换 `/opt/flowmaster`。
6. 创建或更新 `flowmaster.service`，并通过 `/api/version` 验证新版本。
7. 启动失败时尝试恢复刚刚归档的旧版本。

已有 `/opt/flowmaster/.env` 会复制到新版本。成功升级后，上一版本保存在 `/var/backups/flowmaster/rollback-时间戳`。

### 国内网络代理配置

外层 `curl` 只负责下载安装脚本。要尝试让安装器下载的源码归档也走代理，必须同时传入 `FLOWMASTER_DOWNLOAD_URL`：

```bash
curl -fL --retry 3 --connect-timeout 10 --max-time 120 -o install.sh \
  https://gh-proxy.com/https://raw.githubusercontent.com/vbskycn/FlowMaster/main/install.sh
chmod +x install.sh
sudo env \
  FLOWMASTER_DOWNLOAD_URL='https://gh-proxy.com/https://github.com/vbskycn/FlowMaster/archive/refs/heads/main.tar.gz' \
  ./install.sh
```

`gh-proxy.com` 是第三方 TLS 终点，项目无法保证其可用性或内容完整性。不要通过代理传输密码、Token 或私有仓库凭据；可以直连 GitHub 时优先使用官方地址。

### 固定版本与下载校验

`main` 是移动目标，适合获取最新版，不适合作为可复现部署依据。固定正式版本时，安装脚本和源码归档应使用同一个标签：

```bash
VERSION=vX.Y.Z  # 替换为准备安装的 Release 标签
curl -fL --retry 3 --connect-timeout 10 --max-time 120 -o install.sh \
  "https://raw.githubusercontent.com/vbskycn/FlowMaster/${VERSION}/install.sh"
chmod +x install.sh
sudo env FLOWMASTER_VERSION="${VERSION}" ./install.sh
```

如需让固定版本归档也走国内代理：

```bash
VERSION=vX.Y.Z  # 替换为准备安装的 Release 标签
curl -fL --retry 3 --connect-timeout 10 --max-time 120 -o install.sh \
  "https://gh-proxy.com/https://raw.githubusercontent.com/vbskycn/FlowMaster/${VERSION}/install.sh"
chmod +x install.sh
sudo env \
  FLOWMASTER_VERSION="${VERSION}" \
  FLOWMASTER_DOWNLOAD_URL="https://gh-proxy.com/https://github.com/vbskycn/FlowMaster/archive/refs/tags/${VERSION}.tar.gz" \
  ./install.sh
```

如果已经从独立可信渠道取得该归档的 SHA-256，可在执行上述安装器时额外传入 `FLOWMASTER_SHA256`：

```bash
sudo env \
  FLOWMASTER_VERSION="${VERSION}" \
  FLOWMASTER_DOWNLOAD_URL="https://github.com/vbskycn/FlowMaster/archive/refs/tags/${VERSION}.tar.gz" \
  FLOWMASTER_SHA256='请替换为可信的64位十六进制摘要' \
  ./install.sh
```

不要为 `main` 长期硬编码一个摘要；分支内容更新后摘要必然改变。
`FLOWMASTER_SHA256` 只校验安装器下载的源码归档，不校验已经执行的 `install.sh` 本身；经第三方代理获取安装脚本时，仍需从可信渠道另行核对脚本内容。

安装器常用覆盖变量：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `FLOWMASTER_VERSION` | `main` | `main` 或正式版本标签 |
| `FLOWMASTER_DOWNLOAD_URL` | 根据版本生成的 GitHub 归档地址 | 完整覆盖源码归档 URL |
| `FLOWMASTER_SHA256` | 空 | 非空时校验下载归档 |
| `FLOWMASTER_BACKUP_ROOT` | `/var/backups/flowmaster` | 安装、回滚和 PM2 恢复备份根目录 |

其余 `FLOWMASTER_*` 变量用于测试或受控故障恢复，不作为常规部署接口。

## 服务管理与验证

```bash
sudo flowmaster start
sudo flowmaster stop
sudo flowmaster restart
sudo flowmaster status
sudo flowmaster logs
```

非持续日志和健康检查：

```bash
sudo journalctl -u flowmaster.service -n 100 --no-pager
curl --fail http://127.0.0.1:10089/api/version
```

若 `HOST` 或 `PORT` 已修改，请使用实际监听地址。`HOST=0.0.0.0` 或 `HOST=::` 时，本机健康检查使用 `127.0.0.1`。

## 运行配置

首次创建：

```bash
sudo cp -n /opt/flowmaster/.env.example /opt/flowmaster/.env
sudo chmod 600 /opt/flowmaster/.env
sudo editor /opt/flowmaster/.env
sudo systemctl restart flowmaster.service
```

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `HOST` | `0.0.0.0` | 监听地址 |
| `PORT` | `10089` | 监听端口，必须为 1–65535 |
| `NODE_ENV` | `production` | Node.js 运行环境 |
| `CACHE_MAX_SIZE` | `100` | 缓存最大条目数 |
| `CACHE_MAX_MEMORY_MB` | `50` | 缓存估算内存上限 |
| `CACHE_CLEANUP_INTERVAL` | `60000` | 过期缓存清理间隔，毫秒 |
| `MEMORY_MONITOR_INTERVAL` | `300000` | 内存状态日志间隔，毫秒 |
| `VNSTAT_COMMAND_TIMEOUT_MS` | `15000` | 单次 vnstat 命令超时，毫秒 |
| `MAX_RANGE_DAYS` | `3660` | 日期范围查询最大天数 |
| `RATE_LIMIT_WINDOW_MS` | `60000` | API 限流窗口，毫秒 |
| `RATE_LIMIT_MAX` | `180` | 每客户端每窗口最大请求数 |
| `RATE_LIMIT_MAX_CLIENTS` | `10000` | 内存中最多保留的客户端限流桶 |
| `CORS_ORIGINS` | 空 | 允许的精确跨域来源，逗号分隔 |
| `ADMIN_TOKEN` | 空 | 管理接口令牌 |
| `TRUST_PROXY` | `false` | 仅在单层可信反向代理后设为 `true` |

数值配置如果不是正整数，服务会使用对应默认值。修改 `.env` 后必须重启服务。

## 公网安全

FlowMaster 默认监听所有接口，查询 API 和页面不带登录系统。公网部署至少应：

1. 仅由 HTTPS 反向代理访问 FlowMaster。
2. 用防火墙限制 `10089`，不要直接暴露给互联网。
3. 在反向代理层为整个站点配置认证或来源限制。
4. 设置高强度 `ADMIN_TOKEN`；管理请求使用 `X-Admin-Token`。
5. 只配置必要的 `CORS_ORIGINS`。
6. 仅在可信代理正确覆盖客户端地址时启用 `TRUST_PROXY=true`。

`CORS_ORIGINS` 是浏览器跨域策略，不是防火墙，也不阻止 curl 等非浏览器客户端。

## vnstat 备份与恢复

运行安装目录内的工具：

```bash
sudo bash /opt/flowmaster/backup_vnstat.sh
```

菜单提供：

1. 创建一致性备份。
2. 校验并恢复备份。
3. 列出备份。

备份流程会先暂停正在运行的 `flowmaster.service`，再暂停 vnstat 并复制数据目录；结束后按相反顺序恢复原本处于活动状态的服务。归档写入：

- `data/`：vnstat 数据文件。
- `checksums.sha256`：每个数据文件的校验和。
- `vnstat.json`：可读导出，失败时不会阻断文件备份。
- `metadata.txt`：时间、主机名和 vnstat 版本。
- 同名 `.sha256`：整个压缩归档的外部校验和。

恢复时始终校验内部文件；如存在同名 `.sha256`，还会校验整个外部归档。当前数据会先移动到 `/var/lib/vnstat.rollback-时间戳`。恢复后执行 vnstat 可用性检查，失败则尝试回滚。

备份工具覆盖变量：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `FLOWMASTER_BACKUP_DIR` | `/var/backups/flowmaster/vnstat` | 备份归档目录 |
| `VNSTAT_DATA_DIR` | `/var/lib/vnstat` | vnstat 数据目录 |
| `FLOWMASTER_BACKUP_LOG` | `/var/log/flowmaster-vnstat-backup.log` | 备份与恢复审计日志 |

不要把 `VNSTAT_DATA_DIR` 指向宽泛目录。脚本会拒绝 `/`、`/var`、`/var/lib`、`/tmp`、`/opt`、`/root` 和 `/home` 等危险目标。

## 卸载

重新运行安装脚本，选择“卸载 FlowMaster”。卸载会：

- 停止并禁用 `flowmaster.service`。
- 移除 `/usr/local/bin/flowmaster`。
- 将 `/opt/flowmaster` 移到 `/var/backups/flowmaster/uninstalled-时间戳`。
- 保留 `/var/lib/vnstat`。

需要永久清理归档或 vnstat 数据时，应先创建和验证备份，再单独确认精确目录；卸载器不会代替用户执行这类不可恢复操作。

## PM2 迁移与僵尸进程处理

旧版 FlowMaster 使用全局 PM2。PM2 5.x 的 TreeKill 路径在异常 daemon 上可能反复执行 `ps`，造成高 CPU 和大量僵尸进程。当前安装器不会在线调用 `pm2 delete`、`pm2 stop`、`pm2 save` 或 `pm2 kill` 来迁移 FlowMaster。

只有满足以下安全边界时，安装器才提供原地恢复：

- daemon 属于 root，并由独立的 `pm2-*.service` 管理。
- daemon PID、启动时间、systemd 主进程和 cgroup 一致。
- PM2 CLI 与 unit 使用同一安装。
- `dump.pm2` 以及存在时的 `dump.pm2.bak` 是可信、可解析的普通文件。
- 能精确列出恢复后应保留的其他已保存应用及状态。

确认流程：

1. 重新运行最新版安装器。
2. 阅读安装器列出的其他 PM2 应用和状态。
3. 只有列表正确时输入完整的 `RECOVER-PM2`。
4. 等待安装器有界停止 unit、离线从主备清单移除精确名称 `flowmaster`。
5. 若仍有其他保存应用，安装器恢复并验证它们；若清单只有 FlowMaster，PM2 unit 保持停止。
6. FlowMaster 最后由 `flowmaster.service` 接管。

恢复前快照位于 `/var/backups/flowmaster/pm2-recovery-*`。流程不需要重启主机，但 PM2 中列出的其他已保存应用会短暂停止。未执行 `pm2 save` 的应用无法从无响应 daemon 中可靠导出。

如果安装器拒绝恢复，不要放宽校验或直接 `kill -9`。先保存完整输出，并检查 unit、cgroup、PM2_HOME 和清单归属；拒绝意味着安装器无法证明不会影响其他应用。

## 回滚

新版本在部署前通过临时冒烟测试，替换后还会检查 systemd 状态和 `/api/version`。该检查失败时安装器自动尝试恢复刚归档的旧程序。

成功升级后如需人工回滚：

1. 先记录当前版本、`.env`、服务状态和目标 `rollback-*` 目录。
2. 确认目标目录包含 `package.json`、`server.js`、`package-lock.json` 和完整 `node_modules`。
3. 停止 `flowmaster.service`。
4. 将当前 `/opt/flowmaster` 移到新的、明确命名的保留目录，不要删除。
5. 将已核对的回滚目录移动回 `/opt/flowmaster`。
6. 启动服务，并核对 `/api/version`、页面、日志和 vnstat 数据。

人工回滚会改变正在运行的服务，目录选择错误也可能覆盖配置。不要使用通配符或“最新目录”自动选择；逐项核对精确绝对路径后再操作。

## 故障排查

### 服务状态

```bash
sudo systemctl status flowmaster.service --no-pager
sudo journalctl -u flowmaster.service -n 100 --no-pager
sudo systemctl status vnstat --no-pager
```

### 健康与版本

```bash
curl --fail http://127.0.0.1:10089/api/version
curl --fail http://127.0.0.1:10089/api/system/status
```

### 网络接口

```bash
ip route show default
vnstat --iflist
vnstat -i eth0 --oneline
```

将 `eth0` 替换为实际接口。不要把接口名拼接到 Shell 命令或脚本中；FlowMaster 本身使用参数数组执行 vnstat。

### 端口

```bash
sudo ss -ltnp | grep ':10089'
```

### 配置未生效

确认编辑的是 `/opt/flowmaster/.env`，然后执行：

```bash
sudo systemctl restart flowmaster.service
sudo systemctl show flowmaster.service -p MainPID -p ActiveState -p SubState
```

不要期望当前终端的 `export` 自动进入 systemd 服务。
