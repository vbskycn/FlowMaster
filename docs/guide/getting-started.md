# 项目简介与快速开始

**FlowMaster** 是一个专为 Linux 服务器、VPS 与多机集群设计的超轻量级网络流量实时监控与统一管理中枢。

同一个静态二进制文件同时胜任三种角色：
- **单机轻量监控面板**（默认）：零多余菜单，专注本机秒级网速、多周期流量统计、CPU/内存/硬盘负载与月度流量包提醒。
- **多机主控中心（Hub）**：在管理后台显式勾选开启 **「主控模式」** 后，立即解锁多机总览墙、横向对比图表、节点分组、多架构安装包直发、批量管控与集群统一告警。
- **被控采集节点（Agent）**：通过主控一键命令接入，3 秒主动上报心跳与 25 秒反向长轮询隧道，穿透 NAT 与纯 IPv6 环境，默认保留本地 `10089` 独立面板（亦可选 `--no-web` 纯探针模式）。

---

## 环境要求

| 项目 | 要求说明 |
| :--- | :--- |
| 操作系统 | 任意主流 Linux 发行版（Debian / Ubuntu / CentOS / Rocky / Alpine 等） |
| CPU 架构 | `x86_64` (`linux/amd64`)、`aarch64` (`linux/arm64`) |
| 内存占用 | 常驻约 **12 ~ 18 MB**（无需 Node.js / Python / 外部数据库） |
| 端口 | 默认 `10089`（IPv4 + IPv6 双栈监听 `HOST=::`，可自定义或收敛至 `127.0.0.1` 配合反代） |
| 外部依赖 | **无强制依赖**；若宿主机已安装 `vnstat`，自动以纯只读方式支持 `Hybrid` 智能融合或一键历史导入 |

---

## 快速上手（3 步完成）

### 第 1 步：一键安装（默认推荐静态二进制）

```bash
curl -fsSL --connect-timeout 5 https://raw.githubusercontent.com/vbskycn/FlowMaster/main/install.sh -o install.sh || \
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/vbskycn/FlowMaster/main/install.sh -o install.sh
chmod +x install.sh
sudo ./install.sh binary
```

脚本会自动：
1. 检测中国大陆网络环境并在需要时测速启用 GitHub 加速代理；
2. 下载对应架构（`amd64` / `arm64`）官方预编译静态二进制并严格核验 `SHA256SUMS`；
3. 创建受限非 root 系统用户 `flowmaster` 并配置 `systemd` 守护服务；
4. 自动放行本机防火墙 `10089` 端口（兼容 UFW、Firewalld 及甲骨文云 `iptables` / `ip6tables` 规则）。

### 第 2 步：打开面板并初始化管理员密码

在浏览器访问 `http://你的服务器IP:10089`：
- 点击右上角 **「🔒 管理登录」**，首次进入将引导你设置管理员密码；
- 登录后可进入 **「⚙️ 本机后台」** 配置网卡备注、月度流量包、告警通道与备份快照。

### 第 3 步：按需开启「主控模式」管理多台机器

如果你只有一台服务器，到这里就已经全部完成！  
如果你有多台 VPS 需要集中监控，只需在主控机的 **「⚙️ 本机后台 → 系统设置」** 中勾选 **「开启主控模式（Hub 多机管理中枢）」** 并保存，即可参考 [多机集群与主控分发指南](/guide/cluster) 接入其他机器。
