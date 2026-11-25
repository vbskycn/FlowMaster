# FlowMaster 协作规范

## 项目边界

- 本项目是基于 **Go 单二进制 + 纯 Go SQLite + 内嵌 Vue 3 现代前端** 的轻量级 Linux 主机网络流量实时监控与管理系统，同时支持混合读取或导入系统 `vnstat` 数据。
- 根目录 `VERSION`（`APP_NAME` / `APP_VERSION`）是产品版本唯一来源，由 Go `embed` 在编译期直接注入二进制与前端接口；普通开发阶段不要提前修改版本号。
- 现代前端使用 `/api/v1/*` 结构化接口与 SSE 实时流；同时完整保留旧版 `/api/*`（`interfaces`、`stats`、`range`、`version`、`system/status` 等）响应字段兼容。

## 数据安全

- 安装、更新、重置或卸载 FlowMaster 时**严禁删除或修改系统 `/var/lib/vnstat`**；混合引擎读取或历史导入对 `/var/lib/vnstat` 仅执行只读访问。
- Web 管理后台内置可视化备份与还原功能：
  - 创建备份使用 SQLite `VACUUM INTO` 生成在线一致性快照并附带 SHA-256 校验；
  - 恢复数据（无论是从快照列表还原还是上传本地归档还原）前必须拒绝路径穿越、链接、重复成员与超大归档，并对候选库执行 `PRAGMA integrity_check` 及核心表检查；
  - 正式切换数据库前必须自动留存一份 `pre-restore` 保护快照，切换或自检失败必须自动回滚至原现网数据库。
- 重置内置 SQLite 流量统计必须是独立、显式输入 `RESET` 确认且先自动创建保护快照的操作。

## 开发与测试

- Go 版本见 `go.mod`（`CGO_ENABLED=0` 纯静态编译，使用 `modernc.org/sqlite`）；前端工程位于 `web/`（Node.js 22+ 与 `npm ci`）。
- 提交前至少执行：
  - 前端构建：`cd web && npm ci && npm run build`
  - Go 静态检查与单测：`go vet ./... && go test -race ./...`
  - Shell 脚本检查：`bash -n install.sh && shellcheck --severity=warning install.sh`
- Linux 内核 `/proc/net/dev` 采集、Docker `--network host` 部署及 `vnstat` 混合模式应在真实 Debian/Linux 环境执行端到端冒烟验证。

## 部署与安全

- 优先推荐单容器多阶段 Docker 部署（`--network host` 读取宿主机真实网卡并明确挂载宿主机目录至 `/data`，禁用匿名卷）；宿主机裸机部署使用 `flowmaster.service` 与受限 `flowmaster` 系统账号。
- `.dockerignore` 必须排除 `.md` 文档、测试与本地缓存；运行时秘密严禁打入镜像。
- 会话签名密钥未显式配置有效强随机值时，自动在 `DATA_DIR/session.key` 生成 `0600` 随机密钥；Cookie `Secure` 属性按 HTTPS 或可信代理 `X-Forwarded-Proto` 动态开启，兼顾内网 HTTP 与公网 HTTPS。
- 后台告警敏感凭据（Webhook Secret、Telegram Bot Token）只写不回显（API 仅返回脱敏掩码），日志拆分为 `system` 与 `alert` 独立轮转通道并自动脱敏，默认按时间倒序（最新在顶部）展示。
- 外部 Webhook / Telegram 告警推送禁止自动跟随重定向，默认拦截回环与私有内网地址（防 SSRF）。
