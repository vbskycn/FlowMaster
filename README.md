# FlowMaster

[![Latest Release](https://img.shields.io/github/v/release/vbskycn/FlowMaster)](https://github.com/vbskycn/FlowMaster/releases/latest)
[![Docker Pulls](https://img.shields.io/docker/pulls/zhoujie218/flowmaster)](https://hub.docker.com/r/zhoujie218/flowmaster)
[![License](https://img.shields.io/github/license/vbskycn/FlowMaster)](LICENSE)

FlowMaster 是一个面向 Linux 服务器与 VPS 的**超轻量级网络流量实时监控与管理面板**。`v2.0` 采用 **Go 静态单二进制 + 内置 SQLite + 现代化响应式 Web 界面** 全新重构，零 Node.js 运行时依赖，常驻内存仅约 **12 ~ 18 MB**，原生提供 **`linux/amd64` 与 `linux/arm64` 多架构 Docker 镜像** 及智能一键安装更新脚本。

![FlowMaster 界面](assets/FlowMaster.jpg)

## 核心特性

- **极致轻量高效**：单个静态二进制内嵌全部前端资源，直接读取 Linux 内核 `/proc/net/dev` 实现 1 秒级低开销实时吞吐与包速率推送（SSE），空闲 CPU 接近 `0%`。
- **混合流量引擎（SQLite + vnstat 双兼容）**：
  - **独立自采**：默认无需安装 `vnstat`，开箱即记录 5 分钟、小时、日、月、年及自定义日期区间流量；
  - **平滑兼容老环境**：支持 `Hybrid 智能融合` 或 `vnstat 直读` 模式，可在后台**一键将宿主机原有 `vnstat` 历史账本幂等导入内置数据库**（对 `/var/lib/vnstat` 纯只读，绝不修改或删除）。
- **VPS 月度流量包与超额告警**：支持自定义每月账单重置日（1–31 号）、4 种计费模式（双向 `RX+TX` / 仅上行 `TX` / 仅下行 `RX` / 单向取大 `max(RX,TX)`）、额度预警进度条、月底用量预测，以及 Webhook / Telegram 超额告警推送。
- **现代化看板与可视化管理后台**：
  - 明暗主题自适应、移动端与桌面响应式布局、`Mbps` / `MiB/s` 单位切换；
  - 默认自动过滤隐藏 `docker*` / `veth*` / `br-*` 等虚拟接口，支持自定义网卡备注别名与显隐管理；
  - 增强型数据表（序号列、`20 / 50 / 100` 分页切换、多列排序与关键词搜索）及双通道倒序脱敏日志查看器；
  - 前台默认免密查看，支持后台一键开启“全站密码保护”。
- **在线备份与还原闭环**：后台一键创建 SQLite 一致性快照、一键下载到本地、从快照列表还原或上传本地 `.tar.gz` 备份一键还原（自动校验 `PRAGMA integrity_check`、还原前自动留存保护快照、失败自动回滚）。

---

## 一键安装与更新脚本（自动识别国内网络加速）

`install.sh` 同时支持 **Docker 容器部署** 与 **宿主机静态二进制（systemd）部署**，内置**中国大陆网络自动检测与多节点 GitHub 加速代理 / 镜像源自动回退机制**，避免因连接超时或单点代理失效导致安装出错。

### 1. 下载脚本并打开交互式菜单

以下命令在直连受阻时会自动切换国内代理拉取脚本：

```bash
curl -fsSL --connect-timeout 5 https://raw.githubusercontent.com/vbskycn/FlowMaster/main/install.sh -o install.sh || \
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/vbskycn/FlowMaster/main/install.sh -o install.sh
chmod +x install.sh
sudo ./install.sh
```

### 2. 非交互式一键命令（部署最新版 / 平滑更新版本）

下载 `install.sh` 后，也可直接传入子命令完成部署或升级：

```bash
# 方式 A：使用 Docker 一键部署或平滑更新到最新版本（推荐）
sudo ./install.sh docker

# 方式 B：使用单文件二进制 + systemd 一键部署或平滑更新到最新版本（无需安装 Docker）
sudo ./install.sh binary

# 智能一键更新：自动识别当前已安装的是 Docker 还是二进制模式，平滑升级至最新版本（异常自动回滚）
sudo ./install.sh update

# 查看当前运行状态与版本
sudo ./install.sh status

# 卸载运行实例（完整保留历史流量数据库与 /var/lib/vnstat）
sudo ./install.sh uninstall
```

> **国内网络与高级参数说明**：
> - 脚本运行时会自动检测网络连通性；若识别为国内受限环境，会自动测速选择可正常校验响应内容的 GitHub 加速节点并支持多源 Docker 镜像拉取回退。
> - 如需手动强制开启/关闭国内加速或指定私有代理，可附加环境变量：
>   ```bash
>   sudo FLOWMASTER_CN=1 ./install.sh docker
>   sudo FLOWMASTER_GH_PROXY='https://你的代理域名/' ./install.sh binary
>   sudo FLOWMASTER_PORT=10089 FLOWMASTER_VERSION=v2.0.0 ./install.sh binary
>   ```

---

## 手动 Docker 部署与升级

官方同步发布 `linux/amd64` 与 `linux/arm64` 多架构镜像：
- **Docker Hub**：`zhoujie218/flowmaster:2.0.0`（及 `zhoujie218/flowmaster:latest`）
- **GitHub Container Registry**：`ghcr.io/vbskycn/flowmaster:2.0.0`（及 `ghcr.io/vbskycn/flowmaster:latest`）

### 方式一：`docker run` 部署

监控宿主机真实物理网卡需开启 `--network host`，并将 `/data` 挂载到明确的宿主机目录：

```bash
mkdir -p /opt/flowmaster/data

docker run -d \
  --name flowmaster \
  --restart unless-stopped \
  --network host \
  -e TZ=Asia/Shanghai \
  -e PORT=10089 \
  -v /opt/flowmaster/data:/data \
  zhoujie218/flowmaster:2.0.0
```

> **可选挂载宿主机 `vnstat`**：若服务器上原本已有系统 `vnstat` 历史数据，可额外添加 `-v /var/lib/vnstat:/var/lib/vnstat:ro -e VNSTAT_DB_DIR=/var/lib/vnstat`，启动后即可在后台融合查看或一键合并导入。

### 方式二：`docker compose` 部署

下载仓库中的 [compose.yaml](compose.yaml) 后启动：

```bash
docker compose up -d
```

启动后访问 `http://服务器IP:10089`，点击右上角 **「管理登录」** 即可完成首次管理员密码设置（也可通过 `-e ADMIN_PASSWORD='你的强密码'` 预先指定）。

### 手动升级与回滚

1. **升级前备份**：建议先在「管理后台 → 备份与还原」创建并下载一份备份快照到本地。
2. **更新版本**：可直接执行 `sudo ./install.sh update`，或手动拉取新版本镜像重建容器：
   ```bash
   docker pull zhoujie218/flowmaster:2.0.0
   docker compose up -d
   ```
3. **验证与回滚**：访问 `http://127.0.0.1:10089/api/version` 核对版本；如需回滚，将镜像标签改回旧版本重建容器即可。

---

## 数据持久化与目录说明

| 部署方式 | 配置与数据路径 | 说明 |
| :--- | :--- | :--- |
| **Docker 部署** | `/opt/flowmaster/data`（挂载至容器 `/data`） | 包含 `flowmaster.db`、`session.key`、`backups/` 快照与 `logs/` 轮转日志 |
| **二进制部署** | 配置：`/etc/flowmaster/flowmaster.env`<br>数据：`/var/lib/flowmaster` | 以专用无登录 `flowmaster` 系统账号运行，可通过 `flowmaster-ctl {start\|stop\|restart\|status\|logs\|version}` 管理 |

---

## 常用环境变量

完整配置项见 [.env.example](.env.example)，反向代理与安全运维细节见 [安装、安全与运维指南](docs/operations.md)：

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
- Docker 镜像：[Docker Hub (`zhoujie218/flowmaster`)](https://hub.docker.com/r/zhoujie218/flowmaster)
- 开源协议：[MIT](LICENSE)

如果 FlowMaster 对你有帮助，欢迎支持项目：

![支持项目](assets/dsm.jpg)
