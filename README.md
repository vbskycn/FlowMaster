# FlowMaster

[![Latest Release](https://img.shields.io/github/v/release/vbskycn/FlowMaster)](https://github.com/vbskycn/FlowMaster/releases/latest)
[![License](https://img.shields.io/github/license/vbskycn/FlowMaster)](LICENSE)
[![Node.js](https://img.shields.io/badge/Node.js-18%2B-339933?logo=node.js&logoColor=white)](https://nodejs.org/)

FlowMaster 是一个面向 Linux 服务器的轻量级网络流量监控面板。它通过系统 `vnstat` 读取历史与实时流量，由 Node.js/Express 提供 Web 页面和 API，并使用 systemd 管理生产服务。

![FlowMaster 界面](assets/FlowMaster.jpg)

## 功能概览

- 自动发现并验证 vnstat 已记录的网络接口。
- 展示实时、5 分钟粒度、小时、日、月和年流量统计。
- 支持自定义日期范围查询和多网卡切换。
- 提供响应式页面、深浅主题、图表与数据表格。
- 使用有容量和内存上限的进程内 LRU 缓存。
- 提供版本、缓存、进程内存、系统状态和 vnstat 诊断 API。
- 安装、更新和卸载均保留 `/var/lib/vnstat` 历史数据。

## 系统要求

- 使用 systemd 的 Linux 发行版；Debian 是当前真实验证环境。
- Node.js 18 或更高版本，以及与该版本兼容的 npm。
- vnstat 2.x。
- root 权限，用于安装依赖和创建 systemd 服务。
- 默认监听 TCP `10089`；安装前请确认端口可用。

安装器支持 `apt-get`、`dnf` 或 `yum`，并会补装缺失的基础依赖。若发行版仓库中的 Node.js 低于 18，请先通过发行版或 Node.js 官方渠道升级。

## 安装与升级

首次安装和后续升级使用同一个脚本。已有安装会在菜单中显示“安全更新/重新部署 FlowMaster”。

### GitHub 直连

```bash
curl -fL --retry 3 --connect-timeout 10 --max-time 120 -o install.sh \
  https://raw.githubusercontent.com/vbskycn/FlowMaster/main/install.sh
chmod +x install.sh
sudo ./install.sh
```

### 国内网络

下面的命令尝试让安装脚本和源码归档都通过代理下载；只给第一条 `curl` 加代理并不能加速安装器后续的源码下载。

```bash
curl -fL --retry 3 --connect-timeout 10 --max-time 120 -o install.sh \
  https://gh-proxy.com/https://raw.githubusercontent.com/vbskycn/FlowMaster/main/install.sh
chmod +x install.sh
sudo env \
  FLOWMASTER_DOWNLOAD_URL='https://gh-proxy.com/https://github.com/vbskycn/FlowMaster/archive/refs/heads/main.tar.gz' \
  ./install.sh
```

`gh-proxy.com` 是第三方服务，其可用性和返回内容不由本项目控制。能直连 GitHub 时优先使用官方地址；对可复现部署要求较高时，请固定 Release 标签并从可信渠道核对 SHA-256，参见[安装与运维指南](docs/operations.md#固定版本与下载校验)。

安装器会在替换旧版本前执行锁文件安装、语法检查和临时服务冒烟测试。新服务启动验证失败时会尝试自动回滚，成功更新后的旧程序保存在 `/var/backups/flowmaster/rollback-*`。

> 从旧 PM2 部署迁移时，如果安装器检测到可信且仍包含 FlowMaster 的 PM2 systemd 服务，无论它当前健康还是无响应，都会列出受影响的已保存应用并要求输入 `RECOVER-PM2`。请先核对列表，不要自行执行 `pm2 delete`、`pm2 kill` 或直接杀死 PM2 守护进程。详细流程见[PM2 迁移与僵尸进程处理](docs/operations.md#pm2-迁移与僵尸进程处理)。

## 访问与服务管理

安装完成后访问：

```text
http://服务器IP:10089
```

常用命令：

```bash
sudo flowmaster start
sudo flowmaster stop
sudo flowmaster restart
sudo flowmaster status
sudo flowmaster logs
```

也可以直接使用 systemd：

```bash
sudo systemctl status flowmaster.service --no-pager
sudo journalctl -u flowmaster.service -f
```

公网部署时应使用 HTTPS 反向代理、限制 `10089` 的访问来源，并设置 `ADMIN_TOKEN`。该令牌只保护管理接口，不会为整个面板增加登录认证；如需限制全部页面和查询 API，请同时在反向代理层配置访问控制。

## 配置

生产安装目录是 `/opt/flowmaster`。首次创建配置文件时：

```bash
sudo cp -n /opt/flowmaster/.env.example /opt/flowmaster/.env
sudo chmod 600 /opt/flowmaster/.env
sudo editor /opt/flowmaster/.env
sudo systemctl restart flowmaster.service
```

更新时安装器会保留已有 `.env`。不要用当前 Shell 的 `export` 代替配置文件；systemd 服务不会继承该终端环境。

常用安全项：

```dotenv
ADMIN_TOKEN=请替换为高强度随机值
CORS_ORIGINS=https://monitor.example.com
TRUST_PROXY=false
```

只有 FlowMaster 确实位于可信反向代理之后时才能启用 `TRUST_PROXY`。全部配置项、默认值和边界见[安装与运维指南](docs/operations.md#运行配置)。

## vnstat 数据、备份与卸载

FlowMaster 不拥有 vnstat 数据库。安装、更新和卸载不会删除 `/var/lib/vnstat`。

安装后可运行交互式备份恢复工具：

```bash
sudo bash /opt/flowmaster/backup_vnstat.sh
```

默认备份目录是 `/var/backups/flowmaster/vnstat`。归档包含外部 SHA-256、内部文件校验和、vnstat JSON 导出和环境元数据；恢复前会再次校验，并将当前数据库保留为带时间戳的回滚目录。

卸载时重新运行安装脚本并选择“卸载 FlowMaster”。程序文件会归档到 `/var/backups/flowmaster/uninstalled-*`，vnstat 数据保持不变。

完整的备份、恢复和回滚边界见[安装与运维指南](docs/operations.md#vnstat-备份与恢复)。

## API

常用端点：

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| GET | `/api/interfaces` | 获取可用网络接口 |
| GET | `/api/stats/:interface/:period` | 获取指定周期统计 |
| GET | `/api/stats/:interface/range/:startDate/:endDate` | 获取日期范围统计 |
| GET | `/api/version` | 获取产品版本 |
| GET | `/api/system/status` | 获取运行状态 |
| POST | `/api/cache/clear` | 清空缓存，管理接口 |
| GET | `/api/test/vnstat` | 执行 vnstat 诊断，管理接口 |

`period` 支持 `l`、`5`、`h`、`d`、`m`、`y`。管理接口在配置 `ADMIN_TOKEN` 后要求请求头 `X-Admin-Token`。

请求、响应、鉴权和状态码说明见 [API 文档](docs/api.md)。

## 常见问题

### 服务无法启动

```bash
sudo flowmaster status
sudo journalctl -u flowmaster.service -n 100 --no-pager
curl --fail http://127.0.0.1:10089/api/version
```

如果修改过 `PORT` 或 `HOST`，请按 `/opt/flowmaster/.env` 中的实际值检查。

### vnstat 没有数据

```bash
sudo systemctl status vnstat --no-pager
vnstat --iflist
ip route show default
```

新接口需要先由 vnstat 建库和采样；刚添加后可能需要等待一个采样周期。

### 端口被占用

```bash
sudo ss -ltnp | grep ':10089'
```

确认占用进程后再决定是释放端口，还是修改 `/opt/flowmaster/.env` 中的 `PORT` 并重启服务。

### PM2 高 CPU 并出现大量 `ps` 僵尸

不要反复调用 PM2 命令。下载最新版安装脚本并重新执行；无论旧 PM2 当前健康还是无响应，安装器都只会在确认 PM2 守护进程、独立 systemd 服务、cgroup 和保存清单均可信后提供 `RECOVER-PM2` 迁移。恢复备份位于 `/var/backups/flowmaster/pm2-recovery-*`。

更多诊断步骤见[安装与运维指南](docs/operations.md#故障排查)。

## 开发

```bash
npm ci
npm run test:ci
```

源码调试、Linux 测试、提交规范和完整发布前检查见 [CONTRIBUTING.md](CONTRIBUTING.md)。项目版本以 [package.json](package.json) 的 `version` 为唯一来源，正式变化记录在 [CHANGELOG.md](CHANGELOG.md)。

## 获取帮助

- 问题反馈：[GitHub Issues](https://github.com/vbskycn/FlowMaster/issues)
- 版本发布：[GitHub Releases](https://github.com/vbskycn/FlowMaster/releases)
- 开源协议：[MIT](LICENSE)

如果 FlowMaster 对你有帮助，也可以支持项目：

![支持项目](assets/dsm.jpg)
