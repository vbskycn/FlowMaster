# FlowMaster

[![Latest Release](https://img.shields.io/github/v/release/vbskycn/FlowMaster)](https://github.com/vbskycn/FlowMaster/releases/latest)
[![License](https://img.shields.io/github/license/vbskycn/FlowMaster)](LICENSE)

FlowMaster 是一个面向 Linux 服务器与 VPS 的**超轻量级网络流量实时监控与管理面板**。它由 **Go 静态单二进制 + 内置 SQLite + 现代化响应式 Web 界面** 构建，无需在宿主机安装 Node.js 或任何运行时依赖，常驻内存仅约 **10 ~ 15 MB**，开箱支持 **Docker 一键运行** 与宿主机 `systemd` 极速部署。

![FlowMaster 界面](assets/FlowMaster.jpg)

## 核心特性

- **极致轻量高效**：单个静态二进制内嵌全部 Web 资源，直接读取 Linux 内核 `/proc/net/dev` 实现 1 秒级低开销实时吞吐与包速率推送（SSE），空闲 CPU 接近 `0%`。
- **混合流量引擎（SQLite + vnstat 双兼容）**：
  - **独立自采**：默认无需安装 `vnstat`，开箱即记录 5 分钟、小时、日、月、年及任意日期区间流量；
  - **平滑兼容老环境**：支持 `Hybrid 智能融合` 或 `vnstat 直读` 模式，并支持在后台**一键将系统原有 `vnstat` 历史账本无损合并导入内置数据库**（对 `/var/lib/vnstat` 纯只读，绝不修改或删除）。
- **VPS 月度流量包与超额告警**：支持自定义每月账单重置日（1–31 号）、灵活计费方向（双向 `RX+TX` / 仅上行 `TX` / 仅下行 `RX` / 单向取大 `max(RX,TX)`）、月度总额度进度条、月底用量预测，以及 Webhook / Telegram 超额告警推送。
- **现代化 Web 看板与可视化管理中心**：
  - 明暗主题自适应、手机与桌面响应式设计、`Mbps` / `MiB/s` 单位一键切换；
  - 网卡智能排序，默认折叠过滤 `docker*` / `veth*` / `br-*` 等虚拟接口，支持自定义网卡备注别名与显隐控制；
  - 增强型数据明细表（含序号列、`20 / 50 / 100` 分页切换、列排序与关键词搜索）；
  - 前台默认免密查看，亦可在后台一键开启“全站密码保护”；后台内置独立倒序系统与告警日志查看器。
- **内置可视化备份与还原闭环**：后台一键创建 SQLite 一致性快照、历史快照列表查看、一键下载到本地、从列表还原或上传本地 `.tar.gz` 备份一键还原（自动校验 `PRAGMA integrity_check`、还原前自动留存保护快照、异常自动回滚）。

---

## 快速开始（推荐 Docker 部署）

监控宿主机真实物理网卡需使用 `--network host` 模式，并将 `/data` 绑定挂载到明确的宿主机目录以持久化流量数据与配置。

### 方式一：`docker run` 一行启动

```bash
mkdir -p /opt/flowmaster/data

docker run -d \
  --name flowmaster \
  --restart unless-stopped \
  --network host \
  -e TZ=Asia/Shanghai \
  -e PORT=10089 \
  -v /opt/flowmaster/data:/data \
  ghcr.io/vbskycn/flowmaster:1.1.21
```

> **提示**：如果你的服务器此前已经运行了系统 `vnstat` 并希望融合查看或一键导入历史数据，可额外加上只读挂载 `-v /var/lib/vnstat:/var/lib/vnstat:ro`。

### 方式二：`docker compose` 部署

下载仓库中的 [compose.yaml](compose.yaml) 后启动：

```bash
docker compose up -d
```

启动后在浏览器访问：

```text
http://服务器IP:10089
```

首次点击右上角 **「管理登录」** 时，页面会引导你初始化管理员密码。你也可以通过环境变量 `-e ADMIN_PASSWORD='你的强密码'` 预先指定初始密码。

---

## 宿主机二进制一键安装（无需 Docker）

适用于未安装 Docker 的轻量小内存 VPS（支持 `x86_64` 与 `arm64`，自动配置受限 `flowmaster` 系统账号与 `systemd` 守护服务）：

```bash
curl -fL --retry 3 --connect-timeout 10 --max-time 120 -o install.sh \
  https://raw.githubusercontent.com/vbskycn/FlowMaster/main/install.sh
chmod +x install.sh
sudo ./install.sh install
```

常用服务管理命令：

```bash
sudo flowmaster-ctl status
sudo flowmaster-ctl restart
sudo flowmaster-ctl logs
sudo flowmaster-ctl version
```

默认路径说明：

| 项目 | 路径 |
| :--- | :--- |
| 可执行程序 | `/usr/local/bin/flowmaster` |
| 配置文件 | `/etc/flowmaster/flowmaster.env`（`0640`） |
| 持久化数据目录 | `/var/lib/flowmaster`（含 `flowmaster.db`、`backups/`、`logs/`） |
| 系统服务单元 | `/etc/systemd/system/flowmaster.service` |

---

## 数据持久化、备份与恢复

FlowMaster 的全部配置、历史流量与快照均保存在 `DATA_DIR`（Docker 内为 `/data`，systemd 部署为 `/var/lib/flowmaster`）：

1. **创建与下载备份**：进入「管理后台 → 备份与还原」，点击 **「一键创建备份快照」**，随后点击 **「下载到本地」** 即可将 `.tar.gz` 备份包离线保存。
2. **一键恢复数据**：支持在快照列表中直接点击 **「一键还原」**，或点击 **「上传本地备份还原 (.tar.gz)」** 上传备份包恢复。系统在切换前会自动校验 SHA-256 与 SQLite `PRAGMA integrity_check`，并自动创建一份 `pre-restore-*` 保护快照，确保现网数据万无一失。
3. **导入旧版 `vnstat` 数据**：若挂载或安装了系统 `vnstat`，可在「管理后台 → 概览与数据源」中点击 **「从系统 vnstat 幂等导入历史数据」**，多次执行也不会重复累加流量，且绝不修改原 `/var/lib/vnstat`。

---

## 升级与回滚

### Docker 部署升级与回滚

1. **升级前备份**：建议先在 Web 管理后台下载一份最新备份快照。
2. **拉取新版本并重建**：
   ```bash
   docker pull ghcr.io/vbskycn/flowmaster:<新版本号>
   # 更新 compose.yaml 或 docker run 中的镜像标签后重新启动
   docker compose up -d
   ```
3. **验证运行**：访问 `http://127.0.0.1:10089/api/version` 核对版本号与页面状态。
4. **快速回滚**：将镜像标签改回上一版本并执行 `docker compose up -d`；如需回退数据库，可在后台「备份与还原」中一键恢复升级前快照。

### systemd 部署升级与卸载

- **安全升级**：重新运行 `sudo ./install.sh install`，脚本会自动备份旧二进制并在健康检查失败时自动回退；若宿主机存在旧版 `/opt/flowmaster` Node.js 部署，脚本会自动迁移 `.env` 并将旧程序安全归档至 `/var/backups/flowmaster/`。
- **安全卸载**：运行 `sudo ./install.sh uninstall`，仅移除服务与二进制程序，完整保留 `/var/lib/flowmaster` 与系统 `/var/lib/vnstat`。

---

## 常用环境变量

完整配置示例见 [.env.example](.env.example)，运维与安全细节见 [安装与运维指南](docs/operations.md)：

| 变量 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `HOST` | `0.0.0.0` | HTTP 监听地址 |
| `PORT` | `10089` | HTTP 监听端口 |
| `DATA_DIR` | `./data`（容器内 `/data`） | SQLite 数据库、日志与备份持久化目录 |
| `REALTIME_INTERVAL_MS` | `1000` | 内核实时采样间隔（毫秒，`1000`–`60000`） |
| `ADMIN_PASSWORD` | 空 | 首次启动自动初始化的管理员密码（未设时由页面引导设置） |
| `ADMIN_TOKEN` | 空 | 可选 API 管理令牌（请求头 `X-Admin-Token`） |
| `TRUST_PROXY` | `false` | 位于可信 HTTPS 反向代理后方时设为 `true` |
| `CORS_ORIGINS` | 空 | 逗号分隔的精确跨域白名单 |

---

## 文档导航

- [系统架构说明](docs/architecture.md)
- [HTTP API 文档（含 v1 与旧版兼容端点）](docs/api.md)
- [安装、安全与运维指南](docs/operations.md)
- [开发与贡献指南](CONTRIBUTING.md)
- [版本更新记录](CHANGELOG.md)

## 获取帮助与支持

- 问题反馈：[GitHub Issues](https://github.com/vbskycn/FlowMaster/issues)
- 版本发布：[GitHub Releases](https://github.com/vbskycn/FlowMaster/releases)
- 开源协议：[MIT](LICENSE)

如果 FlowMaster 对你有帮助，欢迎支持项目：

![支持项目](assets/dsm.jpg)
