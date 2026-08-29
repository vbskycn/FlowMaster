# FlowMaster API

本文档描述 FlowMaster 当前公开 HTTP API。产品版本以根目录 `package.json` 为准；变更统计结构时应保持现有响应兼容。

## 基础约定

- 默认地址：`http://服务器IP:10089`
- 响应类型：`application/json`
- 日期格式：`YYYY-MM-DD`，并执行真实日历日期校验
- 网络接口名称：只允许字母、数字、冒号、点、下划线和连字符，且必须以字母或数字开头
- 默认限流：每个客户端每 60 秒最多 180 个 API 请求

除管理接口外，当前 API 不要求登录。公网部署应在 HTTPS 反向代理层限制整个站点的访问来源。

## 管理接口鉴权

`POST /api/cache/clear` 和 `GET /api/test/vnstat` 是管理接口。

设置 `ADMIN_TOKEN` 后，请求必须携带：

```http
X-Admin-Token: <ADMIN_TOKEN>
```

示例：

```bash
curl -X POST \
  -H 'X-Admin-Token: 请替换为实际令牌' \
  http://127.0.0.1:10089/api/cache/clear
```

未设置 `ADMIN_TOKEN` 时，无 `Origin` 请求，以及 `Origin` 中 Host（含端口）与请求 Host 一致的浏览器请求可以调用管理接口；其他 `Origin` 会被拒绝。这里不比较 URL scheme，因此不是严格的 Web 同源鉴权。公网环境必须配置令牌并限制端口。

## 端点

### 获取网络接口

```http
GET /api/interfaces
```

成功响应：

```json
{
  "interfaces": ["eth0", "docker0"]
}
```

接口来源于 `vnstat --iflist`，并逐一验证是否可以读取。若列表可读取但没有任何接口通过验证，为兼容旧客户端会回退返回 `eth0`；这不代表 eth0 一定已建库。若 vnstat 命令本身失败，返回 `503`。

### 获取周期统计

```http
GET /api/stats/:interface/:period
```

`period` 取值：

| 值 | 含义 | 服务端处理 |
| --- | --- | --- |
| `l` | 实时 | vnstat 5 秒采样；首次访问后按需持续采集 |
| `5` | 5 分钟粒度 | 保留最近约 60 分钟 |
| `h` | 小时 | 保留最近约 12 小时 |
| `d` | 日 | 保留最近约 12 天 |
| `m` | 月 | 按 vnstat 月统计输出 |
| `y` | 年 | 按 vnstat 年统计输出 |

成功响应：

```json
{
  "data": [
    "统计输出行"
  ]
}
```

实时响应还包含 Unix 毫秒时间戳：

```json
{
  "data": [
    "实时输出行"
  ],
  "timestamp": 1788012000000
}
```

`data` 保留 vnstat 的表格行结构，并进行中文标签和单位归一化，调用方不应依赖空格列宽不变。

### 获取日期范围统计

```http
GET /api/stats/:interface/range/:startDate/:endDate
```

示例：

```bash
curl \
  http://127.0.0.1:10089/api/stats/eth0/range/2026-08-01/2026-08-29
```

起止日期均包含在查询范围内。开始日期不能晚于结束日期，默认最大范围是 3660 天，可通过 `MAX_RANGE_DAYS` 调整。结果流量值统一为 GiB。

### 获取版本

```http
GET /api/version
```

```json
{
  "version": "x.y.z"
}
```

### 获取缓存状态

```http
GET /api/cache/stats
```

响应包含命中、未命中、写入、删除、拒绝次数，以及当前条目数、容量和估算内存占用。

### 清空缓存

```http
POST /api/cache/clear
```

这是管理接口。成功响应：

```json
{
  "message": "缓存已清空"
}
```

### 获取进程内存

```http
GET /api/system/memory
```

响应包含 Node.js 进程的 `rss`、`heapTotal`、`heapUsed`、`external` 和缓存估算内存。

### 获取系统状态

```http
GET /api/system/status
```

响应包含 Node.js 运行时间、内存、版本、平台和架构，以及 vnstat 可用性、缓存状态和采集时间。

### 执行 vnstat 诊断

```http
GET /api/test/vnstat
```

这是管理接口。它依次检查 vnstat 的版本、接口列表和帮助命令，并返回每项是否成功。失败详情只记录在服务端日志，对外不返回底层命令错误。

## 错误与状态码

显式校验错误通常返回：

```json
{
  "error": "可安全展示的错误信息"
}
```

未捕获的服务错误还会带 `timestamp` 和 `requestId`。客户端应以 HTTP 状态码和 `error` 字段为准，不应假设所有错误都包含相同的附加字段。

| 状态码 | 含义 |
| --- | --- |
| `400` | 接口名、周期或日期参数无效 |
| `401` | 管理令牌缺失或错误 |
| `403` | 跨站管理请求或 CORS 来源被拒绝 |
| `404` | API 路径不存在 |
| `429` | 超出请求频率限制；响应含 `Retry-After` |
| `500` | 服务内部错误 |
| `503` | vnstat 或统计数据暂时不可用 |

## CORS

`CORS_ORIGINS` 留空时，FlowMaster 不发送跨域许可头；这不会阻止非浏览器客户端直接请求服务。设置后只允许逗号分隔列表中的精确来源，例如：

```dotenv
CORS_ORIGINS=https://monitor.example.com,https://admin.example.com
```

修改配置后需要重启 `flowmaster.service`。
