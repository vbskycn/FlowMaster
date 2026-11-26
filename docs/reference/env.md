# 环境变量与配置参考

FlowMaster 支持通过系统环境变量或 `-env-file` 指定的 `.env` 文件（二进制部署默认为 `/etc/flowmaster/flowmaster.env`）进行配置。

## 一、服务端运行环境变量

| 变量名 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `HOST` | `::` | HTTP 监听地址。默认 `::` 开启 IPv4 + IPv6 双栈监听；若前置本机反代可收敛为 `127.0.0.1` 或 `::1` |
| `PORT` | `10089` | HTTP 监听端口 |
| `DATA_DIR` | `./data` | 持久化数据目录（二进制部署为 `/var/lib/flowmaster`，Docker 内为 `/data`） |
| `REALTIME_INTERVAL_MS` | `1000` | 内核秒级采样间隔（毫秒，合法范围 `1000..60000`） |
| `HUB_URL` | 空 | 被控节点上报的主控地址（如 `https://hub.example.com`）；留空表示独立面板或主控 |
| `HUB_TOKEN` | 空 | 主控生成的节点专属接入密钥（`fm_...`） |
| `NODE_NAME` | 空 | 被控节点上报展示名称（留空默认取宿主机名） |
| `DISABLE_WEB` | `false` | 设为 `true` 时关闭本机 Web 端口，仅作为纯无端口后台探针向主控上报 |
| `TRUST_PROXY` | `false` | 服务位于可信 HTTPS 反向代理后方时设为 `true`，用于识别真实访客 IP（含 `CF-Connecting-IP`）并动态启用 `Secure` Cookie |
| `ADMIN_PASSWORD` | 空 | 可选初始管理员密码；留空时首次访问后台将引导在网页初始化密码 |
| `ADMIN_TOKEN` | 空 | 可选静态 API 管理令牌（通过请求头 `X-Admin-Token` 认证） |
| `ALLOW_ANONYMOUS_ADMIN` | `false` | 仅用于旧版 `/api/cache/clear` 等兼容接口的匿名开关，生产环境保持 `false` |
| `SESSION_SECRET` | 空 | 会话签名密钥；留空或弱值时自动在 `DATA_DIR/session.key` 生成 `0600` 强随机密钥 |
| `CORS_ORIGINS` | 空 | 逗号分隔的精确跨域白名单，留空时不发送 CORS 许可头 |
| `VNSTAT_BIN` | `vnstat` | 系统 `vnstat` 可执行文件路径（仅 Hybrid / vnstat 模式或历史导入使用） |
| `VNSTAT_DB_DIR` | 空 | 可选自定义 `vnstat` 数据库目录（默认使用系统 `/var/lib/vnstat`，只读访问） |
| `VNSTAT_COMMAND_TIMEOUT_MS` | `15000` | 调用 `vnstat --json` 的单次超时时间（毫秒） |
| `VNSTAT_MAX_CONCURRENCY` | `4` | 并发执行 `vnstat` 读取的最大协程数 |
| `MAX_RANGE_DAYS` | `3660` | 自定义日期范围查询允许的最大跨度（天） |
| `RATE_LIMIT_WINDOW_MS` | `60000` | API 限流统计时间窗口（毫秒） |
| `RATE_LIMIT_MAX` | `300` | 单客户端在每个窗口内的最大请求次数 |
| `RATE_LIMIT_MAX_CLIENTS` | `10000` | 限流器内存中跟踪的最大客户端 IP 数量 |
| `FLOWMASTER_CN` | 空 | 设为 `1` 时主控/节点自升级优先走内置 GitHub 加速代理池 |
| `FLOWMASTER_GH_PROXY` | 空 | 自定义 GitHub 下载代理前缀（如 `https://gh-proxy.com/`） |

---

## 二、一键脚本 (`install.sh`) 环境变量

| 变量名 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `FLOWMASTER_VERSION` | `latest` | 指定安装或更新的固定版本号（例如 `v2.5.1`） |
| `FLOWMASTER_PORT` | `10089` | 部署时写入的默认监听端口并自动放行宿主机防火墙 |
| `FLOWMASTER_MIRROR_HUB` | `0` | `join` 时设为 `1`（或传 `--mirror-hub`）优先直接从主控机拉取安装脚本与二进制包 |
| `FLOWMASTER_SKIP_FIREWALL` | `0` | 设为 `1` 跳过 UFW / Firewalld / iptables 防火墙自动放行 |
| `FLOWMASTER_CN` | 自动探测 | `1` 强制启用国内加速代理模式，`0` 强制直连 GitHub |
| `FLOWMASTER_GH_PROXY` | 自动测速 | 自定义 GitHub 反代前缀 |
| `FLOWMASTER_DOCKER_DATA_DIR` | `/opt/flowmaster/data` | Docker 模式下宿主机持久化挂载目录 |
