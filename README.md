# FlowMaster - 专业的网络流量实时监控系统

[![Version](https://img.shields.io/badge/version-1.1.19-blue.svg)](https://github.com/vbskycn/FlowMaster)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Node.js](https://img.shields.io/badge/node.js-18+-green.svg)](https://nodejs.org/)
[![Vue.js](https://img.shields.io/badge/vue.js-3.5.42-green.svg)](https://vuejs.org/)

![FlowMaster](assets/FlowMaster.jpg)

## 📋 目录

- [项目介绍](#项目介绍)
- [✨ 核心特性](#-核心特性)
- [🛠️ 技术架构](#️-技术架构)
- [📦 快速开始](#-快速开始)
- [🔧 配置说明](#-配置说明)
- [📚 API 文档](#-api-文档)
- [🚀 高级功能](#-高级功能)
- [🔍 故障排除](#-故障排除)
- [⚡ 性能优化](#-性能优化)
- [👨‍💻 开发指南](#-开发指南)
- [🤝 贡献指南](#-贡献指南)
- [📄 开源协议](#-开源协议)

## 📝 项目介绍

FlowMaster 是一个基于 **vnstat** 的专业网络流量监控系统，采用现代化的 Web 技术栈构建。系统提供实时流量监控、多维度数据分析、智能缓存管理、性能监控等高级功能，让网络流量监控变得简单而强大。

### 🎯 设计理念

- **高性能**: 智能缓存系统，LRU算法优化，内存使用监控
- **高可用**: 完善的错误处理，自动诊断，降级机制
- **易扩展**: 模块化设计，RESTful API，支持多网卡
- **用户友好**: 响应式界面，深色主题，实时更新

## ✨ 核心特性

### 🚀 实时监控
- **实时流量图表**: 基于Chart.js的动态图表，支持实时数据更新
- **速度监控**: 接收/发送速度实时显示（kb/秒）
- **数据包统计**: 实时数据包传输统计
- **自动刷新**: 可配置的自动刷新间隔（1秒-60秒）

### 📊 多维度统计
- **分钟统计**: 最近5分钟流量数据，30秒缓存
- **小时统计**: 最近12小时数据，1分钟缓存
- **日统计**: 最近12天数据，2分钟缓存
- **月统计**: 最近30天数据，5分钟缓存
- **年统计**: 年度数据，10分钟缓存

### 🌐 智能网卡管理
- **自动检测**: 自动发现和验证可用网络接口
- **优先级排序**: 物理网卡优先，虚拟接口靠后
- **多接口支持**: 支持eth、ens、enp、wlan、bond、docker等接口
- **接口验证**: 自动验证接口有效性

### 💾 智能缓存系统
- **LRU缓存**: 最近最少使用算法
- **内存监控**: 实时监控缓存内存使用
- **缓存统计**: 命中率、缓存条目、内存使用统计
- **自动清理**: 定期清理过期缓存
- **可配置**: 支持自定义缓存大小和内存限制

### 🔍 系统监控
- **性能监控**: 响应时间、请求计数、平均响应时间
- **内存监控**: RSS、堆内存、外部内存使用
- **服务器状态**: 运行时间、平台信息、vnstat状态
- **诊断功能**: 自动诊断连接问题和vnstat配置

### 🎨 用户界面
- **响应式设计**: 完美适配桌面和移动设备
- **深色主题**: 支持深色/浅色主题切换
- **实时图表**: 基于Chart.js的交互式图表
- **数据表格**: 格式化的数据展示
- **加载状态**: 优雅的加载动画

### 📅 高级查询
- **日期范围查询**: 自定义时间段数据查询
- **单位统一**: 自动单位转换和归一化
- **数据过滤**: 智能过滤无效数据
- **图表渲染**: 查询结果图表展示

## 🛠️ 技术架构

### 后端技术栈
| 组件 | 技术 | 版本 | 说明 |
|------|------|------|------|
| **运行时** | Node.js | 18.0.0+ | JavaScript运行时环境 |
| **Web框架** | Express.js | 5.2.1 | 轻量级Web应用框架 |
| **跨域处理** | CORS | 2.8.6 | 跨域资源共享 |
| **进程管理** | systemd | 系统自带 | 服务守护、日志和开机启动 |
| **监控工具** | vnstat | 2.0.0+ | 网络流量监控工具 |

### 前端技术栈
| 组件 | 技术 | 版本 | 说明 |
|------|------|------|------|
| **框架** | Vue.js | 3.5.42 | 渐进式JavaScript框架，本地加载 |
| **UI框架** | Bootstrap | 5.3.8 | 响应式CSS框架，本地加载 |
| **图表库** | Chart.js | 4.5.1 | 交互式图表库，本地加载 |
| **HTTP客户端** | Axios | 1.20.0 | Promise-based HTTP客户端，本地加载 |
| **图标库** | Bootstrap Icons | 1.13.1 | 图标字体库，本地加载 |

### 系统架构
```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   前端界面      │    │   API网关       │    │   vnstat工具    │
│   (Vue.js)      │◄──►│   (Express)     │◄──►│   (系统命令)    │
└─────────────────┘    └─────────────────┘    └─────────────────┘
                              │
                              ▼
                       ┌─────────────────┐
                       │   缓存系统      │
                       │   (LRU Cache)   │
                       └─────────────────┘
```

## 📦 快速开始

### 环境要求

| 组件 | 最低版本 | 推荐版本 | 说明 |
|------|----------|----------|------|
| **Node.js** | 18.0.0 | 22.0.0+ | JavaScript运行时 |
| **vnstat** | 2.0.0 | 2.10+ | 网络监控工具 |
| **npm** | 6.0.0 | 8.0.0+ | 包管理器 |
| **操作系统** | Linux | Ubuntu 20.04+ | 支持vnstat的系统 |

### 🚀 一键部署

**国际网络：**
```bash
curl -o install.sh https://raw.githubusercontent.com/vbskycn/FlowMaster/main/install.sh && chmod +x install.sh && sudo ./install.sh
```

**国内网络：**
```bash
curl -o install.sh https://gh-proxy.com/https://raw.githubusercontent.com/vbskycn/FlowMaster/main/install.sh && chmod +x install.sh && sudo ./install.sh
```

### 📋 服务管理命令

```bash
# 启动服务
flowmaster start

# 停止服务
flowmaster stop

# 重启服务
flowmaster restart

# 查看状态
flowmaster status

# 查看日志
flowmaster logs

# 卸载服务（在安装脚本菜单选择卸载）
sudo ./install.sh
```

卸载只归档 FlowMaster 程序文件，不会删除 `/var/lib/vnstat`。如需备份或恢复流量历史数据：

```bash
sudo ./backup_vnstat.sh
```

备份默认保存在 `/var/backups/flowmaster/vnstat`，包含文件校验和、vnstat 导出和环境元数据。恢复前会再次校验，并将当前数据保留为带时间戳的回滚目录。

### 🌐 访问系统

安装完成后，通过浏览器访问：`http://服务器IP:10089`

> ⚠️ **注意**: 公网部署应通过 HTTPS 反向代理访问，并限制 10089 端口来源；需要管理接口保护时请设置 `ADMIN_TOKEN`。

## 🔧 配置说明

### 环境变量配置

复制 `.env.example` 为 `.env`，或直接设置进程环境变量。服务会在启动时加载项目目录下的 `.env`：

```bash
# 服务器配置
HOST=0.0.0.0                       # 监听地址
PORT=10089                          # 服务端口
NODE_ENV=production                 # 运行环境

# 缓存配置
CACHE_MAX_SIZE=100                  # 最大缓存条目数
CACHE_MAX_MEMORY_MB=50              # 最大缓存内存(MB)
CACHE_CLEANUP_INTERVAL=60000        # 缓存清理间隔(ms)
MEMORY_MONITOR_INTERVAL=300000      # 内存监控间隔(ms)

# 安全配置
CORS_ORIGINS=                       # 逗号分隔的跨域来源，留空表示不开放跨域
ADMIN_TOKEN=                        # 可选；保护缓存清理和vnstat诊断接口
RATE_LIMIT_MAX=180                  # 每个客户端每分钟API请求上限
RATE_LIMIT_MAX_CLIENTS=10000        # 限流客户端桶数量上限
TRUST_PROXY=false                   # 仅在可信反向代理后启用
```

### systemd 服务

一键安装会创建并启用 `flowmaster.service`。服务异常退出时自动重启，日志统一进入 systemd journal：

```bash
systemctl status flowmaster.service --no-pager
journalctl -u flowmaster.service -f
```

### 手动安装步骤

#### 1. 安装依赖

```bash
# Ubuntu/Debian
sudo apt-get update
sudo apt-get install vnstat

# CentOS/RHEL
sudo yum install vnstat

# 启动vnstat服务
sudo systemctl enable vnstat
sudo systemctl start vnstat
```

#### 2. 安装 Node.js

```bash
# 安装 Node.js 18 或更高版本
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.0/install.sh | bash
source ~/.bashrc
nvm install 18
nvm use 18
```

#### 3. 部署应用

```bash
# 克隆项目
git clone https://github.com/vbskycn/FlowMaster.git
cd FlowMaster

# 按锁文件安装依赖
npm ci

# 前台调试启动；生产部署请使用一键安装器生成的 systemd 服务
node server.js
```

#### 4. systemd 管理命令

```bash
# 查看服务状态
systemctl status flowmaster.service --no-pager

# 查看服务日志
journalctl -u flowmaster.service -f

# 重启服务
systemctl restart flowmaster.service

# 停止服务
systemctl stop flowmaster.service

# 启动服务
systemctl start flowmaster.service
```

默认访问地址：`http://localhost:10089`

#### 5. 更新脚本

##### 一键自动更新

- **国际网络用户**（可直接访问 GitHub）：

```bash
curl -o install.sh https://raw.githubusercontent.com/vbskycn/FlowMaster/main/install.sh && chmod +x install.sh && sudo ./install.sh
```

- **国内网络用户**（推荐使用加速代理）：

```bash
curl -o install.sh https://gh-proxy.com/https://raw.githubusercontent.com/vbskycn/FlowMaster/main/install.sh && chmod +x install.sh && sudo ./install.sh
```

- 运行后，脚本会识别已有安装；请选择 **1（安全更新/重新部署）**。新版本会先安装依赖并完成冒烟测试，验证通过后才替换现有版本，失败时保留旧服务。
- PM2 健康时，安装器只删除名为 `flowmaster` 的旧应用并迁移到 systemd，不会重启或删除其他 PM2 应用。
- 如果大量僵尸进程直接归属于无响应的 root PM2 daemon，安装器会先校验独立的 `pm2-*.service`、主备保存清单和 cgroup，再列出将短暂重启的已保存应用。输入完整的 `RECOVER-PM2` 后即可原地恢复，不需要重启服务器；恢复前备份写入 `/var/backups/flowmaster/pm2-recovery-*`。
- 自动化部署只有显式设置 `FLOWMASTER_RECOVER_UNRESPONSIVE_PM2=1` 才允许重启 PM2 unit。PM2 未由独立 systemd unit 管理、保存清单不可信或有效停止边界被其他配置覆盖时，安装器会保持现状并安全退出，避免产生孤儿或重复应用。

##### 手动更新

如果你是手动用源码部署的：

```bash
cd FlowMaster #进入脚本目录
git pull #更新仓库
npm ci
sudo systemctl restart flowmaster.service
```

### 🔧 配置说明

编辑应用目录中的 `.env` 后重启服务：

```bash
sudo cp .env.example /opt/flowmaster/.env
sudo editor /opt/flowmaster/.env
sudo systemctl restart flowmaster.service
```

## 📖 使用说明

1. 系统启动后，自动检测可用网卡
2. 在界面上选择要监控的网卡
3. 查看实时流量和历史统计数据
4. 可开启自动刷新功能，实时更新数据

## 📚 API 文档

### 基础信息

- **基础URL**: `http://localhost:10089`
- **内容类型**: `application/json`
- **字符编码**: `UTF-8`

### 接口列表

#### 1. 获取网络接口列表

```http
GET /api/interfaces
```

**响应示例：**
```json
{
  "interfaces": ["eth0", "wlan0", "docker0"]
}
```

#### 2. 获取统计数据

```http
GET /api/stats/{interface}/{period}
```

**参数说明：**
- `interface`: 网络接口名称 (如: eth0)
- `period`: 统计周期
  - `l`: 实时数据
  - `5`: 5分钟统计
  - `h`: 小时统计
  - `d`: 日统计
  - `m`: 月统计
  - `y`: 年统计

**响应示例：**
```json
{
  "data": [
    "eth0 / 5 minute",
    "时间 | 接收(MiB) | 发送(MiB) | 总计(MiB) | 平均速率",
    "---",
    "14:55 | 12.34 | 5.67 | 18.01 | 2.40 kb/s"
  ]
}
```

#### 3. 日期范围查询

```http
GET /api/stats/{interface}/range/{startDate}/{endDate}
```

**参数说明：**
- `interface`: 网络接口名称
- `startDate`: 开始日期 (YYYY-MM-DD)
- `endDate`: 结束日期 (YYYY-MM-DD)

#### 4. 获取版本信息

```http
GET /api/version
```

**响应示例：**
```json
{
  "version": "1.1.19"
}
```

#### 5. 缓存管理

```http
# 获取缓存统计
GET /api/cache/stats

# 清空缓存
POST /api/cache/clear
```

#### 6. 系统监控

```http
# 获取内存使用
GET /api/system/memory

# 获取服务器状态
GET /api/system/status

# 测试vnstat
GET /api/test/vnstat
```

### 错误处理

所有API都遵循统一的错误响应格式：

```json
{
  "error": "错误描述",
  "timestamp": "2024-01-01T00:00:00.000Z",
  "requestId": "abc123def"
}
```

**常见HTTP状态码：**
- `200`: 请求成功
- `400`: 请求参数错误
- `500`: 服务器内部错误
- `503`: 服务暂时不可用
- `504`: 请求超时

## 🚀 高级功能

### 智能缓存系统

FlowMaster 实现了高效的缓存管理系统：

- **LRU算法**: 最近最少使用策略
- **内存监控**: 实时监控缓存内存使用
- **自动清理**: 定期清理过期缓存
- **统计信息**: 缓存命中率、条目数量等

### 性能监控

系统内置性能监控功能：

- **响应时间**: 实时监控API响应时间
- **请求统计**: 请求次数、平均响应时间
- **内存使用**: 详细的内存使用情况
- **缓存性能**: 缓存命中率和效率

### 诊断系统

自动诊断功能帮助快速定位问题：

- **连接诊断**: 检查服务器连接状态
- **vnstat测试**: 验证vnstat命令可用性
- **配置检查**: 检查系统配置是否正确
- **建议生成**: 根据诊断结果提供解决建议

### 图表优化

前端图表系统经过深度优化：

- **实例池管理**: Chart.js实例复用
- **防抖节流**: 避免频繁更新
- **批量更新**: 批量处理图表更新
- **内存清理**: 自动清理无用实例

## 🔍 故障排除

### 常见问题

#### 1. vnstat命令不可用

**症状**: 页面显示"vnstat命令不可用"错误

**解决方案**:
```bash
# 检查vnstat是否安装
which vnstat

# 安装vnstat
sudo apt-get install vnstat  # Ubuntu/Debian
sudo yum install vnstat      # CentOS/RHEL

# 启动vnstat服务
sudo systemctl enable vnstat
sudo systemctl start vnstat
```

#### 2. 端口被占用

**症状**: 启动时显示"端口已被占用"

**解决方案**:
```bash
# 查看端口占用
netstat -tlnp | grep 10089

# 修改端口
sudo editor /opt/flowmaster/.env
sudo systemctl restart flowmaster.service
```

#### 3. 缓存问题

**症状**: 数据更新缓慢或显示异常

**解决方案**:
```bash
# 清空缓存
curl -X POST http://localhost:10089/api/cache/clear

# 重启服务
sudo systemctl restart flowmaster.service
```

#### 4. 内存使用过高

**症状**: 系统内存使用持续增长

**解决方案**:
```bash
# 调整缓存配置
export CACHE_MAX_MEMORY_MB=25
export CACHE_MAX_SIZE=50
sudo systemctl restart flowmaster.service
```

#### 5. 更新时 PM2 无响应并出现大量 `ps` 僵尸

**症状**：安装停在旧 PM2 检查，`top` 显示 PM2 daemon 高 CPU，并出现大量状态为 `Z` 的 `ps` 进程。

**处理方式**：重新运行最新版安装器。安装器确认僵尸进程直接属于 PM2 且能够安全定位独立的 root `pm2-*.service` 后，会显示已保存应用列表；核对无误后输入：

```text
RECOVER-PM2
```

这会短暂重启该 PM2 unit 管理的已保存应用，但不会重启整台服务器。恢复过程会验证新 daemon 的应用集合、运行状态和 `PIDUSAGE_USE_PS=false`，随后只把旧 FlowMaster 迁移到 `flowmaster.service`。

如果安装器提示 PM2 不在独立的 systemd unit 中，它会拒绝直接杀死 daemon。可先查看其归属以便排查：

```bash
pm2_pid="$(sudo cat /root/.pm2/pm2.pid)"
sudo systemctl status "$pm2_pid" --no-pager
sudo cat "/proc/$pm2_pid/cgroup"
```

不要直接 `kill -9` PM2 daemon：Fork 应用可能成为孤儿，之后 `pm2 resurrect` 可能再启动一份重复实例。

### 日志分析

查看详细日志信息：

```bash
# 查看最近100行日志
journalctl -u flowmaster.service -n 100 --no-pager

# 持续查看实时日志
journalctl -u flowmaster.service -f
```

### 性能诊断

使用内置诊断功能：

1. 访问系统页面
2. 点击"诊断问题"按钮
3. 查看诊断结果和建议

## ⚡ 性能优化

### 系统优化建议

#### 1. 缓存配置优化

```bash
# 生产环境推荐配置
CACHE_MAX_SIZE=200              # 增加缓存条目
CACHE_MAX_MEMORY_MB=100         # 增加缓存内存
CACHE_CLEANUP_INTERVAL=300000   # 5分钟清理一次
```

#### 2. 网络接口优化

- 优先监控主要网络接口
- 避免监控虚拟接口（如docker、veth）
- 定期检查接口状态

#### 3. 系统资源优化

```bash
# 增加文件描述符限制
echo "* soft nofile 65536" >> /etc/security/limits.conf
echo "* hard nofile 65536" >> /etc/security/limits.conf

# 优化内核参数
echo "net.core.somaxconn = 65535" >> /etc/sysctl.conf
sysctl -p
```

### 监控指标

关键性能指标：

- **响应时间**: < 100ms (正常), < 500ms (警告)
- **缓存命中率**: > 80% (优秀), > 60% (良好)
- **内存使用**: < 100MB (正常), < 200MB (警告)
- **CPU使用率**: < 10% (正常), < 30% (警告)

## 👨‍💻 开发指南

### 本地开发环境

#### 1. 克隆项目

```bash
git clone https://github.com/vbskycn/FlowMaster.git
cd FlowMaster
```

#### 2. 安装依赖

```bash
npm ci
```

#### 3. 启动开发服务器

```bash
# 开发模式启动
npm run dev

# 或直接启动
node server.js
```

#### 4. 访问开发环境

打开浏览器访问：`http://localhost:10089`

### 项目结构

```
FlowMaster/
├── .github/workflows/ci.yml # 持续集成
├── AGENTS.md             # 开发协作与安全边界
├── CHANGELOG.md          # 未发布及正式版本记录
├── server.js              # 主服务器文件
├── package.json           # 项目配置
├── package-lock.json      # 可复现依赖锁
├── README.md             # 项目文档
├── .env.example          # 环境变量示例
├── install.sh            # 安装脚本
├── backup_vnstat.sh      # vnstat备份恢复脚本
├── scripts/              # 静态检查脚本
├── test/                 # 自动化测试
├── public/               # 静态资源
│   ├── index.html        # 主页面
│   ├── css/              # 样式文件
│   │   ├── main.css      # 主样式
│   │   └── dark-theme.css # 深色主题
│   └── favicon.png       # 网站图标
└── assets/               # 资源文件
    └── FlowMaster1.1.3.jpg # 项目截图
```

### 代码规范

- 使用ES6+语法
- 遵循JavaScript标准规范
- 添加适当的注释
- 使用有意义的变量名

### 测试

```bash
# 安装锁定依赖并执行语法检查、单元测试和API测试
npm ci
npm run test:ci

# 检查全部依赖安全公告
npm audit --audit-level=high

# Linux安装与备份脚本语法
bash -n install.sh
bash -n backup_vnstat.sh

# Linux安装器超时、端口占用和进程回收回归
bash test/install-linux.test.sh

# Debian/systemd 真实 PM2 5.4.3 故障注入（需要 root 和网络）
sudo bash test/pm2-recovery-systemd.test.sh
```

真实 vnstat 联调仍需在 Linux 主机执行，并验证接口发现、实时采样、周期统计、日期查询和优雅关闭。

## 🤝 贡献指南

我们欢迎所有形式的贡献！

### 贡献方式

1. **报告问题**: 提交Issue报告bug或建议新功能
2. **代码贡献**: 提交Pull Request改进代码
3. **文档改进**: 完善文档和翻译
4. **测试反馈**: 测试新功能并提供反馈

### 开发流程

1. Fork 本项目
2. 创建功能分支：`git checkout -b feature/AmazingFeature`
3. 提交更改：`git commit -m 'Add some AmazingFeature'`
4. 推送分支：`git push origin feature/AmazingFeature`
5. 提交 Pull Request

### 提交规范

提交信息格式：
```
type(scope): description

[optional body]

[optional footer]
```

**类型说明**:
- `feat`: 新功能
- `fix`: 修复bug
- `docs`: 文档更新
- `style`: 代码格式调整
- `refactor`: 代码重构
- `test`: 测试相关
- `chore`: 构建过程或辅助工具的变动

### 代码审查

所有Pull Request都需要通过代码审查：

- 代码质量检查
- 功能测试验证
- 文档更新确认
- 性能影响评估

## 📄 开源协议

本项目采用 [MIT 协议](LICENSE) 开源。

### 协议要点

- ✅ 允许商业使用
- ✅ 允许修改源码
- ✅ 允许分发
- ✅ 允许私人使用
- ❌ 不提供担保

## 📞 联系方式

### 项目维护者

**vbskycn**

- GitHub: [@vbskycn](https://github.com/vbskycn)
- 项目主页: [FlowMaster](https://github.com/vbskycn/FlowMaster)

### 获取帮助

- 📧 **提交Issue**: [GitHub Issues](https://github.com/vbskycn/FlowMaster/issues)
- 📖 **查看文档**: [项目Wiki](https://github.com/vbskycn/FlowMaster/wiki)
- 💬 **讨论交流**: [GitHub Discussions](https://github.com/vbskycn/FlowMaster/discussions)

### 支持项目

如果这个项目对你有帮助，欢迎：

- ⭐ **Star**: 给项目点个星

- 🍴 **Fork**: 复制项目到你的仓库

- 💡 **贡献**: 提交代码或建议

- 📢 **分享**: 推荐给其他开发者

- 🍴直接请作者喝咖啡

  ![dsm](assets/dsm.jpg)

---

## 🙏 致谢

- [vnstat](https://github.com/vergoh/vnstat) - 强大的网络流量监控工具
- [Vue.js](https://vuejs.org/) - 渐进式 JavaScript 框架
- [Bootstrap](https://getbootstrap.com/) - 流行的前端组件库
- [Chart.js](https://www.chartjs.org/) - 交互式图表库
- [Express.js](https://expressjs.com/) - 快速、开放、极简的 Node.js Web 应用框架
- [systemd](https://systemd.io/) - Linux 服务与日志管理

**感谢使用 FlowMaster！** 

*让网络流量监控变得简单而强大*



