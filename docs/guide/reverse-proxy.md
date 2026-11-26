# 反向代理与 Cloudflare CDN 最佳实践

生产环境建议为 FlowMaster 前置 HTTPS 反向代理（宝塔 Nginx / 原生 Nginx / Caddy），以获得 TLS 加密、标准 `443` 端口访问与更优的安全隔离。

---

## 一、宝塔面板（Nginx）反向代理必看 5 点

为 `http://127.0.0.1:10089` 添加宝塔反向代理时，请务必检查以下要点：

1. **严禁勾选「开启缓存」**：避免 `/api/*` 实时流量与会话登录态被 Nginx 缓存。
2. **关闭代理缓冲并调大读写超时**：必须配置 `proxy_buffering off;` 与 `proxy_read_timeout 3600s;`，否则首页 SSE 秒级波形会卡顿，且长轮询每 60 秒断流重连。
3. **开启 `TRUST_PROXY=true`**：
   - 二进制部署：编辑 `/etc/flowmaster/flowmaster.env` 设置 `TRUST_PROXY=true`，执行 `sudo flowmaster-ctl restart`；
   - Docker 部署：附加 `-e TRUST_PROXY=true`；
   - 开启后系统自动识别 `CF-Connecting-IP` / `X-Forwarded-For` / `X-Real-IP` 作为真实客户端 IP，并按 `X-Forwarded-Proto: https` 动态为会话 Cookie 启用 `Secure`。
4. **宝塔 WAF / CC 防护白名单**：如启用了宝塔 Nginx 防火墙，请将 URL 正则 `^/api/v1/cluster/` 加入 **URL 白名单**，防止多台节点每 3 秒一次的心跳上报被误判为 CC 攻击。
5. **收敛宿主机端口（可选加固）**：反代生效后，可将 `HOST` 改为 `127.0.0.1` 仅监听本机回环，对外只开放 `443` 端口。

### 宝塔「反向代理 → 配置文件」完整推荐模板

```nginx
# PROXY-START/
location ^~ /
{
    proxy_pass http://127.0.0.1:10089;
    proxy_http_version 1.1;
    proxy_set_header Connection "";

    proxy_set_header Host $host;
    # 若前端套了 Cloudflare，自动取 CF-Connecting-IP；未套 CDN 时自动回退 $remote_addr
    set $real_client_ip $remote_addr;
    if ($http_cf_connecting_ip != "") {
        set $real_client_ip $http_cf_connecting_ip;
    }
    proxy_set_header X-Real-IP $real_client_ip;
    proxy_set_header X-Forwarded-For $real_client_ip;
    proxy_set_header X-Forwarded-Proto $scheme;

    # 关键：关闭缓冲与缓存，保证 SSE 秒级网速与 25s 反向长轮询实时透传
    proxy_buffering off;
    proxy_cache off;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;

    # 允许后台上传本地备份归档一键还原与远程节点备份回传
    client_max_body_size 128m;
}
# PROXY-END/
```

---

## 二、Caddy 反向代理示例

Caddy 原生支持自动 HTTPS 证书与 SSE 流式直通：

```txt
flow.example.com {
    reverse_proxy 127.0.0.1:10089 {
        flush_interval -1
    }
}
```

---

## 三、Cloudflare CDN 兼容性与「双域名」架构

- **单域名直接套 Cloudflare（小黄云）可用**：主从反向长轮询服务端挂起 `25s`（远低于 CF `100s` 的 `524` 超时阈值）。若开启了 Bot Fight Mode / 质询盾，请在 Cloudflare `Security -> WAF -> Custom rules` 为 URI Path 前缀 `/api/v1/cluster/` 添加一条 **Skip（跳过质询）** 规则。
- **双域名最佳实践（国内被控节点较多时强烈推荐）**：在同一个宝塔/Nginx 站点绑定两个域名：
  1. **日常浏览域名**（如 `flow.example.com`，**开启小黄云 CDN**）：浏览器日常访问走 CDN 加速并隐藏源站 IP；
  2. **节点接入直连域名**（如 `hub-direct.example.com`，**设为灰色云朵仅 DNS 解析**）：填入主控后台 **「主控公网接入地址」**，专门供被控节点上报心跳、执行远程控制与满速拉取主控分发的安装包，彻底避开晚高峰 CDN 减速与盾拦截。
