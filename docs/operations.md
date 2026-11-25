# FlowMaster 安装、安全与运维指南

## 一、一键安装与更新脚本 (`install.sh`)

`install.sh` 统一封装了 **Docker 容器部署** 与 **静态二进制 + systemd 部署** 两种生产模式，并内置国内网络环境自动探测机制：

1. **国内网络自动加速原理**：
   - 执行安装或更新时，脚本先探测当前网络归属地与 GitHub 官方直连连通性；
   - 若识别为国内网络或直连超时，自动轮询测速内置代理池并**校验返回内容真实性**（拒绝代理返回的 HTML 报错页），下载二进制时强制比对 `SHA256SUMS` 校验和；
   - Docker 模式下若官方源拉取超时，自动回退尝试镜像加速前缀与 GHCR 源。
2. **常用维护子命令**：
   - `sudo ./install.sh docker`：部署或更新 Docker 容器（更新异常自动回退旧镜像 ID）
   - `sudo ./install.sh binary`：部署或更新二进制 `systemd` 服务（更新异常自动回退旧二进制）
   - `sudo ./install.sh update`：自动检测当前部署模式并平滑更新至最新版本
   - `sudo ./install.sh status` / `sudo ./install.sh uninstall`

---

## 二、Docker 生产部署建议

1. **网络模式**：容器需读取宿主机真实网卡流量（`/proc/net/dev`），请使用 `--network host`。若需更改监听地址或端口，可通过环境变量 `-e HOST=127.0.0.1 -e PORT=10089` 控制（例如仅监听本机回环并由宿主机 Nginx / Caddy 反代提供公网 HTTPS）。
2. **持久化目录**：始终使用明确的宿主机目录挂载至 `/data`（如 `-v /opt/flowmaster/data:/data`），严禁使用匿名卷存储数据库。`/data` 目录结构如下：
   - `/data/flowmaster.db`（及 `-wal`/`-shm`）：核心流量与配置 SQLite 数据库
   - `/data/session.key`：自动生成的 `0600` 高强度随机会话签名密钥
   - `/data/backups/`：手动备份与还原前自动留存的保护快照（`.tar.gz` + `.sha256`）
   - `/data/logs/`：`system.log` 与 `alert.log` 独立轮转日志（单文件上限 2 MiB，最多保留 3 个轮转副本，防止磁盘写满）
3. **混合模式挂载系统 `vnstat`（可选）**：
   - 如宿主机已有运行中的 `vnstatd` 并积累了历史流量，可添加只读挂载 `-v /var/lib/vnstat:/var/lib/vnstat:ro` 且设置 `-e VNSTAT_DB_DIR=/var/lib/vnstat`。
   - 容器内置了轻量 `vnstat` CLI，可在后台选择 `Hybrid 智能融合` 直接展示历史数据，或点击「从系统 vnstat 幂等导入历史数据」将其永久合并进 `/data/flowmaster.db` 后脱离 `vnstat` 独立运行。

---

## 三、公网反向代理与 HTTPS 安全配置

公网暴露建议前置 HTTPS 反向代理（如 Caddy 或 Nginx），并在 FlowMaster 中设置 `TRUST_PROXY=true`：

- 设置 `TRUST_PROXY=true` 后，FlowMaster 会读取可信代理传递的 `X-Forwarded-For` 进行限流与防爆破识别，并根据 `X-Forwarded-Proto: https` 自动为会话 Cookie 启用 `Secure` 属性。
- 在局域网直接通过 `http://内网IP:10089` 访问时，会话 Cookie 自动保持非 `Secure` 模式，剪贴板复制自动启用兼容回退，不影响内网运维调试。
- 反向代理转发 `/api/v1/stream/realtime`（SSE 实时流）时，建议关闭代理缓冲（FlowMaster 已自动响应 `X-Accel-Buffering: no`）。Nginx 参考片段：

```nginx
location / {
    proxy_pass http://127.0.0.1:10089;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_buffering off;
    proxy_read_timeout 3600s;
}
```

---

## 四、备份、还原与灾难恢复

1. **日常备份**：登录 Web 管理后台 →「备份与还原」→「一键创建备份快照」→「下载到本地」。
2. **故障恢复**：
   - 在线恢复：在「备份与还原」列表中点击目标快照的「一键还原」，或上传离线保存的 `.tar.gz` 备份文件。
   - 安全机制：恢复流程在替换数据库前会依次执行归档路径/类型检查、SHA-256 摘要校验、SQLite `PRAGMA integrity_check` 及核心表检查，随后自动生成当前现网数据的 `pre-restore-*` 保护快照，最后原子切换数据库文件；若切换后自检失败会自动回滚原数据库。

---

## 五、常见问题排查

### 1. 容器内只看到 `eth0` 而看不到宿主机多张网卡？
请确认 Docker 启动命令或 `compose.yaml` 中已配置 `--network host`（`network_mode: host`）。默认桥接网络下容器拥有独立的 Network Namespace，只能看到容器自身虚拟网卡。

### 2. 忘记了管理员登录密码怎么办？
管理员密码哈希存储在 SQLite 的 `kv_settings` 表（键名 `admin_password_hash`）中。若遗忘密码且已设置环境变量 `ADMIN_PASSWORD`，可在停服备份 `/data/flowmaster.db` 后清除该键值并重启服务重新初始化，或配置临时 `ADMIN_TOKEN` 通过 API 重置密码。

### 3. 端口冲突如何修改？
- Docker (`--network host`)：修改环境变量 `-e PORT=新端口` 并重启容器。
- systemd 部署：编辑 `/etc/flowmaster/flowmaster.env` 中的 `PORT=`，然后执行 `sudo flowmaster-ctl restart`。
