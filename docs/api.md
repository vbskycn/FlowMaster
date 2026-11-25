# FlowMaster HTTP API 文档

FlowMaster 同时提供面向现代前端与自动化集成的 `/api/v1/*` 接口，以及完整保留向后兼容的旧版 `/api/*` 接口。产品版本统一由根目录 `VERSION` 定义。

## 鉴权与安全机制

1. **前台查询接口**（`/api/v1/interfaces`、`/api/v1/stats/*`、`/api/v1/stream/realtime`、`/api/v1/quota/status` 及旧版查询接口）：
   - 默认免登录可直接访问；
   - 若管理员在后台开启了 **「全站密码保护 (`requireLoginForView=true`)」**，则未认证请求返回 `401`。
2. **管理后台接口**（`/api/v1/admin/*`、`/api/v1/auth/password`）：
   - 支持两种认证方式：
     - **Web 会话登录**：调用 `POST /api/v1/auth/login` 成功后由服务端下发 `HttpOnly` 签名会话 Cookie（`fm_session`），写请求需同源 `Origin` 或携带 `X-Requested-With: FlowMaster` 请求头；
     - **API 令牌**：配置环境变量 `ADMIN_TOKEN` 后，在请求头携带 `X-Admin-Token: <ADMIN_TOKEN>`。
   - 登录接口具备 IP 防爆破保护：5 分钟内连续失败 5 次自动锁定 15 分钟并返回 `429` 及 `Retry-After`。

---

## 一、现代 `/api/v1/*` 端点

### 1. 初始化引导与认证

| 方法 | 路径 | 说明 |
| :--- | :--- | :--- |
| `GET` | `/api/v1/bootstrap` | 获取系统名称、版本号、站点标题、数据源模式、登录态与是否需首次设密 |
| `POST` | `/api/v1/auth/setup` | 首次初始化管理员密码（仅当未设置密码时可用，成功后自动登录） |
| `POST` | `/api/v1/auth/login` | 管理员密码登录 |
| `POST` | `/api/v1/auth/logout` | 清除会话 Cookie 退出登录 |
| `POST` | `/api/v1/auth/password` | 修改管理员密码（需已认证） |

### 2. 流量监控与配额查询

| 方法 | 路径 | 说明 |
| :--- | :--- | :--- |
| `GET` | `/api/v1/interfaces` | 获取前台可见网卡列表及链路速率、状态、IPv4、MAC 元数据 |
| `GET` | `/api/v1/realtime/{interface}` | 获取指定网卡最近 60 个秒级实时样本与最新速率 |
| `GET` | `/api/v1/stream/realtime?interface=eth0` | **SSE 实时推送流**：建立后立即下发 `init` 历史帧，随后每秒推送 `sample` 帧 |
| `GET` | `/api/v1/stats/{interface}/{period}` | 获取周期统计（`period` 支持 `5`、`h`、`d`、`m`、`y`；可选查询参数 `source`、`limit`） |
| `GET` | `/api/v1/stats/{interface}/range/{startDate}/{endDate}` | 获取闭区间按日流量统计（日期格式 `YYYY-MM-DD`） |
| `GET` | `/api/v1/quota/status` | 获取当前月度计费周期起止日、已用字节、剩余额度、百分比与周期末预测值 |

### 3. 管理后台接口（需管理员权限）

| 方法 | 路径 | 说明 |
| :--- | :--- | :--- |
| `GET` | `/api/v1/admin/overview` | 获取 Go 进程内存、协程数、SQLite 体积、运行时长及 `vnstat` 可用性 |
| `GET` | `/api/v1/admin/settings` | 读取系统参数、月度配额规则与**脱敏后**的告警配置（绝不回显明文密钥） |
| `PUT` | `/api/v1/admin/settings` | 更新系统设置与月度流量配额规则 |
| `PUT` | `/api/v1/admin/alerts` | 更新 Webhook / Telegram 告警规则（密钥留空保持原值不变） |
| `POST` | `/api/v1/admin/alerts/test` | 发送一次告警连通性测试消息 |
| `GET` | `/api/v1/admin/interfaces` | 获取包含隐藏虚拟接口在内的完整网卡列表 |
| `PUT` | `/api/v1/admin/interfaces/{name}` | 设置指定网卡的备注别名（`alias`）与显隐状态（`visible`） |
| `GET` | `/api/v1/admin/backups` | 按时间倒序获取历史备份快照列表 |
| `POST` | `/api/v1/admin/backups` | 在线创建一份 SQLite `VACUUM INTO` 一致性备份归档 |
| `GET` | `/api/v1/admin/backups/{name}/download` | 下载指定 `.tar.gz` 备份包到本地 |
| `POST` | `/api/v1/admin/backups/{name}/restore` | 从已有快照一键还原（需 `{"confirm": true}`，自动校验并留存保护快照） |
| `POST` | `/api/v1/admin/backups/upload-restore` | 上传本地 `.tar.gz` 备份文件一键还原（`multipart/form-data`，`confirm=true`） |
| `DELETE` | `/api/v1/admin/backups/{name}` | 删除指定历史快照 |
| `GET` | `/api/v1/admin/config/export` | 导出非敏感配置 JSON |
| `POST` | `/api/v1/admin/config/import` | 导入配置 JSON |
| `POST` | `/api/v1/admin/vnstat/import` | 从系统 `vnstat --json` 幂等合并历史流量至内置 SQLite |
| `POST` | `/api/v1/admin/data/reset` | 先创建保护备份后重置内置 SQLite 流量记录（需 `{"confirm": "RESET"}`） |
| `GET` | `/api/v1/admin/logs` | 查询脱敏日志（`channel=system\|alert`、`level`、`q`、`limit`，严格倒序最新在顶） |

---

## 二、旧版兼容 `/api/*` 端点

为保证已有探针或脚本平滑升级，以下端点完全保留原有路径与字段结构：

- `GET /api/version` -> `{"version": "2.1.0"}`

---

## 三、多机集群管理 `/api/v1/cluster/*` 端点

| 方法 | 路径 | 权限 | 说明 |
| :--- | :--- | :--- | :--- |
| `GET` | `/api/v1/cluster/nodes` | 视图访问 | 获取本机与全部受控节点的在线状态、实时网速、今日/本月流量、配额进度与版本汇总 |
| `GET` | `/api/v1/cluster/nodes/{id}/interfaces` | 视图访问 | 获取指定远程节点的网卡与 IPv4/IPv6 元数据 |
| `GET` | `/api/v1/cluster/nodes/{id}/stats/{interface}/{period}` | 视图访问 | 通过反向长轮询隧道实时查询指定节点的周期统计 |
| `GET` | `/api/v1/cluster/nodes/{id}/stats/{interface}/range/{start}/{end}` | 视图访问 | 查询指定节点的日期范围流量统计 |
| `POST` | `/api/v1/admin/cluster/nodes` | 管理员 | 注册新节点并生成带专属密钥与国内自动代理的一键接入命令 |
| `PUT` | `/api/v1/admin/cluster/nodes/{id}` | 管理员 | 修改节点名称、分组标签与备注 |
| `DELETE` | `/api/v1/admin/cluster/nodes/{id}` | 管理员 | 从主控移除节点 |
| `GET/PUT` | `/api/v1/admin/cluster/nodes/{id}/config` | 管理员 | 远程读取或下发保存指定节点的月度流量包配额与引擎设置 |
| `POST` | `/api/v1/admin/cluster/upgrade` | 管理员 | 向勾选的一台或多台节点批量下发受控原子自升级指令 |
- `GET /api/interfaces` -> `{"interfaces": ["eth0"]}`
- `GET /api/stats/{interface}/{period}`（`period`: `l`, `5`, `h`, `d`, `m`, `y`，保留 `data` 文本行与 MiB 精度 `series`）
- `GET /api/stats/{interface}/range/{startDate}/{endDate}`
- `GET /api/cache/stats` & `POST /api/cache/clear`
- `GET /api/system/memory`、`GET /api/system/status`、`GET /api/test/vnstat`
