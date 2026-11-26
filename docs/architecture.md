# FlowMaster 系统架构说明

## 设计目标

FlowMaster 采用 **Go 单静态二进制 + 纯 Go SQLite（WAL 模式）+ 编译期嵌入式 Vue 3 前端** 架构，消除外部运行时依赖与高频子进程采样开销，并在同一个二进制内同时支持单机监控、主控中心（Hub）与被控节点（Agent）。

```text
Linux 宿主机内核 (/proc/net/dev, /proc/stat, /proc/meminfo, statfs /)
   │ (1s 内存伪文件直采)                       可选只读: vnstat --json
   ▼                                                │
┌───────────────────────────────────────────────────┴──────────────────┐
│                  FlowMaster 单静态二进制 (~12~18 MB)                   │
│                                                                      │
│  [collector] 混合流量引擎 + 主机 CPU/内存/硬盘采样 + SSE 实时广播      │
│       │ (15s 批量事务刷盘)                                            │
│  [store]     纯 Go SQLite WAL + VACUUM INTO 在线快照 + 原子换库回滚   │
│  [quota]     月度重置日账单 + 四通道防 SSRF 告警 (企微/飞书/TG/Hook)  │
│  [cluster]   Hub 显式主控开关 + Agent 3s 心跳 + 25s 反向长轮询隧道    │
│  [updater]   主控 amd64/arm64 多架构分发缓存 + 原子 OTA 自升级        │
│  [web]       IPv4/IPv6 双栈 + PBKDF2 认证 + 访客脱敏 + 内嵌 Vue 3 SPA │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 核心模块职责

| 目录 / 文件 | 职责说明 |
| :--- | :--- |
| `VERSION` + `embed.go` | 全仓唯一版本源；编译期直接嵌入前端 `web/dist` 与主控直发脚本 `install.sh` |
| `cmd/flowmaster` | CLI 参数解析（`--version`、`--help`、`--healthcheck`、`-env-file`）、组件装配与优雅退出 |
| `internal/config` | 环境变量与 `.env` 加载、安全范围兜底、`DATA_DIR/session.key` 加密随机密钥生成（`0600`） |
| `internal/logger` | `system` 与 `alert` 物理隔离双通道日志、自动脱敏凭据（Bot Token / 飞书 Hook / Bearer / Key）与 2 MiB 轮转 |
| `internal/collector` | `/proc/net/dev` 计数器回绕安全差分、主机 CPU/内存/硬盘纯 Go 采样、`vnstat --json` 只读融合与 SSE 广播 |
| `internal/store` | 纯 Go SQLite（`modernc.org/sqlite`）5m/h/d/m 聚合表、集群节点元数据、`VACUUM INTO` 快照与失败自动回滚 |
| `internal/quota` | VPS 月度账单区间计算、四向计费、企业微信 / 飞书（含 HMAC 签名） / Telegram / Webhook 禁重定向防 SSRF 推送 |
| `internal/cluster` | 1 Hub + N Agents 集群纳管、批量改分组/配额/重启/删除、主控统一集群巡检告警与零 RCE 白名单动作执行 |
| `internal/updater` | 主控 `DATA_DIR/dist-cache/` 多架构（`amd64`/`arm64`）分发缓存、SHA-256 校验与被控端原子自升级 |
| `internal/web` | IPv4/IPv6 双栈监听、防爆破登录限流、动态 `Secure` Cookie、访客敏感字段脱敏、`/api/v1/*` 与旧版 `/api/*` 兼容 |
| `web/` | Vue 3 + Vite + Tailwind CSS + 按需裁剪 Chart.js 构建的单机看板、多机矩阵总览与可视化管理中心 |
| `docs/` | 基于 VitePress 构建的官方静态文档站（独立目录，`.dockerignore` 已排除，不进入镜像） |

---

## 多机通信与安全模型

1. **穿透 NAT 与纯 IPv6**：被控节点主动向主控发起出站 HTTP/HTTPS 连接（3 秒心跳上报 + 25 秒反向长轮询），无需在被控机开放额外控制端口。
2. **零任意 Shell / 零 RCE**：反向 RPC 隧道仅允许白名单查询与受控动作（流量统计、网卡配置、配额保存、脱敏日志只读、SQLite 备份直传、`restart_service` 平滑重启、`self_upgrade` 官方包校验升级），彻底杜绝命令注入面。
3. **非特权沙箱运行**：二进制部署默认运行在受限系统账号 `flowmaster` 下（`NoNewPrivileges=true`、`ProtectHome=true`、`ProtectSystem=strict`、`ReadWritePaths=/var/lib/flowmaster`）。
