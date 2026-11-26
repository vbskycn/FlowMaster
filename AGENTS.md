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
  - 文档站构建（涉及文档更新或发版时）：`cd docs && npm run build`
- Linux 内核 `/proc/net/dev` 采集、Docker `--network host` 部署及 `vnstat` 混合模式应在真实 Debian/Linux 环境执行端到端冒烟验证。

## 文档与静态文档站（Cloudflare Pages）

- 项目官方静态文档站位于 `docs/` 目录（VitePress），由 Cloudflare Pages 关联本仓库 `main` 分支自动构建部署（根目录 `docs`，输出 `.vitepress/dist`），线上绑定域名 `https://flowmaster-docs.168668518.com/`。
- **单一事实同步**：以后每次功能变更、配置调整、更新文档或发布新版本时，**必须直接同步更新 `docs/` 静态文档站中的对应内容**（如 `docs/guide/*`、`docs/api.md`、`docs/architecture.md`、`docs/operations.md`、`docs/reference/env.md` 及 `docs/reference/changelog.md`），并在提交前运行 `cd docs && npm run build` 校验无死链与构建成功，保证推送 `main` 后 Cloudflare Pages 静态站点立即自动同步更新。
- 文档站顶栏版本号由 `docs/.vitepress/config.mjs` 自动从根目录 `VERSION` 读取，禁止在站点配置中硬编码版本号。

## 部署与安全

- 默认推荐宿主机静态二进制 + `systemd` 部署（使用 `flowmaster.service` 与受限 `flowmaster` 系统账号，支持网页远程原子自升级与主控多架构分发）；Docker 多阶段单容器部署（`--network host` 读取宿主机真实网卡并明确挂载宿主机目录至 `/data`，禁用匿名卷）作为容器化备选方案。
- `.dockerignore` 必须排除 `docs/`、`*.md` 文档、测试与本地缓存；运行时秘密严禁打入镜像。
- 会话签名密钥未显式配置有效强随机值时，自动在 `DATA_DIR/session.key` 生成 `0600` 随机密钥；Cookie `Secure` 属性按 HTTPS 或可信代理 `X-Forwarded-Proto` 动态开启，兼顾内网 HTTP 与公网 HTTPS。
- 后台告警敏感凭据（企业微信机器人 Webhook、飞书机器人 Webhook 与签名密钥、Telegram Bot Token、通用 Webhook Secret）只写不回显（API 仅返回脱敏掩码），日志拆分为 `system` 与 `alert` 独立轮转通道并自动脱敏，默认按时间倒序（最新在顶部）展示。
- 外部告警推送（企业微信 / 飞书 / Telegram / Webhook）禁止自动跟随重定向，默认拦截回环与私有内网地址（防 SSRF）。
