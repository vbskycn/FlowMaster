# 安装、升级与安全卸载

FlowMaster 提供统一的一键维护脚本 `install.sh`，**默认推荐静态二进制（`systemd`）部署**，同时保留 Docker 容器部署作为备选方案。

::: tip 为什么默认推荐静态二进制部署？
1. **极致省内存**：无需 Docker 守护进程开销，单机常驻内存仅 12 ~ 18 MB。
2. **原生读取宿主机硬件与网卡**：直接访问 `/proc/net/dev`、`/proc/stat`、`/proc/meminfo` 与根分区空间。
3. **支持主控网页一键远程自升级**：被控节点可在主控页面一键勾选原子替换并平滑重启，Docker 模式则需在宿主机手动拉取新镜像。
:::

---

## 一、交互式维护菜单

下载脚本并无参数运行即可进入交互菜单：

```bash
curl -fsSL --connect-timeout 5 https://raw.githubusercontent.com/vbskycn/FlowMaster/main/install.sh -o install.sh || \
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/vbskycn/FlowMaster/main/install.sh -o install.sh
chmod +x install.sh
sudo ./install.sh
```

菜单项一览（直接回车默认执行选项 `1`）：

1. **二进制部署 / 更新至最新版**（默认推荐，`systemd` 守护，支持远程自升级与多架构主控分发）
2. **Docker 部署 / 更新至最新版**（容器化备选方案）
3. **作为被控节点接入主控中心**（同时开启本机 `10089` 面板并放行防火墙）
4. **智能一键更新已安装的实例**（自动识别当前模式并升级，健康检查失败自动回滚）
5. **查看运行状态与当前版本**
6. **卸载 FlowMaster（仅移除程序与服务，完整保留历史数据）**

---

## 二、非交互式常用命令

```bash
# 默认推荐：静态二进制 + systemd 一键安装或平滑更新
sudo ./install.sh binary

# 容器化备选：Docker 一键安装或平滑更新
sudo ./install.sh docker

# 自动识别当前部署模式并更新至最新版
sudo ./install.sh update

# 查看当前安装模式、版本号与服务状态
sudo ./install.sh status

# 安全卸载（交互确认，完整保留数据库与配置；附加 -y 跳过确认）
sudo ./install.sh uninstall
```

二进制部署完成后，系统会自动安装便捷管理命令 `flowmaster-ctl`：

```bash
sudo flowmaster-ctl status   # 查看运行状态
sudo flowmaster-ctl restart  # 重启服务
sudo flowmaster-ctl logs     # 实时跟踪 systemd 日志
flowmaster-ctl version       # 查看当前二进制版本
```

---

## 三、国内网络加速与自定义参数

`install.sh` 支持以下环境变量进行精细控制：

| 环境变量 | 说明 | 示例 |
| :--- | :--- | :--- |
| `FLOWMASTER_VERSION` | 安装指定版本（默认 `latest`） | `FLOWMASTER_VERSION=v2.5.1` |
| `FLOWMASTER_PORT` | 自定义监听端口（默认 `10089`） | `FLOWMASTER_PORT=18080` |
| `FLOWMASTER_CN` | `1` 强制国内代理加速，`0` 强制直连 GitHub | `FLOWMASTER_CN=1` |
| `FLOWMASTER_GH_PROXY` | 指定自定义 GitHub 反代前缀 | `FLOWMASTER_GH_PROXY=https://gh-proxy.com/` |
| `FLOWMASTER_SKIP_FIREWALL` | 设为 `1` 跳过自动放行系统防火墙 | `FLOWMASTER_SKIP_FIREWALL=1` |
| `FLOWMASTER_MIRROR_HUB` | `join` 时优先从主控直发安装包（默认 `1`） | `FLOWMASTER_MIRROR_HUB=1` |

---

## 四、手动 Docker / Compose 部署（备选）

官方同步发布 `linux/amd64` 与 `linux/arm64` 多架构镜像：
- **Docker Hub**：`zhoujie218/flowmaster`
- **GHCR**：`ghcr.io/vbskycn/flowmaster`

### `docker run` 示例

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
  zhoujie218/flowmaster:latest
```

::: warning 网络与卷挂载要求
- 必须使用 `--network host` 才能读取宿主机真实网卡流量（而非容器隔离网卡）。
- 必须使用明确的宿主机目录挂载至 `/data`（禁用匿名卷）。
- 如需融合宿主机既有 `vnstat` 历史记录，可只读附加 `-v /var/lib/vnstat:/var/lib/vnstat:ro -e VNSTAT_DB_DIR=/var/lib/vnstat`。
:::

---

## 五、安全卸载（完整保留历史数据）

执行 `sudo ./install.sh uninstall` 或在交互菜单选择 `6`：
- **将移除**：`flowmaster.service` 系统服务、`/usr/local/bin/flowmaster`、`/usr/local/bin/flowmaster-ctl`、`/var/lib/flowmaster/bin/flowmaster` 及同名 Docker 容器；
- **完整保留**：
  - `/var/lib/flowmaster/`（SQLite 历史流量数据库、会话密钥、备份快照、主控分发缓存）
  - `/etc/flowmaster/flowmaster.env`（服务配置）
  - `/opt/flowmaster/data/`（Docker 持久化目录）
  - `/var/lib/vnstat/`（系统原有 vnstat 数据，任何操作均绝不触碰）

后续重新安装时会自动无缝继承全部历史流量与配置。
