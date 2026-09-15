# FlowMaster API

本文档描述 FlowMaster 当前公开 HTTP API。产品版本以根目录 `package.json` 为准；新增的结构化字段不会取代现有 `data` 响应。

## 基础约定

- 默认地址：`http://服务器IP:10089`
- 响应类型：`application/json`
- 日期格式：`YYYY-MM-DD`，并执行真实日历日期校验
- 网络接口名称：只允许字母、数字、冒号、点、下划线和连字符，且必须以字母或数字开头
- 默认限流：每个客户端每 60 秒最多 180 个 API 请求

除管理接口外，当前 API 不要求登录。公网部署应在 HTTPS 反向代理层限制整个站点的访问。

## 管理接口鉴权

`POST /api/cache/clear` 和 `GET /api/test/vnstat` 是管理接口。默认配置 `ALLOW_ANONYMOUS_ADMIN=false` 会拒绝未鉴权的调用。

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

鉴权规则：

| `ADMIN_TOKEN` | `ALLOW_ANONYMOUS_ADMIN` | 结果 |
| --- | --- | --- |
| 非空 | 任意 | 必须提供完全匹配的 `X-Admin-Token`；缺失或错误返回 `401` |
| 空 | `false`（默认） | 所有管理请求返回 `403` |
| 空 | `true` | 只兼容无 `Origin` 或 `Origin` Host（含端口）与请求 Host 一致的调用；其他请求返回 `403` |

`ALLOW_ANONYMOUS_ADMIN=true` 只用于受信任内网的旧调用方兼容，不是完整的身份鉴权。其 Host 检查不比较 URL scheme；公网环境应保持为 `false`、设置 `ADMIN_TOKEN`，并在反向代理层保护整个站点。

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

服务优先通过 `vnstat --dbiflist 1` 读取已建库的接口。旧版 vnstat 不支持该命令时，才会从 `vnstat --iflist` 取得候选项，并用 `--oneline` 逐一验证；回退验证同样受全局 vnstat 并发上限约束。

没有已建库接口时返回空数组 `[]`，服务不会伪造 `eth0`。命令执行失败时返回 `503`。

### 获取周期统计

```http
GET /api/stats/:interface/:period
```

`period` 取值：

| 值 | 含义 | 服务端处理 |
| --- | --- | --- |
| `l` | 实时 | 默认每 5 秒采样；首次访问后按需持续采集 |
| `5` | 5 分钟粒度 | 保留最近约 60 分钟 |
| `h` | 小时 | 保留最近约 12 小时 |
| `d` | 日 | 保留最近约 12 天 |
| `m` | 月 | 按 vnstat 月统计输出 |
| `y` | 年 | 按 vnstat 年统计输出 |

除 `l` 以外的周期统计成功响应：

```json
{
  "data": [
    "统计输出行"
  ],
  "series": {
    "unit": "MiB",
    "points": [
      {
        "label": "2026-09-15",
        "rx": 5,
        "tx": 3,
        "total": 8
      }
    ]
  }
}
```

`data` 是为现有调用方保留的人类可读表格行，并进行中文标签和显示单位归一；调用方不应依赖空格列宽不变。`series` 是为机器读取增加的兼容字段：

- `unit` 固定为 `MiB`。
- `points` 可为空数组；每项包含时间标签 `label` 以及数值型 `rx`、`tx`、`total`。
- 新客户端应优先使用 `series`，避免解析显示文本或损失小流量精度。

`period=l` 的实时响应不含 `series`，其结构为：

```json
{
  "data": [
    "实时输出行"
  ],
  "timestamp": 1788012000000,
  "stale": false,
  "ageMs": 23
}
```

`timestamp` 是样本采集时的 Unix 毫秒时间戳，`ageMs` 是响应时的样本年龄。`stale=false` 表示样本仍在新鲜期内；采集失败或进入退避时，如果存在旧样本，服务会以 `stale=true` 显式返回。没有可回退的样本时返回 `503`。

实时采集在接口首次访问时按需启动；同一接口的并发请求共用同一次正在执行的采集。具体采样、空闲回收和退避边界见[运行配置](operations.md#运行配置)。

### 获取日期范围统计

```http
GET /api/stats/:interface/range/:startDate/:endDate
```

示例：

```bash
curl \
  http://127.0.0.1:10089/api/stats/eth0/range/2026-08-01/2026-08-29
```

起止日期均包含在查询范围内。开始日期不能晚于结束日期，默认最大范围是 3660 天，可通过 `MAX_RANGE_DAYS` 调整。响应与非实时周期统计一样包含 `data` 和 `series`：`data` 的显示值归一为 GiB，`series` 仍使用 MiB 数值以保留精度。

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
| `401` | 已配置管理令牌，但请求中的令牌缺失或错误 |
| `403` | 匿名管理被禁用、跨站管理请求或 CORS 来源被拒绝 |
| `404` | API 路径不存在 |
| `413` | JSON 请求体超过 16 KiB |
| `429` | 超出请求频率限制；响应含 `Retry-After` |
| `500` | 服务内部错误 |
| `503` | vnstat、执行队列或统计数据暂时不可用 |

## CORS

`CORS_ORIGINS` 留空时，FlowMaster 不发送跨域许可头；这不会阻止非浏览器客户端直接请求服务。设置后只允许逗号分隔列表中的精确来源，例如：

```dotenv
CORS_ORIGINS=https://monitor.example.com,https://admin.example.com
```

修改配置后需要重启 `flowmaster.service`。
