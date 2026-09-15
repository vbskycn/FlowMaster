# FlowMaster 安装与运维指南

本文档集中说明生产安装、升级、安全配置、vnstat 数据保护和故障恢复。快速使用请先阅读根目录 [README](../README.md)。

## 部署模型与路径

一键安装器使用 systemd，而不是全局 PM2。

| 项目 | 默认位置 |
| --- | --- |
| 程序目录 | `/opt/flowmaster` |
| 运行配置 | `/opt/flowmaster/.env` |
| systemd unit | `/etc/systemd/system/flowmaster.service` |
| 管理命令 | `/usr/local/bin/flowmaster` |
| 安装器恢复记录与 PM2 备份 | `/var/backups/flowmaster` |
| 上一版程序回滚目录 | `/opt/.flowmaster-rollback-*` |
| vnstat 数据 | `/var/lib/vnstat` |
| vnstat 备份 | `/var/backups/flowmaster/vnstat` |

`/var/lib/vnstat` 属于系统 vnstat。FlowMaster 的安装、更新和卸载不得删除或重置它。

## 服务身份与文件权限

安装器创建无登录 Shell 的 `flowmaster` 系统账号和同名组，生产服务使用 `User=flowmaster` 和 `Group=flowmaster`，不以 root 运行。系统存在可信的 `vnstat` 系统组时，该账号会加入该组并由 systemd 声明唯一的补充组，以获取读取 vnstat 数据所需的最小权限。安装器同时核对 unit 最终生效的 `SupplementaryGroups` 和主进程 `/proc/<PID>/status` 中的 `Groups`，任何额外组都会使部署失败。

`/opt/flowmaster` 由 `root:flowmaster` 持有：目录通常为 `0750`，普通文件对组只读，`.env` 明确为 `0640`。只有 root 可写程序和配置；不应把服务账号加入其他特权组或放宽为全局可读。systemd unit 同时启用了只读系统、隐藏其他进程、禁止新特权和清空 capability 等沙箱边界。

若系统已经存在同名用户或组，安装器只会在 UID/GID、主组、主目录、无登录 Shell、密码锁定、组成员及附属组均符合专用账号约束时复用；否则会在迁移 PM2 或停服务前拒绝部署。新建账号、组或新增 `vnstat` 成员关系均纳入部署事务：普通失败会恢复部署前身份状态，`useradd` 失败会立即清理本次刚创建的孤立组；只有旧 PM2 已完成离线交接且需要由 systemd 承接旧服务时才保留该专用身份。旧安装目录中的 `.env` 也必须是普通文件，符号链接和特殊文件不会被迁移。

## 安装和升级

### 官方地址

```bash
curl -fL --retry 3 --connect-timeout 10 --max-time 120 -o install.sh \
  https://raw.githubusercontent.com/vbskycn/FlowMaster/main/install.sh
chmod +x install.sh
sudo ./install.sh
```

安装器会：

1. 补齐锁依赖，并获取安装、卸载、备份和恢复共用的维护锁。
2. 补齐 PM2 安全预检命令，尝试收敛可信的上次中断现场，再检查进程健康。
3. 安装其余缺失依赖，验证 Node.js 18+、systemd 247+ 和 vnstat。
4. 下载源码到隔离暂存目录，拒绝危险归档结构，并执行 `npm ci --omit=dev --ignore-scripts` 和语法检查。
5. 在独立进程组内运行有硬超时且带随机实例令牌的临时服务冒烟测试，避免误命中占用端口的旧进程。
6. 安全迁移旧 FlowMaster 进程，仅在检查通过后以同文件系统原子重命名替换 `/opt/flowmaster`。
7. 使用专用 `flowmaster` 系统账号和收紧的 systemd 沙箱启动服务；以每次部署随机生成且仅注入该 unit 的实例令牌绑定 `/api/version` 健康响应，精确核对 `/proc` 中的 Node 可执行文件、仅含 Node 与 `server.js` 的 argv、UID/GID/Groups，并在 `RestartSec=3` 之上保持同一 PID 和 `NRestarts` 不变连续观察 4 秒。最终生效的 unit 属性、持久开机自启或任一运行校验不符时都会回滚。
8. 文件、unit、控制命令或启动任一步失败，或者脚本收到终止信号时，恢复部署前状态。

已有 `/opt/flowmaster/.env` 会复制到新版本并调整为 `root:flowmaster`、`0640`。成功升级后，上一版本保存在 `/opt/.flowmaster-rollback-时间戳.*`；它与程序目录位于同一文件系统，切换通过原子重命名完成，不会留下半复制目录。

安装、升级、卸载、备份和恢复共用非阻塞维护锁 `/run/lock/flowmaster-maintenance.lock`。锁已被占用时，新操作会立即拒绝，不会与另一个状态变更操作并发。如果必须覆盖锁路径，安装器和备份工具必须传入同一个可信绝对路径 `FLOWMASTER_MAINTENANCE_LOCK_FILE`；备份工具还会拒绝位于备份或 vnstat 数据目录中的锁。

安装器只接受规范、无符号链接且具有可信祖先的备份与锁路径；它们不得与 `/opt/flowmaster`、`/var/lib/vnstat`、systemd unit 目录或控制命令目录重叠。源码归档压缩体积上限为 50 MiB、声明展开体积上限为 256 MiB，成员数上限为 20,000；超限会在解包和停服前退出。

### 国内网络代理配置

外层 `curl` 只负责下载安装脚本。要尝试让安装器下载的源码归档也走代理，必须同时传入 `FLOWMASTER_DOWNLOAD_URL`：

```bash
curl -fL --retry 3 --connect-timeout 10 --max-time 120 -o install.sh \
  https://gh-proxy.com/https://raw.githubusercontent.com/vbskycn/FlowMaster/main/install.sh
chmod +x install.sh
sudo env \
  FLOWMASTER_DOWNLOAD_URL='https://gh-proxy.com/https://github.com/vbskycn/FlowMaster/archive/refs/heads/main.tar.gz' \
  ./install.sh
```

`gh-proxy.com` 是第三方 TLS 终点，项目无法保证其可用性或内容完整性。不要通过代理传输密码、Token 或私有仓库凭据；可以直连 GitHub 时优先使用官方地址。

### 固定版本与下载校验

`main` 是移动目标，适合获取最新版，不适合作为可复现部署依据。固定正式版本时，安装脚本和源码归档应使用同一个标签：

```bash
VERSION=vX.Y.Z  # 替换为准备安装的 Release 标签
curl -fL --retry 3 --connect-timeout 10 --max-time 120 -o install.sh \
  "https://raw.githubusercontent.com/vbskycn/FlowMaster/${VERSION}/install.sh"
chmod +x install.sh
sudo env FLOWMASTER_VERSION="${VERSION}" ./install.sh
```

如需让固定版本归档也走国内代理：

```bash
VERSION=vX.Y.Z  # 替换为准备安装的 Release 标签
curl -fL --retry 3 --connect-timeout 10 --max-time 120 -o install.sh \
  "https://gh-proxy.com/https://raw.githubusercontent.com/vbskycn/FlowMaster/${VERSION}/install.sh"
chmod +x install.sh
sudo env \
  FLOWMASTER_VERSION="${VERSION}" \
  FLOWMASTER_DOWNLOAD_URL="https://gh-proxy.com/https://github.com/vbskycn/FlowMaster/archive/refs/tags/${VERSION}.tar.gz" \
  ./install.sh
```

如果已经从独立可信渠道取得该归档的 SHA-256，可在执行上述安装器时额外传入 `FLOWMASTER_SHA256`：

```bash
sudo env \
  FLOWMASTER_VERSION="${VERSION}" \
  FLOWMASTER_DOWNLOAD_URL="https://github.com/vbskycn/FlowMaster/archive/refs/tags/${VERSION}.tar.gz" \
  FLOWMASTER_SHA256='请替换为可信的64位十六进制摘要' \
  ./install.sh
```

不要为 `main` 长期硬编码一个摘要；分支内容更新后摘要必然改变。
`FLOWMASTER_SHA256` 只校验安装器下载的源码归档，不校验已经执行的 `install.sh` 本身；经第三方代理获取安装脚本时，仍需从可信渠道另行核对脚本内容。

安装器常用覆盖变量：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `FLOWMASTER_VERSION` | `main` | `main` 或正式版本标签 |
| `FLOWMASTER_DOWNLOAD_URL` | 根据版本生成的 GitHub 归档地址 | 完整覆盖源码归档 URL |
| `FLOWMASTER_SHA256` | 空 | 非空时校验下载归档 |
| `FLOWMASTER_BACKUP_ROOT` | `/var/backups/flowmaster` | 部署事务记录、PM2 恢复备份，以及与 `/opt` 同文件系统时的卸载归档根目录 |
| `FLOWMASTER_MAINTENANCE_LOCK_FILE` | `/run/lock/flowmaster-maintenance.lock` | 与备份工具共用的维护锁文件 |

其余 `FLOWMASTER_*` 变量用于测试或受控故障恢复，不作为常规部署接口。

## 服务管理与验证

```bash
sudo flowmaster start
sudo flowmaster stop
sudo flowmaster restart
sudo flowmaster status
sudo flowmaster logs
```

非持续日志和健康检查：

```bash
sudo journalctl -u flowmaster.service -n 100 --no-pager
curl --fail http://127.0.0.1:10089/api/version
```

若 `HOST` 或 `PORT` 已修改，请使用实际监听地址。`HOST=0.0.0.0` 或 `HOST=::` 时，本机健康检查使用 `127.0.0.1`。

## 运行配置

首次创建：

```bash
sudo cp -n /opt/flowmaster/.env.example /opt/flowmaster/.env
sudo chown root:flowmaster /opt/flowmaster/.env
sudo chmod 640 /opt/flowmaster/.env
sudo editor /opt/flowmaster/.env
sudo systemctl restart flowmaster.service
```

| 变量 | 默认值 | 允许范围 | 说明 |
| --- | --- | --- | --- |
| `HOST` | `0.0.0.0` | 有效监听地址 | 监听地址 |
| `PORT` | `10089` | `1`–`65535` | 监听端口 |
| `NODE_ENV` | `production` | Node.js 支持的值 | Node.js 运行环境 |
| `CACHE_MAX_SIZE` | `100` | `1`–`10000` | 缓存最大条目数 |
| `CACHE_MAX_MEMORY_MB` | `50` | `1`–`4096` | 缓存估算内存上限，MiB |
| `CACHE_CLEANUP_INTERVAL` | `60000` | `1000`–`3600000` | 过期缓存清理间隔，毫秒 |
| `MEMORY_MONITOR_INTERVAL` | `300000` | `10000`–`86400000` | 内存状态日志间隔，毫秒 |
| `VNSTAT_COMMAND_TIMEOUT_MS` | `15000` | `1000`–`120000` | 单次 vnstat 命令超时，毫秒 |
| `VNSTAT_MAX_CONCURRENCY` | `4` | `1`–`32` | vnstat 子进程全局并发上限 |
| `VNSTAT_MAX_QUEUE` | `256` | `1`–`10000` | 等待执行的 vnstat 请求数；超限快速返回服务繁忙 |
| `MAX_RANGE_DAYS` | `3660` | `1`–`36525` | 日期范围查询最大天数 |
| `REALTIME_INTERVAL_MS` | `5000` | `1000`–`60000` | 同一接口实时采样最小间隔，毫秒 |
| `REALTIME_IDLE_TIMEOUT_MS` | `30000` | `10000`–`3600000` | 最后一次访问后保留采集器的时间，毫秒 |
| `REALTIME_MAX_STALE_MS` | `15000` | `5000`–`600000` | 实时样本新鲜期，毫秒 |
| `REALTIME_MAX_ACTIVE` | `2` | `1`–`16` | 按需实时接口上限；实际值不超过 `max(1, VNSTAT_MAX_CONCURRENCY - 1)` |
| `REALTIME_MAX_BACKOFF_MS` | `60000` | `5000`–`3600000` | 采集失败指数退避上限；实际值不低于采样间隔 |
| `RATE_LIMIT_WINDOW_MS` | `60000` | `1000`–`3600000` | API 限流窗口，毫秒 |
| `RATE_LIMIT_MAX` | `180` | `1`–`1000000` | 每客户端每窗口最大请求数 |
| `RATE_LIMIT_MAX_CLIENTS` | `10000` | `1`–`1000000` | 内存中最多保留的客户端限流桶 |
| `CORS_ORIGINS` | 空 | 逗号分隔的精确来源 | 留空时不发送 CORS 许可头 |
| `ADMIN_TOKEN` | 空 | 字符串 | 管理接口令牌；公网部署应设置高强度值 |
| `ALLOW_ANONYMOUS_ADMIN` | `false` | `true` / `false` | 只在 `ADMIN_TOKEN` 留空时控制旧式匿名管理调用 |
| `TRUST_PROXY` | `false` | `true` / `false` | 仅在单层可信反向代理后设为 `true` |

数值配置必须是不带符号的十进制整数并位于上表边界内，否则使用对应默认值；布尔值不区分大小写，但只接受 `true` 或 `false`。修改 `.env` 后必须重启服务。

服务端代码可解析完整端口范围，但一键安装使用非 root 服务账号，因此安装器会拒绝低于 `1024` 的特权端口。需要对外提供 80/443 时，应由反向代理转发到 FlowMaster 的非特权端口。

实时采集是按接口、按访问启动的，同一接口不会并发执行多个采样命令。超过活跃接口上限时会回收最久未访问且当前没有采样任务的采集器；如果全部候选都在采样，则新接口请求快速返回 `503`，不会通过强制驱逐绕过并发上限。无访问超时后采集器也会自动回收。失败后从一个采样间隔开始指数退避，上限由 `REALTIME_MAX_BACKOFF_MS` 控制；有旧样本时 API 显式返回 `stale=true` 和 `ageMs`。

## 公网安全

FlowMaster 默认监听所有接口，查询 API 和页面不带登录系统。公网部署至少应：

1. 仅由 HTTPS 反向代理访问 FlowMaster。
2. 用防火墙限制 `10089`，不要直接暴露给互联网。
3. 在反向代理层为整个站点配置认证或来源限制。
4. 保持 `ALLOW_ANONYMOUS_ADMIN=false`，并设置高强度 `ADMIN_TOKEN`；管理请求使用 `X-Admin-Token`。
5. 只配置必要的 `CORS_ORIGINS`。
6. 仅在可信代理正确覆盖客户端地址时启用 `TRUST_PROXY=true`。

`CORS_ORIGINS` 是浏览器跨域策略，不是防火墙，也不阻止 curl 等非浏览器客户端。

`ADMIN_TOKEN` 非空时，`ALLOW_ANONYMOUS_ADMIN` 不会绕过令牌校验。如果令牌留空且保持默认 `false`，清缓存和 vnstat 诊断管理接口统一返回 `403`。只有为兼容受信任内网中的旧调用方时，才可在令牌留空的同时显式设置 `ALLOW_ANONYMOUS_ADMIN=true`；详细请求规则见 [API 文档](api.md#管理接口鉴权)。

## vnstat 备份与恢复

运行安装目录内的工具：

```bash
sudo bash /opt/flowmaster/backup_vnstat.sh
```

菜单提供：

1. 创建一致性备份。
2. 校验并恢复备份。
3. 列出备份。

备份和恢复都会先获取与安装器共用的维护锁。备份流程会先暂停正在运行的 `flowmaster.service`，再暂停 vnstat 并复制数据目录；`inactive/failed` 只有在 systemd 同时报告 `MainPID=0`、`ControlPID=0`，且经过严格路径校验的 unit cgroup（包含委派子 cgroup）内没有进程时才算停稳。结束后先启动原本处于活动状态的 vnstat，确认成功后再启动 FlowMaster。启动验证会连续观察 systemd 运行态：常驻服务必须保持 `active/running`、`Result=success` 且具有非零 `MainPID`，`oneshot` 服务则按 `active/exited` 且无常驻主进程验证。停服、残留进程、短暂启动后崩溃或恢复任一步失败都会返回非零状态，不会把未恢复的服务报告为成功。

新建归档和同名 `.sha256` sidecar 权限为 `0600`。压缩包顶层必须恰好包含下列四项：

- `data/`：vnstat 数据文件。
- `checksums.sha256`：每个数据文件的校验和。
- `vnstat.json`：辅助阅读的 JSON 导出；最终恢复判定仍以数据目录校验为准。
- `metadata.txt`：时间、主机名和 vnstat 版本。

同名 `.sha256` 位于压缩包旁边，不是包内成员，用于校验整个归档。归档、sidecar 及父目录完成持久化同步后，工具才会报告备份成功。

恢复在解包前会检查成员路径、类型、重复项、顶层集合与资源上限，拒绝绝对路径、路径穿越、额外顶层文件、符号链接、硬链接、特殊文件、超过 20,000 个成员、压缩文件超过 512 MiB 或声明展开后超过 2 GiB 的归档。解包步骤另有 120 秒硬超时。解包后会再次确认四个顶层成员，重算 `data/` 清单，并用 `vnstat --dbdir ... --dbiflist 2` 和 `--json` 校验数据库。同名 `.sha256` 必须存在且只有一行，同时精确包含归档文件名和正确摘要；缺少 sidecar 的旧手工归档会被拒绝，应先在隔离环境核验并按新格式重新生成。

所有归档校验都在停服前完成；待恢复数据库还会先复制到 vnstat 数据目录所在文件系统的隔离 staging 目录，校验并持久化后才停服。开始替换数据时，工具会先用唯一的 `/var/lib/vnstat.rollback.*` 原子保留现有数据，再将 staging 目录原子切换为活动数据库；关键目录切换均同步父目录。恢复后的数据库校验、持久化、服务启动或脚本信号处理失败时，`EXIT` 事务会停止目标服务、换回原数据并恢复原服务状态。成功后该回滚目录保留供人工核对。

备份工具覆盖变量：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `FLOWMASTER_BACKUP_DIR` | `/var/backups/flowmaster/vnstat` | 备份归档目录 |
| `VNSTAT_DATA_DIR` | `/var/lib/vnstat` | vnstat 数据目录 |
| `FLOWMASTER_BACKUP_LOG` | `/var/log/flowmaster-vnstat-backup.log` | 备份与恢复审计日志 |
| `FLOWMASTER_MAINTENANCE_LOCK_FILE` | `/run/lock/flowmaster-maintenance.lock` | 与安装器共用的维护锁文件 |
| `FLOWMASTER_ALLOW_CUSTOM_VNSTAT_DATA_DIR` | `0` | 自定义 `VNSTAT_DATA_DIR` 时必须显式设为 `1` |

不要把 `VNSTAT_DATA_DIR` 指向宽泛目录。脚本会拒绝 `/`、`/var`、`/var/lib`、`/tmp`、`/opt`、`/root` 和 `/home` 等危险目标，也会拒绝符号链接、数据目录与备份目录互为父子、日志位于数据目录内、以及维护锁位于数据或备份目录内的配置。

## 卸载

重新运行安装脚本，选择“卸载 FlowMaster”。卸载会：

- 停止并禁用 `flowmaster.service`。
- 移除 `/usr/local/bin/flowmaster`。
- 原子归档 `/opt/flowmaster`：备份根与 `/opt` 同一文件系统时写入 `/var/backups/flowmaster/.flowmaster-uninstalled-*`，否则写入 `/opt/.flowmaster-uninstalled-*`。
- 保留 `/var/lib/vnstat`。

需要永久清理归档或 vnstat 数据时，应先创建和验证备份，再单独确认精确目录；卸载器不会代替用户执行这类不可恢复操作。

## PM2 迁移与僵尸进程处理

旧版 FlowMaster 使用全局 PM2。PM2 5.x 的 TreeKill 路径在异常 daemon 上可能反复执行 `ps`，造成高 CPU 和大量僵尸进程。当前安装器不会在线调用 `pm2 delete`、`pm2 stop`、`pm2 save` 或 `pm2 kill` 来迁移 FlowMaster。

只有满足以下安全边界时，安装器才提供原地恢复：

- daemon 属于 root，并由独立的 `pm2-*.service` 管理。
- daemon PID、启动时间、systemd 主进程和 cgroup 一致。
- PM2 CLI 与 unit 使用同一安装。
- `dump.pm2` 以及存在时的 `dump.pm2.bak` 是可信、可解析的普通文件。
- 能精确列出恢复后应保留的其他已保存应用及状态。

确认流程：

1. 重新运行最新版安装器。
2. 阅读安装器列出的其他 PM2 应用和状态。
3. 只有列表正确时输入完整的 `RECOVER-PM2`。
4. 等待安装器有界停止 unit、离线从主备清单移除精确名称 `flowmaster`。
5. 若仍有其他保存应用，安装器恢复并验证它们；若清单只有 FlowMaster，PM2 unit 保持停止并禁用，避免主机重启后拉起空 daemon。
6. FlowMaster 最后由 `flowmaster.service` 接管。

恢复前快照位于 `/var/backups/flowmaster/pm2-recovery-*`，包含原主/备清单和 unit 配置，目录及关键备份权限会收紧。流程不需要重启主机，但 PM2 中列出的其他已保存应用会短暂停止。未执行 `pm2 save` 的应用无法从 daemon 中可靠导出。

若 PM2 已完成离线迁移后新版本部署失败，安装器会用 systemd 承接旧 FlowMaster。旧于本版本的服务不会回显实例令牌，因此仅在这条回滚路径中允许精确的旧版版本响应，并仍要求 systemd MainPID、Node exe、两项 argv、进程身份和完整稳定窗口全部匹配；正式部署的新版本不使用该兼容分支。

中断和失败按已完成阶段收敛：

- unit 实际停止前失败：恢复原 drop-in，不重启未受影响的应用。
- unit 已停止、但过滤后应用集合尚未验证：在清单未被外部修改的前提下，原子换回原主/备清单，持久设置 `PIDUSAGE_USE_PS=false`，并恢复、验证原已保存应用。
- 过滤后应用集合已验证：不再把旧 FlowMaster 加回清单；下次安装只收敛临时安全配置，不重复重启正常应用。
- 过滤后清单为空：要求 PM2 unit 完全停止、cgroup 为空并禁用 unit，防止主机重启后拉起空 daemon。
- 事务期间清单被外部修改：不覆盖新现场，保持 unit 停止并指示备份位置供人工处理。

如果安装器拒绝恢复，不要放宽校验或直接 `kill -9`。先保存完整输出，并检查 unit、cgroup、PM2_HOME 和清单归属；拒绝意味着安装器无法证明不会影响其他应用。

## 回滚

新版本在部署前通过临时冒烟测试，替换后还会检查 systemd 的有效沙箱配置、精确启用状态、主进程 exe/argv/UID/GID/Groups，以及由本次 unit 实例令牌绑定的 `/api/version`。同一 PID 与重启计数必须跨过 `RestartSec=3` 连续稳定 4 秒；任一检查失败时，安装器自动尝试恢复刚归档的旧程序、unit、启用状态和本次新增的账号状态。

成功升级后如需人工回滚：

1. 先记录当前版本、`.env`、服务状态和目标 `/opt/.flowmaster-rollback-*` 目录。
2. 确认目标目录包含 `package.json`、`server.js`、`package-lock.json` 和完整 `node_modules`。
3. 停止 `flowmaster.service`。
4. 将当前 `/opt/flowmaster` 移到新的、明确命名的保留目录，不要删除。
5. 将已核对的回滚目录移动回 `/opt/flowmaster`。
6. 启动服务，并核对 `/api/version`、页面、日志和 vnstat 数据。

人工回滚会改变正在运行的服务，目录选择错误也可能覆盖配置。不要使用通配符或“最新目录”自动选择；逐项核对精确绝对路径后再操作。

## 故障排查

### 服务状态

```bash
sudo systemctl status flowmaster.service --no-pager
sudo journalctl -u flowmaster.service -n 100 --no-pager
sudo systemctl status vnstat --no-pager
```

### 健康与版本

```bash
curl --fail http://127.0.0.1:10089/api/version
curl --fail http://127.0.0.1:10089/api/system/status
```

### 网络接口

```bash
ip route show default
vnstat --dbiflist 1
vnstat -i ens3 --oneline
```

将 `ens3` 替换为 `vnstat --dbiflist 1` 返回的实际接口。不要把接口名拼接到 Shell 命令或脚本中；FlowMaster 本身使用参数数组执行 vnstat。

### 端口

```bash
sudo ss -ltnp | grep ':10089'
```

### 配置未生效

确认编辑的是 `/opt/flowmaster/.env`，然后执行：

```bash
sudo systemctl restart flowmaster.service
sudo systemctl show flowmaster.service -p MainPID -p ActiveState -p SubState
```

不要期望当前终端的 `export` 自动进入 systemd 服务。
