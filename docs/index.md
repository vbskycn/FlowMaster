---
layout: home

hero:
  name: FlowMaster
  text: 轻量级 Linux 流量监控与多机管理中枢
  tagline: Go 静态单二进制 + 内置 SQLite + Vue 3 现代界面，常驻内存仅 12~18 MB，一主多从集中纳管、主控多架构直发安装、零 RCE 白名单批量运维。
  image:
    src: /favicon.svg
    alt: FlowMaster
  actions:
    - theme: brand
      text: 快速开始 →
      link: /guide/getting-started
    - theme: alt
      text: 在线 Demo ↗
      link: https://flowmaster.168668518.com/
    - theme: alt
      text: 多机集群指南
      link: /guide/cluster
    - theme: alt
      text: GitHub 仓库
      link: https://github.com/vbskycn/FlowMaster

features:
  - icon: ⚡
    title: 极致轻量 · 零运行时依赖
    details: 纯 Go 静态编译单二进制（默认推荐 systemd 部署），直接读取 Linux /proc/net/dev 秒级推送实时网速与 CPU/内存/硬盘负载，兼容混合读取或一键导入系统 vnstat 历史数据。
  - icon: 🌐
    title: 一主多从 · 主控多架构直发
    details: 在设置中显式开启「主控模式」即可变身多机管理中枢。主控自动缓存 linux/amd64 与 linux/arm64 双架构安装包，国内被控节点免连 GitHub 直接从主控满速安装上线。
  - icon: 🛡️
    title: 零 RCE 白名单批量管控
    details: 严格拒绝任意 Shell 命令执行，仅开放白名单受控动作：批量改分组、批量下发配额、批量平滑重启、批量原子自升级、免 SSH 查看脱敏日志与加密通道下载远程 SQLite 备份。
  - icon: 🔔
    title: 四通道防 SSRF 智能告警
    details: 原生支持企业微信机器人、飞书自定义机器人（支持签名校验，国内直连首选）、Telegram Bot 与通用 JSON Webhook，支持主控统一托管全集群掉线、流量超额与硬盘/内存高水位预警。
  - icon: 💾
    title: 在线一致性快照与灾难还原
    details: 后台内置 SQLite VACUUM INTO 在线快照创建、本地下载、快照列表一键还原与上传归档还原，自动校验完整性并留存 pre-restore 保护快照，失败自动回滚。
  - icon: 🔒
    title: 访客隐私脱敏与双栈防火墙
    details: 未登录访客自动脱敏服务器 IP、MAC、主机名与独立面板端口并隐藏管理入口；默认 IPv4/IPv6 双栈监听，脚本自动放行 UFW、Firewalld 及甲骨文云 iptables 规则。
---

## 1 分钟快速部署（默认推荐静态二进制）

```bash
curl -fsSL --connect-timeout 5 https://raw.githubusercontent.com/vbskycn/FlowMaster/main/install.sh -o install.sh || \
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/vbskycn/FlowMaster/main/install.sh -o install.sh
chmod +x install.sh
sudo ./install.sh binary
```

部署完成后访问 `http://服务器IP:10089`（支持 IPv4 与 IPv6），点击右上角 **「🔒 管理登录」** 设置管理员密码即可开始使用。

## 在线演示与界面预览

- **在线 Demo（访客脱敏只读预览）**：[https://flowmaster.168668518.com/](https://flowmaster.168668518.com/)

### 多机总览与横向对比墙

![FlowMaster 多机总览界面](/images/flowmaster-fleet.jpg)

## 开源与社区

- 代码仓库：[GitHub (`vbskycn/FlowMaster`)](https://github.com/vbskycn/FlowMaster)
- 交流社区：[LINUX DO 社区](https://linux.do)（感谢 LINUX DO 社区与各位佬友的支持与建议）
