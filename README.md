# FlowMaster

[![Latest Release](https://img.shields.io/github/v/release/vbskycn/FlowMaster)](https://github.com/vbskycn/FlowMaster/releases/latest)
[![Docs](https://img.shields.io/badge/Docs-FlowMaster%20官方文档-2563eb)](https://flowmaster-docs.168668518.com/)
[![Docker Pulls](https://img.shields.io/docker/pulls/zhoujie218/flowmaster)](https://hub.docker.com/r/zhoujie218/flowmaster)
[![License](https://img.shields.io/github/license/vbskycn/FlowMaster)](LICENSE)

FlowMaster 是一个面向 Linux 服务器与多 VPS 集群的**超轻量级网络流量实时监控与统一管理中枢**。采用 **Go 静态单二进制 + 内置 SQLite + 现代化响应式 Web 界面** 构建，零 Node.js 运行时依赖，单机常驻内存仅约 **12 ~ 18 MB**，原生支持 **IPv4 / IPv6 双栈**、**自动放行宿主机防火墙**、**一主多从几十台机器集中对比查看**及**后台一键远程升级**。

## 核心特性

- **一主多从统一管理（支持几十上百台 VPS 集中管控）**：
  - **同体合一**：同一个二进制/镜像既可独立单机使用，也可作为**主控中心（Hub）**或**被控节点（Agent）**；
  - **默认主控分发多架构安装包（免连 GitHub）**：主控启动后自动在本地保留 `linux/amd64` 与 `linux/arm64` 双架构静态二进制包，页面点击「+ 添加服务器节点」**默认由主控机直接下发安装脚本与二进制包**，不同架构的国内机器均无需访问 GitHub 或第三方公共代理即可秒速安装上线；
  - **多机总览对比与下钻详情**：一屏掌握所有机器在线状态、实时总带宽、今日/本月流量及横向排行对比图；点击任意机器即可像看本机一样查看其秒级波形、5m/h/d/m/y/区间明细，并可远程调整月度配额；
  - **统一远程自升级**：主控后台支持勾选单台或全部二进制节点一键远程升级（优先从主控分发源拉取新包，自动核验 `SHA256SUMS` 并平滑重启）。
- **极致轻量 + 混合流量引擎（SQLite + vnstat 双兼容）**：
  - 直接读取 Linux `/proc/net/dev` 实现 1 秒级低开销实时吞吐推送（SSE），无需预装 `vnstat` 即可记录全周期流量；
  - 支持 `Hybrid 智能融合` 或一键将宿主机原有 `/var/lib/vnstat` 历史账本无损合并导入内置数据库（纯只读不修改原文件）。
- **IPv4 / IPv6 双栈 & 自动放行防火墙**：
  - 默认双栈监听 `[::]:10089`，自动识别网卡 IPv4 与全局 IPv6 地址；
  - 一键脚本自动检测并放行 `UFW`、`Firewalld` 及甲骨文云（Oracle Cloud）预设的 `iptables` / `ip6tables` 拦截规则。
- **多通道告警（含国内直连）& 可视化备份还原**：
  - 支持自定义每月账单重置日（1–31 号）、4 种计费方向（双向 / 仅上行 / 仅下行 / 单向取大）、**企业微信机器人、飞书自定义机器人（支持签名校验，国内机器直连推荐）**、Telegram Bot 与通用 Webhook 防 SSRF 通知，以及主控统一托管全集群掉线/恢复/流量/磁盘/内存告警；
  - 内置 SQLite 一致性快照创建、下载到本地、列表还原与上传本地 `.tar.gz` 还原（自动校验完整性并留存保护快照）。

---

## 一键安装与更新脚本（默认推荐静态二进制部署）

`install.sh` 内置**中国大陆网络自动检测与多节点 GitHub 代理回退机制**，**默认推荐静态二进制 (`systemd`) 部署**（极致省内存、原生读取宿主机网卡、支持网页一键自升级与主控多架构分发），同时提供 **Docker 容器部署**、**一键接入主控** 与 **保留数据安全卸载**。

### 1. 下载脚本并启动交互菜单

```bash
curl -fsSL --connect-timeout 5 https://raw.githubusercontent.com/vbskycn/FlowMaster/main/install.sh -o install.sh || \
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/vbskycn/FlowMaster/main/install.sh -o install.sh
chmod +x install.sh
sudo ./install.sh
```

### 2. 非交互式常用一键命令

```bash
# 方式 A（默认推荐）：静态二进制 + systemd 一键部署或更新至最新版（极致省内存，支持网页一键远程升级与多架构主控分发）
sudo ./install.sh binary

# 方式 B（容器化备选）：Docker 一键部署或更新至最新版（自动放行 10089 防火墙）
sudo ./install.sh docker

# 方式 C：智能一键更新已部署的实例（自动识别二进制或 Docker 模式并升级，失败自动回滚）
sudo ./install.sh update

# 查看状态 / 安全卸载（仅移除程序与服务，完整保留流量数据库、配置与 /var/lib/vnstat）
sudo ./install.sh status
sudo ./install.sh uninstall
```

---

## 多台机器集中管理教程（1 台主控 + N 台被控）

如果你有几十台服务器希望在一个页面集中查看、对比和统一升级：

1. **部署主控机（Hub）**：任选一台公网可达的机器（建议绑定双栈域名并反代 HTTPS，或直接使用公网 `IP:10089`），推荐执行 `sudo ./install.sh binary`（或 Docker 备选 `sudo ./install.sh docker`）完成部署，打开页面点击右上角 **「管理登录」** 设置管理员密码，进入 **「系统设置」** 勾选 **「开启主控模式（Hub 多机管理中枢）」** 并保存（普通单机和被控节点默认不显示多机与添加节点菜单）。开启主控模式后，主控会自动在本地缓存保留 `linux/amd64` 与 `linux/arm64` 双架构安装包（也可在后台「节点与分组」一键手动同步）。
2. **生成接入命令（默认主控直发安装包，国内小鸡免连 GitHub）**：在主控顶部切换到 **「🌐 多机总览」** → 点击 **「+ 添加服务器节点」**，保持默认勾选 **「由本主控机直接分发安装脚本与二进制包」**（取消勾选才从 GitHub 或公共代理加速地址分发），点击生成并一键复制命令（形如）：

   ```bash
   curl -fsSL 'https://主控地址/api/v1/cluster/dist/install.sh?token=fm_专属节点密钥' -o install.sh && \
   chmod +x install.sh && sudo ./install.sh join --hub 'https://主控地址' --token 'fm_专属节点密钥' --mirror-hub --name '香港-HK1'
   ```
3. **被控机粘贴执行**：在每台被控服务器上执行上述命令，脚本会直接从主控拉取通过 SHA-256 校验的静态二进制包完成部署、默认开放本机 `10089` 面板并放行系统防火墙（若不希望被控机开放本地 Web 端口，可使用弹窗中的 `--no-web` 纯探针命令），2 秒内即可在主控看到该机器实时网速与历史统计！
4. **后续统一升级**：新版本发布后，只需先更新主控，再在主控「多机总览 → 🚀 统一远程升级」中全选在线节点点击升级，所有二进制被控节点即会优先从主控下载校验并平滑重启至新版本。

---

## 宝塔面板（Nginx）反向代理与 Cloudflare CDN 配置指南

### 1. 宝塔面板反向代理必看注意事项

在宝塔面板新建站点并为 FlowMaster（默认 `http://127.0.0.1:10089`）添加反向代理时，请注意以下 **5 点**：

1. **严禁勾选「开启缓存」**：新建反代时不要开启宝塔静态缓存，否则 `/api/*` 实时数据与登录状态会被缓存。
2. **关闭代理缓冲并调大读超时**：在反代配置文件中加入 `proxy_buffering off;` 与 `proxy_read_timeout 3600s;`，否则首页秒级网速（SSE）会卡顿延迟，且每 60 秒断流重连一次。
3. **开启 `TRUST_PROXY=true` 并透传真实访客 IP**：
   - 在 FlowMaster 配置中设置 `TRUST_PROXY=true`（二进制编辑 `/etc/flowmaster/flowmaster.env` 后执行 `sudo flowmaster-ctl restart`，Docker 添加 `-e TRUST_PROXY=true`），使系统自动按 HTTPS 启用 `Secure` Cookie 并按真实客户端 IP 执行登录防爆破限流（原生兼容识别 `CF-Connecting-IP` 与 `X-Forwarded-For`）。
4. **宝塔 WAF / CC 防护白名单**：若启用了宝塔 Nginx 防火墙，请将 URL 前缀 `^/api/v1/cluster/` 加入 **URL 白名单**，防止几十台子节点每 3 秒一次的心跳上报被误判为 CC 攻击拉黑。
5. **收敛宿主机监听地址（可选加固）**：配置好宝塔 `443` 反代后，可将 FlowMaster 的 `HOST` 改为 `127.0.0.1`，对外无需再暴露 `10089` 端口，浏览面板与子节点 `join` 统一走 `443` HTTPS。

#### 宝塔「反向代理 → 配置文件」可直接替换的推荐配置：

```nginx
# PROXY-START/
location ^~ /
{
    proxy_pass http://127.0.0.1:10089;
    proxy_http_version 1.1;
    proxy_set_header Connection "";

    proxy_set_header Host $host;
    # 若前端套了 Cloudflare，自动取 CF-Connecting-IP；未套 CDN 时自动回退 $remote_addr
    set $real_client_ip $remote_addr;
    if ($http_cf_connecting_ip != "") {
        set $real_client_ip $http_cf_connecting_ip;
    }
    proxy_set_header X-Real-IP $real_client_ip;
    proxy_set_header X-Forwarded-For $real_client_ip;
    proxy_set_header X-Forwarded-Proto $scheme;

    # 关键：关闭缓冲与缓存，保证 SSE 秒级网速与 25s 反向长轮询实时透传
    proxy_buffering off;
    proxy_cache off;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;

    # 允许后台上传本地备份归档一键还原
    client_max_body_size 128m;
}
# PROXY-END/
```

### 2. Cloudflare CDN 兼容性与「双域名」最佳实践

- **单域名直接开启 Cloudflare（小黄云）可用**：主从心跳与反向长轮询（服务端挂起 `25s`，远低于 Cloudflare `100s` 的 `524` 超时限制）均走标准 HTTP/HTTPS，开启 CDN 后仍可正常连接。若开启了 CF Bot Fight Mode / 质询盾，请在 Cloudflare `Security -> WAF -> Custom rules` 为 URI Path 前缀 `/api/v1/cluster/` 添加一条 **Skip（跳过质询）** 规则。
- **双域名方案（国内机器多时强烈推荐）**：在同一个宝塔站点绑定两个域名：
  - **日常查看域名**（如 `flow.example.com`，**开启 Cloudflare CDN 小黄云**）：浏览器打开面板走 CDN 加速并隐藏源站 IP；
  - **节点接入专用域名**（如 `hub-direct.example.com`，**设为灰色云朵仅 DNS 直连**）：填在主控后台「主控公网接入地址」中，专门供国内/海外被控机器直连上报心跳与满速拉取主控分发的安装包，彻底避开晚高峰 CDN 减速与盾拦截。

---

## 手动 Docker 部署与升级

官方同步发布 `linux/amd64` 与 `linux/arm64` 多架构镜像：

- **Docker Hub**：`zhoujie218/flowmaster:2.5.2`（及 `zhoujie218/flowmaster:latest`）
- **GitHub Container Registry**：`ghcr.io/vbskycn/flowmaster:2.5.2`（及 `ghcr.io/vbskycn/flowmaster:latest`）

### `docker run` 部署（默认双栈 IPv4/IPv6）

```bash
mkdir -p /opt/flowmaster/data

docker run -d \
  --name flowmaster \
  --restart unless-stopped \
  --network host \
  -e TZ=Asia/Shanghai \
  -e HOST=:: \
  -e PORT=10089 \
  -v /opt/flowmaster/data:/data \
  zhoujie218/flowmaster:2.5.2
```

> **提示**：
>
> - 如宿主机已有系统 `vnstat` 历史数据，可附加 `-v /var/lib/vnstat:/var/lib/vnstat:ro -e VNSTAT_DB_DIR=/var/lib/vnstat`。
> - 云厂商控制台层面的安全组（如阿里云/腾讯云安全组、甲骨文云 Security Lists）位于操作系统外部，如需直接从公网访问 `10089` 面板请同步在云后台放行 TCP `10089`（纯探针 `--no-web` 被控节点无需放行任何入站端口）。

### `docker compose` 部署与升级

使用仓库中的 [compose.yaml](compose.yaml)：

```bash
docker compose up -d

# 升级版本（建议升级前先在管理后台下载一份备份快照）
docker pull zhoujie218/flowmaster:2.5.2
docker compose up -d
```

---

## 常用环境变量

完整配置项见 [.env.example](.env.example)，反向代理与运维细节见 [安装、安全与运维指南](docs/operations.md)：

| 变量          | 默认值                   | 说明                                                                   |
|:------------- |:------------------------ |:---------------------------------------------------------------------- |
| `HOST`        | `::`                     | 监听地址（默认 `::` 同时监听 IPv4 与 IPv6；可填 `127.0.0.1` 或 `::1`） |
| `PORT`        | `10089`                  | HTTP 监听端口                                                          |
| `DATA_DIR`    | `./data`（容器 `/data`） | SQLite 数据库、会话密钥、日志与备份持久化目录                          |
| `HUB_URL`     | 空                       | 被控节点主动连接的主控地址（如 `https://hub.example.com`）             |
| `HUB_TOKEN`   | 空                       | 主控生成的节点专属接入密钥（`fm_...`）                                 |
| `NODE_NAME`   | 空                       | 被控节点上报展示名称（留空默认取主机名）                               |
| `DISABLE_WEB` | `false`                  | 设为 `true` 时关闭本机 Web 端口，仅作为纯后台探针向主控上报            |
| `TRUST_PROXY` | `false`                  | 位于可信 HTTPS 反向代理后方时设为 `true`                               |

---

## 文档导航

- **官方文档站（推荐）**：[https://flowmaster-docs.168668518.com/](https://flowmaster-docs.168668518.com/)
- [系统架构说明](docs/architecture.md)
- [HTTP API 文档（含集群、v1 与旧版兼容端点）](docs/api.md)
- [安装、安全与运维指南](docs/operations.md)
- [开发与贡献指南](CONTRIBUTING.md)
- [版本更新记录](CHANGELOG.md)

## 获取帮助与支持

- 问题反馈：[GitHub Issues](https://github.com/vbskycn/FlowMaster/issues)
- 版本发布：[GitHub Releases](https://github.com/vbskycn/FlowMaster/releases)
- Docker 镜像：[Docker Hub (`zhoujie218/flowmaster`)](https://hub.docker.com/r/zhoujie218/flowmaster)
- 交流社区：[LINUX DO 社区](https://linux.do)（感谢 LINUX DO 社区与各位佬友的支持与建议）
- 开源协议：[MIT](LICENSE)

如果 FlowMaster 对你有帮助，欢迎支持项目：

![支持项目](assets/dsm.jpg)
