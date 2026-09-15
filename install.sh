#!/usr/bin/env bash

set -Eeuo pipefail

readonly APP_NAME="flowmaster"
readonly APP_DIR="/opt/flowmaster"
readonly CONTROL_SCRIPT="/usr/local/bin/flowmaster"
readonly BACKUP_ROOT="${FLOWMASTER_BACKUP_ROOT:-/var/backups/flowmaster}"
readonly MAINTENANCE_LOCK_FILE="${FLOWMASTER_MAINTENANCE_LOCK_FILE:-/run/lock/flowmaster-maintenance.lock}"
readonly SERVICE_NAME="flowmaster.service"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
readonly SERVICE_USER="flowmaster"
readonly SOURCE_REF="${FLOWMASTER_VERSION:-main}"
if [[ "$SOURCE_REF" == "main" ]]; then
    readonly DEFAULT_DOWNLOAD_URL="https://github.com/vbskycn/FlowMaster/archive/refs/heads/main.tar.gz"
else
    readonly DEFAULT_DOWNLOAD_URL="https://github.com/vbskycn/FlowMaster/archive/refs/tags/${SOURCE_REF}.tar.gz"
fi
readonly DOWNLOAD_URL="${FLOWMASTER_DOWNLOAD_URL:-$DEFAULT_DOWNLOAD_URL}"
readonly SOURCE_ARCHIVE_MAX_BYTES=52428800
readonly SOURCE_ARCHIVE_MAX_EXPANDED_BYTES=268435456
readonly SOURCE_ARCHIVE_MAX_MEMBERS=20000
readonly MINIMUM_SYSTEMD_VERSION=247

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

STAGE_DIR=""
ROLLBACK_DIR=""
SMOKE_PID=""
SMOKE_OUTPUT_FILE=""
DOWNLOAD_ARCHIVE=""
DEPLOY_TRANSACTION_ACTIVE=0
DEPLOY_OLD_APP_MOVED=0
DEPLOY_NEW_APP_INSTALLED=0
DEPLOY_OLD_SERVICE_ACTIVE=0
DEPLOY_OLD_SERVICE_ENABLE_STATE="disabled"
DEPLOY_HAD_SERVICE_FILE=0
DEPLOY_HAD_CONTROL_SCRIPT=0
DEPLOY_SYSTEMD_TOUCHED=0
DEPLOY_STATE_DIR=""
PM2_HANDOFF_MARKER=""
DEPLOY_SERVICE_GROUP_CREATED=0
DEPLOY_SERVICE_USER_CREATED=0
DEPLOY_VNSTAT_MEMBERSHIP_ADDED=0
DEPLOY_SERVICE_UID=""
DEPLOY_SERVICE_GID=""
DEPLOY_VNSTAT_GID=""
SERVICE_INSTANCE_TOKEN=""
PACKAGE_INDEX_REFRESHED=0

log() { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}$*${NC}"; }
fail() { echo -e "${RED}$*${NC}" >&2; exit 1; }

stop_smoke_process() {
    [[ -n "$SMOKE_PID" ]] || return 0

    # 冒烟服务使用独立进程组，必须同时终止其 vnstat 子进程。
    kill -TERM -- "-$SMOKE_PID" >/dev/null 2>&1 || kill -TERM "$SMOKE_PID" >/dev/null 2>&1 || true
    for _ in {1..50}; do
        kill -0 "$SMOKE_PID" >/dev/null 2>&1 || break
        sleep 0.1
    done
    if kill -0 "$SMOKE_PID" >/dev/null 2>&1; then
        kill -KILL -- "-$SMOKE_PID" >/dev/null 2>&1 || kill -KILL "$SMOKE_PID" >/dev/null 2>&1 || true
    fi
    wait "$SMOKE_PID" 2>/dev/null || true
    # 即使进程组领导者已退出，也清理仍处于该进程组的子进程。
    kill -KILL -- "-$SMOKE_PID" >/dev/null 2>&1 || true
    SMOKE_PID=""
}

cleanup() {
    local original_status="$?" cleanup_status=0

    # 回滚期间再次收到 Ctrl+C/TERM 时不能把事务留在半恢复状态。
    trap - EXIT
    trap '' INT TERM HUP
    set +e

    stop_smoke_process
    if (( DEPLOY_TRANSACTION_ACTIVE == 1 )); then
        rollback_deploy_transaction || {
            cleanup_status=1
            warn "部署事务自动回滚未能完整完成，请立即检查 $APP_DIR 和 $SERVICE_NAME"
        }
    fi
    if [[ -n "$SMOKE_OUTPUT_FILE" ]]; then
        rm -f -- "$SMOKE_OUTPUT_FILE"
        SMOKE_OUTPUT_FILE=""
    fi
    if [[ -n "$DOWNLOAD_ARCHIVE" ]]; then
        rm -f -- "$DOWNLOAD_ARCHIVE"
        DOWNLOAD_ARCHIVE=""
    fi
    if [[ -n "$STAGE_DIR" && -d "$STAGE_DIR" ]]; then
        case "$STAGE_DIR" in
            /opt/.flowmaster-stage.*) rm -rf -- "$STAGE_DIR" ;;
            *) warn "拒绝清理非预期临时目录: $STAGE_DIR" ;;
        esac
    fi

    if (( original_status != 0 )); then
        exit "$original_status"
    fi
    exit "$cleanup_status"
}
trap cleanup EXIT

handle_signal() {
    warn "收到终止信号，正在清理并恢复部署前状态..."
    exit 130
}
trap handle_signal INT TERM HUP

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "请使用 root 权限运行此脚本"
}

paths_overlap() {
    local first="$1" second="$2"
    [[ "$first" == "$second" || "$first" == "$second"/* || "$second" == "$first"/* ]]
}

validate_configured_paths() {
    local backup_path lock_path protected_path
    [[ "$BACKUP_ROOT" == /* && "$MAINTENANCE_LOCK_FILE" == /* ]] || \
        fail "FLOWMASTER_BACKUP_ROOT 和维护锁必须使用绝对路径"
    backup_path="$(readlink -m -- "$BACKUP_ROOT")" || fail "无法规范化备份路径"
    lock_path="$(readlink -m -- "$MAINTENANCE_LOCK_FILE")" || fail "无法规范化维护锁路径"
    [[ "$backup_path" == "$BACKUP_ROOT" ]] || fail "备份路径不得包含符号链接、.. 或非规范分隔符: $BACKUP_ROOT"
    [[ "$lock_path" == "$MAINTENANCE_LOCK_FILE" ]] || fail "维护锁路径不得包含符号链接、.. 或非规范分隔符: $MAINTENANCE_LOCK_FILE"
    [[ "$lock_path" != "/" ]] || fail "维护锁路径不能是根目录"

    for protected_path in "$APP_DIR" /var/lib/vnstat /etc/systemd/system /usr/local/bin; do
        paths_overlap "$backup_path" "$protected_path" && \
            fail "备份路径不得与受保护目录重叠: $protected_path"
        paths_overlap "$lock_path" "$protected_path" && \
            fail "维护锁不得位于会被安装器移动或修改的目录中: $protected_path"
    done
    paths_overlap "$lock_path" "$backup_path" && fail "维护锁不得位于备份目录中或与其互为祖先"
    return 0
}

validate_lock_file() {
    local lock_file="$1"
    [[ -f "$lock_file" && ! -L "$lock_file" ]] || return 1
    [[ "$(stat -c '%u' "$lock_file" 2>/dev/null || true)" == "0" ]] || return 1
    [[ "$(stat -c '%h' "$lock_file" 2>/dev/null || true)" == "1" ]] || return 1
}

validate_trusted_directory_chain() {
    local current="$1" permissions owner_uid owner_gid
    while :; do
        [[ -d "$current" && ! -L "$current" ]] || return 1
        owner_uid="$(stat -c '%u' "$current" 2>/dev/null || true)"
        owner_gid="$(stat -c '%g' "$current" 2>/dev/null || true)"
        permissions="$(stat -c '%A' "$current" 2>/dev/null || true)"
        [[ "$owner_uid" == "0" && ${#permissions} -eq 10 ]] || return 1
        # root 组可写的 /run/lock 是可信的；其他组可写目录不可信。
        [[ "${permissions:5:1}" != "w" || "$owner_gid" == "0" ]] || return 1
        # /tmp 这类 root 所有且带 sticky bit 的目录可以作为可信祖先。
        [[ "${permissions:8:1}" != "w" || "${permissions:9:1}" == "t" ]] || return 1
        [[ "$current" != "/" ]] || break
        current="$(dirname "$current")"
    done
}

acquire_installer_lock() {
    local lock_dir lock_identity fd_identity
    command -v flock >/dev/null 2>&1 || fail "缺少 flock，无法防止并发安装"
    lock_dir="$(dirname "$MAINTENANCE_LOCK_FILE")"
    mkdir -p -- "$lock_dir" || fail "无法创建维护锁目录"
    [[ -d "$lock_dir" && ! -L "$lock_dir" && "$(readlink -m -- "$lock_dir")" == "$lock_dir" ]] && \
        validate_trusted_directory_chain "$lock_dir" || \
        fail "维护锁目录不可信: $lock_dir"
    if [[ ! -e "$MAINTENANCE_LOCK_FILE" && ! -L "$MAINTENANCE_LOCK_FILE" ]]; then
        ( set -o noclobber; umask 077; : >"$MAINTENANCE_LOCK_FILE" ) 2>/dev/null || true
    fi
    validate_lock_file "$MAINTENANCE_LOCK_FILE" || fail "维护锁必须是 root 所有、无硬链接的普通文件"
    chmod 0600 "$MAINTENANCE_LOCK_FILE" || fail "无法收紧维护锁权限"
    exec {flowmaster_installer_lock_fd}>>"$MAINTENANCE_LOCK_FILE" || fail "无法打开维护锁"
    lock_identity="$(stat -Lc '%d:%i' "$MAINTENANCE_LOCK_FILE" 2>/dev/null || true)"
    fd_identity="$(stat -Lc '%d:%i' "/proc/self/fd/${flowmaster_installer_lock_fd}" 2>/dev/null || true)"
    [[ -n "$lock_identity" && "$lock_identity" == "$fd_identity" ]] || fail "维护锁在打开期间被替换"
    flock -n "$flowmaster_installer_lock_fd" || fail "另一个 FlowMaster 安装、卸载、备份或恢复流程正在运行"
}

check_installation() {
    [[ -d "$APP_DIR" || -f "$SERVICE_FILE" ]] || command -v flowmaster >/dev/null 2>&1
}

refresh_package_index() {
    (( PACKAGE_INDEX_REFRESHED == 0 )) || return 0
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update
    fi
    PACKAGE_INDEX_REFRESHED=1
}

install_package() {
    local apt_package="$1"
    local rpm_package="${2:-$1}"
    if command -v apt-get >/dev/null 2>&1; then
        refresh_package_index
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$apt_package"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "$rpm_package"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "$rpm_package"
    else
        fail "无法识别包管理器，请手动安装 $apt_package"
    fi
}

ensure_command() {
    local command_name="$1"
    local apt_package="$2"
    local rpm_package="${3:-$2}"
    command -v "$command_name" >/dev/null 2>&1 || install_package "$apt_package" "$rpm_package"
}

validate_systemd_version() {
    local systemd_version
    systemd_version="$(LC_ALL=C systemctl --version 2>/dev/null | awk 'NR == 1 { print $2; exit }')" || {
        warn "无法读取 systemd 版本"
        return 1
    }
    [[ "$systemd_version" =~ ^[0-9]+$ ]] || {
        warn "无法识别 systemd 版本: ${systemd_version:-空}"
        return 1
    }
    (( systemd_version >= MINIMUM_SYSTEMD_VERSION )) || {
        warn "systemd ${systemd_version} 过旧；FlowMaster 一键部署要求 systemd ${MINIMUM_SYSTEMD_VERSION} 或更高版本"
        return 1
    }
}

bootstrap_lock_dependency() {
    command -v flock >/dev/null 2>&1 && return 0
    log "安装维护锁依赖..."
    install_package util-linux util-linux
    command -v flock >/dev/null 2>&1 || fail "flock 安装后仍不可用，无法安全执行维护操作"
}

install_recovery_dependencies() {
    # PM2 健康检查发生在完整依赖安装之前，先补齐其所有外部命令。
    ensure_command ps procps procps-ng
    ensure_command awk mawk gawk
    ensure_command timeout coreutils coreutils
    ensure_command setsid util-linux util-linux
    ensure_command node nodejs nodejs
    ensure_command npm npm npm
    ensure_command runuser util-linux util-linux
    ensure_command useradd passwd shadow-utils
    ensure_command groupadd passwd shadow-utils
    ensure_command usermod passwd shadow-utils
    ensure_command gpasswd passwd shadow-utils
    ensure_command userdel passwd shadow-utils
    ensure_command groupdel passwd shadow-utils
    ensure_command getent libc-bin glibc-common
    command -v systemctl >/dev/null 2>&1 || fail "一键部署需要 systemd；当前系统未找到 systemctl"
    [[ -d /run/systemd/system ]] || fail "systemd 当前未作为系统初始化进程运行，无法安全安装服务"
    validate_systemd_version || fail "当前 systemd 版本不支持 FlowMaster 所需的服务隔离能力"
}

check_process_health() {
    local max_zombies="${FLOWMASTER_MAX_ZOMBIES:-100}"
    [[ "$max_zombies" =~ ^[0-9]+$ ]] || fail "FLOWMASTER_MAX_ZOMBIES 必须是非负整数"

    local zombie_count
    zombie_count="$(ps -eo stat= 2>/dev/null | awk '$1 ~ /^Z/ { count++ } END { print count + 0 }')"
    if (( max_zombies > 0 && zombie_count >= max_zombies )); then
        fail "检测到 ${zombie_count} 个僵尸进程，已停止部署以避免进程风暴。请先定位父进程（ps -eo pid,ppid,stat,comm）并恢复系统健康。"
    fi
}

recover_pm2_before_health_check() {
    local max_zombies="${FLOWMASTER_MAX_ZOMBIES:-100}"
    [[ "$max_zombies" =~ ^[0-9]+$ ]] || fail "FLOWMASTER_MAX_ZOMBIES 必须是非负整数"
    (( max_zombies > 0 )) || return 0

    local zombie_count pm2_zombie_count=0 pm2_home="${PM2_HOME:-/root/.pm2}" pm2_pid=""
    zombie_count="$(ps -eo stat= 2>/dev/null | awk '$1 ~ /^Z/ { count++ } END { print count + 0 }')"
    (( zombie_count >= max_zombies )) || return 0

    if [[ -r "${pm2_home}/pm2.pid" ]]; then
        pm2_pid="$(<"${pm2_home}/pm2.pid")"
    fi
    if [[ "$pm2_pid" =~ ^[1-9][0-9]*$ ]] && is_root_pm2_daemon "$pm2_pid"; then
        pm2_zombie_count="$(ps -eo ppid=,stat= 2>/dev/null | awk -v parent="$pm2_pid" '$1 == parent && $2 ~ /^Z/ { count++ } END { print count + 0 }')"
    fi
    if (( pm2_zombie_count == 0 )); then
        warn "检测到 ${zombie_count} 个僵尸进程，但没有僵尸进程直接归属于可信的 root PM2 daemon；不会误重启 PM2。"
        return 0
    fi

    warn "检测到 ${zombie_count} 个僵尸进程，其中 ${pm2_zombie_count} 个直接归属于 PM2 PID ${pm2_pid}，尝试原地恢复..."
    recover_unresponsive_pm2 || fail "PM2 原地恢复未完整通过验证，已停止部署"

    for _ in {1..50}; do
        zombie_count="$(ps -eo stat= 2>/dev/null | awk '$1 ~ /^Z/ { count++ } END { print count + 0 }')"
        (( zombie_count < max_zombies )) && break
        sleep 0.1
    done
}

install_dependencies() {
    log "检查系统依赖..."
    refresh_package_index
    ensure_command curl curl curl
    ensure_command tar tar tar
    ensure_command node nodejs nodejs
    ensure_command npm npm npm
    ensure_command vnstat vnstat vnstat
    ensure_command timeout coreutils coreutils
    ensure_command setsid util-linux util-linux
    ensure_command flock util-linux util-linux
    ensure_command ps procps procps-ng
    ensure_command awk mawk gawk
    ensure_command ip iproute2 iproute
    ensure_command useradd passwd shadow-utils
    ensure_command groupadd passwd shadow-utils
    ensure_command usermod passwd shadow-utils
    ensure_command gpasswd passwd shadow-utils
    ensure_command userdel passwd shadow-utils
    ensure_command groupdel passwd shadow-utils
    ensure_command getent libc-bin glibc-common

    local node_major
    node_major="$(node -p 'Number(process.versions.node.split(".")[0])')"
    (( node_major >= 18 )) || fail "Node.js 版本过低，需要 18 或更高版本"

    command -v systemctl >/dev/null 2>&1 || fail "一键部署需要 systemd；当前系统未找到 systemctl"
    [[ -d /run/systemd/system ]] || fail "systemd 当前未作为系统初始化进程运行，无法安全安装服务"
    validate_systemd_version || fail "当前 systemd 版本不支持 FlowMaster 所需的服务隔离能力"

    systemctl_bounded enable --now vnstat >/dev/null 2>&1 || \
        timeout --signal=TERM --kill-after=2s 10s service vnstat start
}

detect_network_interface() {
    local selected_interface db_interfaces add_status=0
    selected_interface="$(ip route show default 2>/dev/null | awk 'NR == 1 { for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')"
    if [[ -z "$selected_interface" ]]; then
        selected_interface="$(ip -o link show up | awk -F': ' '$2 != "lo" {print $2; exit}')"
    fi
    selected_interface="${selected_interface%%@*}"
    [[ -n "$selected_interface" ]] || fail "未检测到可用网络接口"
    [[ "$selected_interface" =~ ^[a-zA-Z0-9_.:-]{1,64}$ ]] || fail "检测到的网络接口名称不安全: $selected_interface"

    log "检测到网络接口: $selected_interface"
    db_interfaces="$(LC_ALL=C vnstat --dbiflist 1 2>/dev/null || true)"
    if ! tr '[:space:]' '\n' <<<"$db_interfaces" | grep -Fxq -- "$selected_interface"; then
        warn "vnstat 尚未记录 $selected_interface，正在添加；现有数据库不会被删除。"
        vnstat --add -i "$selected_interface" >/dev/null 2>&1 || add_status=$?
        if (( add_status != 0 )); then
            vnstat -u -i "$selected_interface" >/dev/null 2>&1 || fail "无法将网络接口 $selected_interface 添加到 vnstat 数据库"
        fi
        systemctl_bounded restart vnstat >/dev/null 2>&1 || \
            timeout --signal=TERM --kill-after=2s 10s service vnstat restart
        for _ in {1..20}; do
            db_interfaces="$(LC_ALL=C vnstat --dbiflist 1 2>/dev/null || true)"
            tr '[:space:]' '\n' <<<"$db_interfaces" | grep -Fxq -- "$selected_interface" && return 0
            sleep 0.25
        done
        fail "vnstat 重启后仍未在数据库中发现网络接口 $selected_interface"
    fi
}

validate_source_archive() {
    local archive="$1" entry normalized root archive_root="" type_line entry_size archive_size
    local member_count=0 expanded_size=0
    [[ -f "$archive" && ! -L "$archive" ]] || return 1
    archive_size="$(stat -c '%s' "$archive" 2>/dev/null || true)"
    [[ "$archive_size" =~ ^[1-9][0-9]*$ ]] && (( archive_size <= SOURCE_ARCHIVE_MAX_BYTES )) || return 1
    LC_ALL=C tar --quoting-style=escape -tzf "$archive" >/dev/null || return 1
    while IFS= read -r entry; do
        normalized="${entry#./}"
        [[ -n "$normalized" && "$normalized" != /* && "$normalized" != ../* && "/$normalized" != */../* ]] || return 1
        root="${normalized%%/*}"
        [[ -n "$root" && "$root" != "." && "$root" != ".." ]] || return 1
        if [[ -z "$archive_root" ]]; then
            archive_root="$root"
        else
            [[ "$root" == "$archive_root" ]] || return 1
        fi
        ((member_count += 1))
        (( member_count <= SOURCE_ARCHIVE_MAX_MEMBERS )) || return 1
    done < <(LC_ALL=C tar --quoting-style=escape -tzf "$archive")
    [[ -n "$archive_root" ]] || return 1

    # 源码发布包不需要链接、设备或 FIFO；拒绝这些类型可避免解压路径穿透。
    while IFS= read -r type_line; do
        [[ "${type_line:0:1}" == "-" || "${type_line:0:1}" == "d" ]] || return 1
        entry_size="$(awk '{ print $3 }' <<<"$type_line")"
        [[ "$entry_size" =~ ^[0-9]+$ ]] || return 1
        expanded_size=$((expanded_size + entry_size))
        (( expanded_size <= SOURCE_ARCHIVE_MAX_EXPANDED_BYTES )) || return 1
    done < <(LC_ALL=C tar --quoting-style=escape -tvzf "$archive")
}

download_source() {
    local target_dir="$1"
    DOWNLOAD_ARCHIVE="$(mktemp)"
    curl \
        --fail \
        --location \
        --retry 3 \
        --retry-delay 2 \
        --connect-timeout 10 \
        --max-time 120 \
        --max-filesize 52428800 \
        --output "$DOWNLOAD_ARCHIVE" \
        "$DOWNLOAD_URL"

    local downloaded_size
    downloaded_size="$(stat -c '%s' "$DOWNLOAD_ARCHIVE" 2>/dev/null || true)"
    [[ "$downloaded_size" =~ ^[1-9][0-9]*$ ]] && (( downloaded_size <= SOURCE_ARCHIVE_MAX_BYTES )) || \
        fail "下载归档为空或超过 50 MiB 安全上限"

    if [[ -n "${FLOWMASTER_SHA256:-}" ]]; then
        echo "${FLOWMASTER_SHA256}  ${DOWNLOAD_ARCHIVE}" | sha256sum --check --status || fail "下载文件 SHA-256 校验失败"
    fi

    validate_source_archive "$DOWNLOAD_ARCHIVE" || fail "下载归档结构不安全或不完整"
    tar --extract --gzip --file "$DOWNLOAD_ARCHIVE" --directory "$target_dir" \
        --strip-components=1 --no-same-owner --no-same-permissions --delay-directory-restore
    rm -f -- "$DOWNLOAD_ARCHIVE"
    DOWNLOAD_ARCHIVE=""
    [[ -f "$target_dir/package.json" && ! -L "$target_dir/package.json" && \
       -f "$target_dir/server.js" && ! -L "$target_dir/server.js" && \
       -f "$target_dir/package-lock.json" && ! -L "$target_dir/package-lock.json" ]] || \
        fail "下载内容不完整，拒绝覆盖现有安装"

    if [[ "$SOURCE_REF" != "main" ]]; then
        local expected_version="${SOURCE_REF#v}" archive_version
        archive_version="$(node -p "require('${target_dir}/package.json').version")"
        [[ "$archive_version" == "$expected_version" ]] || \
            fail "下载版本与请求标签不一致（请求 ${SOURCE_REF}，归档为 v${archive_version}）"
    fi
}

smoke_test() {
    local target_dir="$1"
    local smoke_user="${2:-}"
    local smoke_port="${FLOWMASTER_SMOKE_PORT:-19089}"
    local smoke_timeout="${FLOWMASTER_SMOKE_TIMEOUT_SECONDS:-15}"
    local curl_timeout="${FLOWMASTER_SMOKE_CURL_TIMEOUT_SECONDS:-2}"
    if [[ ! "$smoke_port" =~ ^[0-9]+$ ]] || (( smoke_port < 1 || smoke_port > 65535 )); then
        fail "FLOWMASTER_SMOKE_PORT 必须是 1-65535 之间的端口"
    fi
    [[ "$smoke_timeout" =~ ^[1-9][0-9]*$ ]] || fail "FLOWMASTER_SMOKE_TIMEOUT_SECONDS 必须是正整数"
    [[ "$curl_timeout" =~ ^[1-9][0-9]*$ ]] || fail "FLOWMASTER_SMOKE_CURL_TIMEOUT_SECONDS 必须是正整数"

    local expected_version smoke_token
    expected_version="$(node -p "require('${target_dir}/package.json').version")"
    smoke_token="$(node -e "process.stdout.write(require('node:crypto').randomBytes(32).toString('hex'))")"
    SMOKE_OUTPUT_FILE="$(mktemp)"

    log "执行临时服务冒烟测试（最多 ${smoke_timeout} 秒）..."
    if [[ -n "$smoke_user" ]]; then
        (
            cd "$target_dir"
            exec setsid runuser -u "$smoke_user" -- env HOME=/nonexistent HOST=127.0.0.1 \
                PORT="$smoke_port" FLOWMASTER_INSTANCE_TOKEN="$smoke_token" \
                "$(readlink -f "$(command -v node)")" server.js >"$SMOKE_OUTPUT_FILE" 2>&1
        ) &
    else
        (
            cd "$target_dir"
            exec setsid env HOST=127.0.0.1 PORT="$smoke_port" FLOWMASTER_INSTANCE_TOKEN="$smoke_token" \
                node server.js >"$SMOKE_OUTPUT_FILE" 2>&1
        ) &
    fi
    SMOKE_PID=$!

    local deadline=$((SECONDS + smoke_timeout))
    local response=""
    while (( SECONDS < deadline )); do
        if ! kill -0 "$SMOKE_PID" 2>/dev/null; then
            break
        fi
        response="$(curl \
            --fail \
            --silent \
            --show-error \
            --connect-timeout 1 \
            --max-time "$curl_timeout" \
            --header "X-FlowMaster-Instance-Token: ${smoke_token}" \
            "http://127.0.0.1:${smoke_port}/api/version" 2>/dev/null || true)"
        if node -e "const r=JSON.parse(process.argv[1]); if(r.version!==process.argv[2] || r.instanceTokenMatched!==true) process.exit(1)" \
            "$response" "$expected_version" >/dev/null 2>&1; then
            stop_smoke_process
            rm -f -- "$SMOKE_OUTPUT_FILE"
            SMOKE_OUTPUT_FILE=""
            log "临时服务冒烟测试通过"
            return 0
        fi
        sleep 0.5
    done

    warn "临时服务冒烟测试失败，最近日志:"
    tail -n 30 "$SMOKE_OUTPUT_FILE" >&2 || true
    stop_smoke_process
    rm -f -- "$SMOKE_OUTPUT_FILE"
    SMOKE_OUTPUT_FILE=""
    return 1
}

find_pm2_systemd_unit() {
    local pm2_pid="$1"
    local pm2_home="$2"
    local cgroup_path component candidate="" main_pid control_group
    local service_type kill_mode pid_file exec_start service_user service_environment
    local process_uid process_command

    [[ -r "/proc/${pm2_pid}/cgroup" ]] || return 1
    process_uid="$(awk '/^Uid:/ { print $2; exit }' "/proc/${pm2_pid}/status" 2>/dev/null || true)"
    process_command="$(tr '\0' ' ' <"/proc/${pm2_pid}/cmdline" 2>/dev/null || true)"
    [[ "$process_uid" == "0" && "$process_command" == *PM2* && "$process_command" == *God* ]] || return 1

    while IFS=: read -r _ _ cgroup_path; do
        local -a components=()
        IFS='/' read -ra components <<<"$cgroup_path"
        for component in "${components[@]}"; do
            if [[ "$component" =~ ^pm2[-_.@a-zA-Z0-9]+\.service$ ]]; then
                candidate="$component"
            fi
        done
    done <"/proc/${pm2_pid}/cgroup"

    [[ -n "$candidate" ]] || return 1
    main_pid="$(systemctl_bounded show "$candidate" --property=MainPID --value 2>/dev/null || true)"
    service_type="$(systemctl_bounded show "$candidate" --property=Type --value 2>/dev/null || true)"
    kill_mode="$(systemctl_bounded show "$candidate" --property=KillMode --value 2>/dev/null || true)"
    pid_file="$(systemctl_bounded show "$candidate" --property=PIDFile --value 2>/dev/null || true)"
    exec_start="$(systemctl_bounded show "$candidate" --property=ExecStart --value 2>/dev/null || true)"
    service_user="$(systemctl_bounded show "$candidate" --property=User --value 2>/dev/null || true)"
    service_environment="$(systemctl_bounded show "$candidate" --property=Environment --value 2>/dev/null || true)"
    control_group="$(systemctl_bounded show "$candidate" --property=ControlGroup --value 2>/dev/null || true)"
    [[ "$main_pid" == "$pm2_pid" ]] || return 1
    [[ "$service_type" == "forking" && "$kill_mode" == "control-group" ]] || return 1
    [[ -z "$service_user" || "$service_user" == "root" ]] || return 1
    [[ "$pid_file" == "${pm2_home%/}/pm2.pid" ]] || return 1
    [[ "$exec_start" == *resurrect* ]] || return 1
    [[ "$service_environment" == *"PM2_HOME=${pm2_home%/}"* ]] || return 1
    [[ "$control_group" == "/system.slice/${candidate}" ]] || return 1
    [[ -f /sys/fs/cgroup/cgroup.controllers ]] || return 1
    printf '%s\n' "$candidate"
}

is_root_pm2_daemon() {
    local pm2_pid="$1"
    local process_uid process_command expected_uid="${EUID:-0}"
    [[ -r "/proc/${pm2_pid}/status" && -r "/proc/${pm2_pid}/cmdline" ]] || return 1
    process_uid="$(awk '/^Uid:/ { print $2; exit }' "/proc/${pm2_pid}/status" 2>/dev/null || true)"
    process_command="$(tr '\0' ' ' <"/proc/${pm2_pid}/cmdline" 2>/dev/null || true)"
    [[ "$process_uid" == "$expected_uid" && "$process_command" == *PM2* && "$process_command" == *God* ]]
}

get_process_starttime() {
    local process_pid="$1"
    node - "$process_pid" <<'NODE'
'use strict';
const fs = require('node:fs');
const pid = process.argv[2];
const stat = fs.readFileSync(`/proc/${pid}/stat`, 'utf8');
const closing = stat.lastIndexOf(') ');
if (closing < 0) process.exit(1);
const fields = stat.slice(closing + 2).trim().split(/\s+/);
if (!/^\d+$/.test(fields[19] || '')) process.exit(1);
process.stdout.write(fields[19]);
NODE
}

process_matches_starttime() {
    local process_pid="$1"
    local expected_starttime="$2"
    [[ "$(get_process_starttime "$process_pid" 2>/dev/null || true)" == "$expected_starttime" ]]
}

is_timeout_status() {
    local command_status="$1"
    (( command_status == 124 || command_status == 137 ))
}

validate_pm2_dump_file() {
    local dump_file="$1"
    local file_uid file_size
    [[ -f "$dump_file" && ! -L "$dump_file" ]] || return 1
    file_uid="$(stat -c '%u' "$dump_file" 2>/dev/null || true)"
    file_size="$(stat -c '%s' "$dump_file" 2>/dev/null || true)"
    [[ "$file_uid" == "0" && "$file_size" =~ ^[0-9]+$ ]] || return 1
    (( file_size > 1 && file_size <= 10 * 1024 * 1024 )) || return 1
    [[ -z "$(find "$dump_file" -maxdepth 0 -perm /022 -print -quit 2>/dev/null)" ]] || return 1
    node -e "const fs=require('node:fs'); const value=JSON.parse(fs.readFileSync(process.argv[1], 'utf8')); if (!Array.isArray(value)) process.exit(1);" "$dump_file"
}

validate_pm2_home_directory() {
    local pm2_home="$1"
    [[ -d "$pm2_home" && ! -L "$pm2_home" ]] || return 1
    [[ "$(stat -c '%u' "$pm2_home" 2>/dev/null || true)" == "0" ]] || return 1
    [[ -z "$(find "$pm2_home" -maxdepth 0 -perm /022 -print -quit 2>/dev/null)" ]] || return 1
}

rewrite_pm2_dump_without_app() {
    local dump_file="$1"
    node - "$dump_file" "$APP_NAME" <<'NODE'
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const [target, appName] = process.argv.slice(2);
let temporary = '';
try {
    const stat = fs.lstatSync(target);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.uid !== 0 || stat.size > 10 * 1024 * 1024) process.exit(1);
    const apps = JSON.parse(fs.readFileSync(target, 'utf8'));
    if (!Array.isArray(apps)) throw new Error('PM2 dump.pm2 根节点不是数组');
    const getName = app => app && (app.name || (app.pm2_env && app.pm2_env.name));
    const kept = apps.filter(app => getName(app) !== appName);
    if (kept.length === apps.length) process.exit(0);
    temporary = path.join(path.dirname(target), `.${path.basename(target)}.flowmaster-${process.pid}-${crypto.randomBytes(6).toString('hex')}`);
    const fd = fs.openSync(temporary, 'wx', stat.mode);
    try {
        fs.writeFileSync(fd, `${JSON.stringify(kept, null, 2)}\n`);
        fs.fsyncSync(fd);
    } finally {
        fs.closeSync(fd);
    }
    fs.chownSync(temporary, stat.uid, stat.gid);
    fs.chmodSync(temporary, stat.mode);
    fs.renameSync(temporary, target);
    temporary = '';
    const directoryFd = fs.openSync(path.dirname(target), 'r');
    try { fs.fsyncSync(directoryFd); } finally { fs.closeSync(directoryFd); }
} catch (error) {
    if (temporary) {
        try { fs.unlinkSync(temporary); } catch {}
    }
    process.exit(1);
}
NODE
}

pm2_dump_contains_app() {
    local dump_file="$1"
    node -e "const fs=require('node:fs'); const a=JSON.parse(fs.readFileSync(process.argv[1],'utf8')); const n=process.argv[2]; if(!a.some(x => x && (x.name === n || x.pm2_env && x.pm2_env.name === n))) process.exit(1);" "$dump_file" "$APP_NAME"
}

pm2_saved_handoff_state() {
    local dump_file="$1"
    node -e "const fs=require('node:fs');const a=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));const n=process.argv[2];const x=a.find(v=>v&&(v.name===n||v.pm2_env&&v.pm2_env.name===n));const e=x&&(x.pm2_env||x);process.stdout.write(e&&e.status==='online'?'online':'inactive');" \
        "$dump_file" "$APP_NAME"
}

record_pm2_handoff() {
    local handoff_state="${1:-inactive}" temporary_file
    [[ -n "$PM2_HANDOFF_MARKER" ]] || return 0
    [[ "$handoff_state" == "online" || "$handoff_state" == "inactive" ]] || return 1
    [[ -n "$DEPLOY_STATE_DIR" && "$PM2_HANDOFF_MARKER" == "$DEPLOY_STATE_DIR/pm2-flowmaster-retired" ]] || return 1
    [[ -d "$DEPLOY_STATE_DIR" && ! -L "$DEPLOY_STATE_DIR" ]] || return 1
    temporary_file="$(mktemp "${PM2_HANDOFF_MARKER}.tmp.XXXXXX")" || return 1
    if ! printf '%s\n' "$handoff_state" >"$temporary_file" || \
       ! chmod 0600 "$temporary_file" || \
       ! sync -f "$temporary_file" || \
       ! mv -fT -- "$temporary_file" "$PM2_HANDOFF_MARKER" || \
       ! sync -f "$DEPLOY_STATE_DIR"; then
        rm -f -- "$temporary_file"
        return 1
    fi
}

clear_pm2_handoff() {
    [[ -n "$PM2_HANDOFF_MARKER" ]] || return 0
    [[ -n "$DEPLOY_STATE_DIR" && "$PM2_HANDOFF_MARKER" == "$DEPLOY_STATE_DIR/pm2-flowmaster-retired" ]] || return 1
    [[ -d "$DEPLOY_STATE_DIR" && ! -L "$DEPLOY_STATE_DIR" ]] || return 1
    if [[ -e "$PM2_HANDOFF_MARKER" || -L "$PM2_HANDOFF_MARKER" ]]; then
        [[ -f "$PM2_HANDOFF_MARKER" && ! -L "$PM2_HANDOFF_MARKER" ]] || return 1
        rm -f -- "$PM2_HANDOFF_MARKER" || return 1
        sync -f "$DEPLOY_STATE_DIR" || return 1
    fi
}

sanitize_saved_pm2_dumps() {
    local pm2_home="$1"
    local backup_dir="$2"
    local dump_file restore_dump backup_file restore_failed=0
    local -a dump_files=()

    for dump_file in "${pm2_home}/dump.pm2" "${pm2_home}/dump.pm2.bak"; do
        [[ -e "$dump_file" ]] || continue
        validate_pm2_dump_file "$dump_file" || return 1
        dump_files+=("$dump_file")
    done

    for dump_file in "${dump_files[@]}"; do
        backup_file="$backup_dir/$(basename "$dump_file").before-flowmaster-removal"
        cp -a -- "$dump_file" "$backup_file" || return 1
    done

    for dump_file in "${dump_files[@]}"; do
        if ! rewrite_pm2_dump_without_app "$dump_file" || pm2_dump_contains_app "$dump_file"; then
            for restore_dump in "${dump_files[@]}"; do
                backup_file="$backup_dir/$(basename "$restore_dump").before-flowmaster-removal"
                cp -a -- "$backup_file" "$restore_dump" || restore_failed=1
            done
            (( restore_failed == 0 )) || warn "PM2 清单过滤失败，且至少一个原文件未能自动恢复"
            return 1
        fi
    done

    return 0
}

print_pm2_recovery_apps() {
    local expected_dump="$1"
    node - "$expected_dump" "$APP_NAME" <<'NODE'
'use strict';
const fs = require('node:fs');
const apps = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const targetName = process.argv[3];
const clean = value => String(value || '未命名').replace(/[\u0000-\u001f\u007f]/g, '?').slice(0, 120);
const kept = apps.filter(app => {
    const name = app && (app.name || (app.pm2_env && app.pm2_env.name));
    return name !== targetName;
});
if (kept.length === 0) {
    console.log('  - （无；PM2 unit 将保持停止）');
}
for (const app of kept) {
    const env = app && (app.pm2_env || app);
    console.log(`  - ${clean(env && env.name)} (${clean(env && env.status || '已保存')})`);
}
NODE
}

pm2_dump_has_entries() {
    local dump_file="$1"
    node -e "const fs=require('node:fs'); const value=JSON.parse(fs.readFileSync(process.argv[1], 'utf8')); if (!Array.isArray(value) || value.length === 0) process.exit(1);" "$dump_file"
}

verify_pm2_runtime() {
    local expected_dump="$1"
    local live_processes="$2"
    node - "$expected_dump" "$live_processes" <<'NODE'
'use strict';
const fs = require('node:fs');
const [expectedPath, livePath] = process.argv.slice(2);
const expectedRaw = JSON.parse(fs.readFileSync(expectedPath, 'utf8'));
const liveRaw = JSON.parse(fs.readFileSync(livePath, 'utf8'));
if (!Array.isArray(expectedRaw) || !Array.isArray(liveRaw)) process.exit(1);
const expected = expectedRaw.filter(app => app && !app.pmx_module);
const live = liveRaw.filter(app => app && !(app.pm2_env && app.pm2_env.pmx_module));
const signature = app => {
    const env = app.pm2_env || app;
    return JSON.stringify([
        env.name || '',
        env.namespace || 'default',
        env.pm_exec_path || '',
        env.exec_mode || '',
        env.status || ''
    ]);
};
const expectedSignatures = expected.map(signature).sort();
const liveSignatures = live.map(signature).sort();
if (JSON.stringify(expectedSignatures) !== JSON.stringify(liveSignatures)) process.exit(1);
const liveStatuses = live.map(app => app.pm2_env && app.pm2_env.status);
if (liveStatuses.some(status => status === 'errored' || status === 'launching')) process.exit(1);
for (const app of live) {
    const status = app.pm2_env && app.pm2_env.status;
    if (status !== 'online') continue;
    if (!Number.isInteger(app.pid) || app.pid <= 0) process.exit(1);
    try { process.kill(app.pid, 0); } catch { process.exit(1); }
}
NODE
}

get_pm2_app_presence() {
    local pm2_home="$1"
    local process_list command_status=0 presence
    process_list="$(mktemp)" || return 1
    chmod 0600 "$process_list" || { rm -f -- "$process_list"; return 1; }
    timeout --signal=TERM --kill-after=2s 5s env PM2_HOME="$pm2_home" PIDUSAGE_USE_PS=false \
        pm2 jlist >"$process_list" 2>/dev/null || command_status=$?
    if (( command_status != 0 )); then
        rm -f -- "$process_list"
        return "$command_status"
    fi
    presence="$(node - "$process_list" "$APP_NAME" <<'NODE'
'use strict';
const fs = require('node:fs');
const [listPath, appName] = process.argv.slice(2);
const apps = JSON.parse(fs.readFileSync(listPath, 'utf8'));
if (!Array.isArray(apps)) process.exit(1);
const names = apps
    .filter(app => app && !(app.pm2_env && app.pm2_env.pmx_module))
    .map(app => app.name || (app.pm2_env && app.pm2_env.name));
process.stdout.write(names.includes(appName) ? 'present' : 'absent');
NODE
)" || { rm -f -- "$process_list"; return 1; }
    rm -f -- "$process_list"
    [[ "$presence" == "present" || "$presence" == "absent" ]] || return 1
    printf '%s\n' "$presence"
}

saved_pm2_dumps_contain_app() {
    local pm2_home="$1"
    local dump_file found=1
    for dump_file in "${pm2_home}/dump.pm2" "${pm2_home}/dump.pm2.bak"; do
        [[ -e "$dump_file" ]] || continue
        validate_pm2_dump_file "$dump_file" || return 2
        pm2_dump_contains_app "$dump_file" && found=0
    done
    return "$found"
}

finalize_pm2_dump_migration() (
    local pm2_home="$1"
    local handoff_state="${2:-inactive}"
    local dump_state=0 migration_backup dump_file backup_file original_status
    local migration_changed=0 migration_success=0 restore_failed=0
    if [[ ! -e "${pm2_home}/dump.pm2" && ! -e "${pm2_home}/dump.pm2.bak" ]]; then
        return 0
    fi
    validate_pm2_home_directory "$pm2_home" || return 1
    saved_pm2_dumps_contain_app "$pm2_home" || dump_state=$?
    if (( dump_state == 1 )); then
        return 0
    fi
    (( dump_state == 0 )) || return 1
    mkdir -p "$BACKUP_ROOT" || return 1
    migration_backup="$(mktemp -d "${BACKUP_ROOT}/pm2-migration-$(date +%Y%m%d-%H%M%S).XXXXXX")" || return 1
    chmod 0700 "$migration_backup" || return 1

    rollback_offline_pm2_migration() {
        original_status="$?"
        trap - EXIT
        trap '' INT TERM HUP
        (( migration_changed == 1 && migration_success == 0 )) || return "$original_status"
        set +e
        for dump_file in "${pm2_home}/dump.pm2" "${pm2_home}/dump.pm2.bak"; do
            backup_file="$migration_backup/$(basename "$dump_file").before-flowmaster-removal"
            [[ -e "$backup_file" ]] || continue
            restore_pm2_dump_atomically "$backup_file" "$dump_file" || restore_failed=1
        done
        if (( restore_failed == 0 )); then
            clear_pm2_handoff || restore_failed=1
        fi
        if (( restore_failed == 0 )); then
            warn "PM2 离线清单迁移未完成，已恢复原保存清单"
        else
            warn "PM2 离线清单迁移回滚不完整；备份位于: $migration_backup"
        fi
        return "$original_status"
    }
    trap rollback_offline_pm2_migration EXIT
    trap 'exit 130' INT TERM HUP

    # sanitize 内部也会回滚部分写入；此标志额外覆盖其返回后到 handoff 落盘之间的信号窗口。
    migration_changed=1
    sanitize_saved_pm2_dumps "$pm2_home" "$migration_backup" || {
        warn "PM2 主/备清单校验或过滤失败，备份位于: $migration_backup"
        return 1
    }
    record_pm2_handoff "$handoff_state" || {
        warn "无法记录 PM2 离线清单交接状态，正在恢复原保存清单"
        return 1
    }
    migration_success=1
)

pm2_unit_cgroup_is_empty() {
    local pm2_unit="$1"
    local control_group cgroup_file cgroup_pid=""
    control_group="$(systemctl_bounded show "$pm2_unit" --property=ControlGroup --value 2>/dev/null || true)"
    [[ -z "$control_group" || "$control_group" == "/system.slice/${pm2_unit}" ]] || return 1
    cgroup_file="/sys/fs/cgroup/system.slice/${pm2_unit}/cgroup.procs"
    [[ ! -e "$cgroup_file" ]] && return 0
    [[ -r "$cgroup_file" ]] || return 1
    read -r cgroup_pid <"$cgroup_file" || true
    [[ -z "$cgroup_pid" ]]
}

signal_pm2_cgroup_children() {
    local pm2_unit="$1"
    local pm2_pid="$2"
    local signal_name="$3"
    local cgroup_file="/sys/fs/cgroup/system.slice/${pm2_unit}/cgroup.procs"
    local child_pid child_cgroup

    [[ -r "$cgroup_file" ]] || return 1
    while IFS= read -r child_pid; do
        [[ "$child_pid" =~ ^[1-9][0-9]*$ ]] || return 1
        [[ "$child_pid" != "$pm2_pid" ]] || continue
        [[ -r "/proc/${child_pid}/cgroup" ]] || continue
        child_cgroup="$(sed -n 's/^0:://p' "/proc/${child_pid}/cgroup" 2>/dev/null | tail -n 1)"
        [[ "$child_cgroup" == "/system.slice/${pm2_unit}" ]] || return 1
        kill -s "$signal_name" "$child_pid" >/dev/null 2>&1 || true
    done <"$cgroup_file"
}

pm2_cgroup_has_children() {
    local pm2_unit="$1"
    local pm2_pid="$2"
    local cgroup_file="/sys/fs/cgroup/system.slice/${pm2_unit}/cgroup.procs"
    local child_pid

    [[ -r "$cgroup_file" ]] || return 1
    while IFS= read -r child_pid; do
        [[ "$child_pid" =~ ^[1-9][0-9]*$ ]] || return 0
        [[ "$child_pid" == "$pm2_pid" ]] || return 0
    done <"$cgroup_file"
    return 1
}

stop_pm2_systemd_unit() (
    local pm2_unit="$1"
    local pm2_pid="$2"
    local pm2_starttime="$3"
    local grace_deadline deadline
    local main_pid control_pid active_state
    local daemon_needs_resume=0

    # 该函数仅由局部 signal/EXIT trap 间接调用。
    # shellcheck disable=SC2317
    resume_frozen_pm2() {
        if (( daemon_needs_resume == 1 )) && process_matches_starttime "$pm2_pid" "$pm2_starttime"; then
            kill -CONT "$pm2_pid" >/dev/null 2>&1 || true
        fi
    }
    trap resume_frozen_pm2 EXIT
    trap 'resume_frozen_pm2; exit 130' INT TERM HUP

    process_matches_starttime "$pm2_pid" "$pm2_starttime" || return 1
    main_pid="$(systemctl_bounded show "$pm2_unit" --property=MainPID --value 2>/dev/null || true)"
    control_pid="$(systemctl_bounded show "$pm2_unit" --property=ControlPID --value 2>/dev/null || true)"
    active_state="$(systemctl_bounded show "$pm2_unit" --property=ActiveState --value 2>/dev/null || true)"
    [[ "$active_state" == "active" && "$main_pid" == "$pm2_pid" && "$control_pid" == "0" ]] || return 1
    # PM2 5.x 捕获 SIGINT/SIGTERM 后会逐个 delete 应用并进入递归 TreeKill。
    # 先冻结 daemon，单独给同一 cgroup 的应用一个短暂退出窗口，再由
    # systemd 直接 KILL 剩余 cgroup，避免重新制造 ps 僵尸风暴。
    kill -STOP "$pm2_pid" >/dev/null 2>&1 || return 1
    daemon_needs_resume=1
    if ! process_matches_starttime "$pm2_pid" "$pm2_starttime"; then
        return 1
    fi
    signal_pm2_cgroup_children "$pm2_unit" "$pm2_pid" TERM || return 1
    grace_deadline=$((SECONDS + 5))
    while (( SECONDS < grace_deadline )); do
        pm2_cgroup_has_children "$pm2_unit" "$pm2_pid" || break
        sleep 0.2
    done
    systemctl_bounded kill --kill-whom=all --signal=KILL "$pm2_unit" >/dev/null 2>&1 || return 1
    daemon_needs_resume=0
    systemctl_bounded --no-block stop "$pm2_unit" >/dev/null 2>&1 || return 1
    deadline=$((SECONDS + 45))
    while (( SECONDS < deadline )); do
        main_pid="$(systemctl_bounded show "$pm2_unit" --property=MainPID --value 2>/dev/null || true)"
        control_pid="$(systemctl_bounded show "$pm2_unit" --property=ControlPID --value 2>/dev/null || true)"
        active_state="$(systemctl_bounded show "$pm2_unit" --property=ActiveState --value 2>/dev/null || true)"
        if [[ "$active_state" =~ ^(inactive|failed)$ && "$main_pid" == "0" && "$control_pid" == "0" ]] && \
           ! process_matches_starttime "$pm2_pid" "$pm2_starttime" && \
           pm2_unit_cgroup_is_empty "$pm2_unit"; then
            return 0
        fi
        sleep 0.5
    done
    return 1
)

verify_pm2_daemon_identity() {
    local pm2_unit="$1"
    local pm2_home="$2"
    local expected_pid="$3"
    local expected_starttime="$4"
    local main_pid control_pid active_state

    main_pid="$(systemctl_bounded show "$pm2_unit" --property=MainPID --value 2>/dev/null || true)"
    control_pid="$(systemctl_bounded show "$pm2_unit" --property=ControlPID --value 2>/dev/null || true)"
    active_state="$(systemctl_bounded show "$pm2_unit" --property=ActiveState --value 2>/dev/null || true)"
    [[ "$active_state" == "active" && "$control_pid" == "0" && "$main_pid" == "$expected_pid" ]] || return 1
    process_matches_starttime "$expected_pid" "$expected_starttime" || return 1
    is_root_pm2_daemon "$expected_pid" || return 1
    [[ "$(find_pm2_systemd_unit "$expected_pid" "$pm2_home" 2>/dev/null || true)" == "$pm2_unit" ]] || return 1
    grep -zqx 'PIDUSAGE_USE_PS=false' "/proc/${expected_pid}/environ" 2>/dev/null
}

start_pm2_systemd_unit() {
    local pm2_unit="$1"
    local pm2_home="$2"
    local deadline=$((SECONDS + 45))
    local main_pid control_pid active_state new_starttime

    systemctl_bounded reset-failed "$pm2_unit" >/dev/null 2>&1 || true
    systemctl_bounded --no-block start "$pm2_unit" >/dev/null 2>&1 || return 1
    while (( SECONDS < deadline )); do
        main_pid="$(systemctl_bounded show "$pm2_unit" --property=MainPID --value 2>/dev/null || true)"
        control_pid="$(systemctl_bounded show "$pm2_unit" --property=ControlPID --value 2>/dev/null || true)"
        active_state="$(systemctl_bounded show "$pm2_unit" --property=ActiveState --value 2>/dev/null || true)"
        if [[ "$active_state" == "active" && "$control_pid" == "0" && "$main_pid" =~ ^[1-9][0-9]*$ ]]; then
            new_starttime="$(get_process_starttime "$main_pid" 2>/dev/null || true)"
            [[ -n "$new_starttime" ]] || return 1
            verify_pm2_daemon_identity "$pm2_unit" "$pm2_home" "$main_pid" "$new_starttime" || return 1
            printf '%s:%s\n' "$main_pid" "$new_starttime"
            return 0
        fi
        sleep 0.5
    done
    return 1
}

verify_restarted_pm2() {
    local pm2_home="$1"
    local expected_dump="$2"
    local pm2_unit="$3"
    local expected_pid="$4"
    local expected_starttime="$5"
    local process_list deadline=$((SECONDS + 30))

    verify_pm2_daemon_identity "$pm2_unit" "$pm2_home" "$expected_pid" "$expected_starttime" || return 1
    timeout --signal=TERM --kill-after=2s 10s env PM2_HOME="$pm2_home" PIDUSAGE_USE_PS=false \
        pm2 ping >/dev/null 2>&1 || return 1
    verify_pm2_daemon_identity "$pm2_unit" "$pm2_home" "$expected_pid" "$expected_starttime" || return 1
    process_list="$(mktemp)" || return 1
    chmod 0600 "$process_list" || { rm -f -- "$process_list"; return 1; }
    while (( SECONDS < deadline )); do
        : >"$process_list" || { rm -f -- "$process_list"; return 1; }
        if timeout --signal=TERM --kill-after=2s 10s env PM2_HOME="$pm2_home" PIDUSAGE_USE_PS=false \
            pm2 jlist >"$process_list" 2>/dev/null && \
           verify_pm2_daemon_identity "$pm2_unit" "$pm2_home" "$expected_pid" "$expected_starttime" && \
           verify_pm2_runtime "$expected_dump" "$process_list"; then
            rm -f -- "$process_list"
            return 0
        fi
        sleep 0.5
    done
    rm -f -- "$process_list"
    return 1
}

validate_pm2_dropin_directory() {
    local dropin_dir="$1"
    local owner_uid
    if [[ -e "$dropin_dir" || -L "$dropin_dir" ]]; then
        [[ -d "$dropin_dir" && ! -L "$dropin_dir" ]] || return 1
    else
        install -d -o root -g root -m 0755 "$dropin_dir" || return 1
    fi
    owner_uid="$(stat -c '%u' "$dropin_dir" 2>/dev/null || true)"
    [[ "$owner_uid" == "0" ]] || return 1
    [[ -z "$(find "$dropin_dir" -maxdepth 0 -perm /022 -print -quit 2>/dev/null)" ]] || return 1
}

install_pm2_dropin_atomically() {
    local source_file="$1"
    local target_file="$2"
    local target_dir temporary_file
    target_dir="$(dirname "$target_file")"
    validate_pm2_dropin_directory "$target_dir" || return 1
    temporary_file="$(mktemp "${target_file}.tmp.XXXXXX")" || return 1
    if ! install -o root -g root -m 0644 "$source_file" "$temporary_file" || \
       ! sync -f "$temporary_file" || \
       ! mv -fT -- "$temporary_file" "$target_file" || \
       ! sync -f "$target_dir"; then
        rm -f -- "$temporary_file"
        return 1
    fi
}

effective_pm2_pidusage_setting() {
    local pm2_unit="$1"
    systemctl_bounded show "$pm2_unit" --property=Environment --value 2>/dev/null | \
        tr ' ' '\n' | sed -n 's/^PIDUSAGE_USE_PS=//p' | tail -n 1
}

verify_pm2_recovery_unit_settings() {
    local pm2_unit="$1"
    local exec_stop kill_signal
    exec_stop="$(systemctl_bounded show "$pm2_unit" --property=ExecStop --value 2>/dev/null || true)"
    kill_signal="$(systemctl_bounded show "$pm2_unit" --property=KillSignal --value 2>/dev/null || true)"
    [[ "$(systemctl_bounded show "$pm2_unit" --property=TimeoutStopUSec --value 2>/dev/null || true)" == "15s" ]] || return 1
    [[ "$(systemctl_bounded show "$pm2_unit" --property=TimeoutStopFailureMode --value 2>/dev/null || true)" == "kill" ]] || return 1
    [[ "$(systemctl_bounded show "$pm2_unit" --property=KillMode --value 2>/dev/null || true)" == "control-group" ]] || return 1
    [[ "$kill_signal" == "9" || "$kill_signal" == "KILL" || "$kill_signal" == "SIGKILL" ]] || return 1
    [[ "$(systemctl_bounded show "$pm2_unit" --property=SendSIGKILL --value 2>/dev/null || true)" == "yes" ]] || return 1
    [[ "$(systemctl_bounded show "$pm2_unit" --property=Restart --value 2>/dev/null || true)" == "no" ]] || return 1
    [[ -z "$exec_stop" ]] || return 1
    [[ "$(effective_pm2_pidusage_setting "$pm2_unit")" == "false" ]] || return 1
}

is_known_flowmaster_pm2_dropin() {
    local dropin_file="$1"
    local file_size content
    [[ -f "$dropin_file" && ! -L "$dropin_file" ]] || return 1
    [[ "$(stat -c '%u' "$dropin_file" 2>/dev/null || true)" == "0" ]] || return 1
    [[ -z "$(find "$dropin_file" -maxdepth 0 -perm /022 -print -quit 2>/dev/null)" ]] || return 1
    file_size="$(stat -c '%s' "$dropin_file" 2>/dev/null || true)"
    [[ "$file_size" =~ ^[1-9][0-9]*$ ]] && (( file_size <= 1024 )) || return 1
    content="$(<"$dropin_file")"
    case "$content" in
        $'[Service]\nEnvironment=PIDUSAGE_USE_PS=false' | \
        $'[Service]\nEnvironment=PIDUSAGE_USE_PS=false\nTimeoutStopSec=15s\nTimeoutStopFailureMode=kill\nKillMode=control-group\nSendSIGKILL=yes' | \
        $'[Service]\nEnvironment=PIDUSAGE_USE_PS=false\nRestart=no\nExecStop=\nTimeoutStopSec=15s\nTimeoutStopFailureMode=kill\nKillMode=control-group\nKillSignal=SIGKILL\nSendSIGKILL=yes') return 0 ;;
        *) return 1 ;;
    esac
}

is_temporary_flowmaster_pm2_dropin() {
    local dropin_file="$1" content
    is_known_flowmaster_pm2_dropin "$dropin_file" || return 1
    content="$(<"$dropin_file")"
    [[ "$content" == $'[Service]\nEnvironment=PIDUSAGE_USE_PS=false\nRestart=no\nExecStop=\nTimeoutStopSec=15s\nTimeoutStopFailureMode=kill\nKillMode=control-group\nKillSignal=SIGKILL\nSendSIGKILL=yes' ]]
}

restore_pm2_dropin() {
    local pm2_unit="$1"
    local dropin_file="$2"
    local dropin_backup="$3"
    local had_dropin="$4"
    local restart_unit="${5:-1}"

    if (( had_dropin == 1 )); then
        install_pm2_dropin_atomically "$dropin_backup" "$dropin_file" || return 1
    else
        rm -f -- "$dropin_file" || return 1
        sync -f "$(dirname "$dropin_file")" || return 1
    fi
    systemctl_bounded daemon-reload || return 1
    (( restart_unit == 0 )) || systemctl_bounded --no-block restart "$pm2_unit" >/dev/null 2>&1
}

restore_pm2_dump_atomically() {
    local backup_file="$1"
    local target_file="$2"
    local temporary_file target_dir file_mode file_uid file_gid
    validate_pm2_dump_file "$backup_file" || return 1
    target_dir="$(dirname "$target_file")"
    [[ -d "$target_dir" && ! -L "$target_dir" ]] || return 1
    file_mode="$(stat -c '%a' "$backup_file" 2>/dev/null || true)"
    file_uid="$(stat -c '%u' "$backup_file" 2>/dev/null || true)"
    file_gid="$(stat -c '%g' "$backup_file" 2>/dev/null || true)"
    [[ "$file_mode" =~ ^[0-7]{3,4}$ && "$file_uid" == "0" && "$file_gid" =~ ^[0-9]+$ ]] || return 1
    temporary_file="$(mktemp "${target_file}.flowmaster-restore.XXXXXX")" || return 1
    if ! install -o "$file_uid" -g "$file_gid" -m "$file_mode" "$backup_file" "$temporary_file" || \
       ! sync -f "$temporary_file" || \
       ! mv -fT -- "$temporary_file" "$target_file" || \
       ! sync -f "$target_dir"; then
        rm -f -- "$temporary_file"
        return 1
    fi
    validate_pm2_dump_file "$target_file"
}

converge_known_pm2_migration() {
    local pm2_home="$1"
    local pm2_pid="$2"
    local pm2_unit pm2_starttime dropin_file work_dir temporary_candidate persistent_candidate dump_file
    local has_entries=1

    validate_pm2_home_directory "$pm2_home" || return 1
    for dump_file in "${pm2_home}/dump.pm2" "${pm2_home}/dump.pm2.bak"; do
        [[ -e "$dump_file" ]] || continue
        validate_pm2_dump_file "$dump_file" || return 1
        ! pm2_dump_contains_app "$dump_file" || return 1
    done
    [[ -r "${pm2_home}/dump.pm2" ]] || return 1
    pm2_unit="$(find_pm2_systemd_unit "$pm2_pid" "$pm2_home" 2>/dev/null || true)"
    [[ -n "$pm2_unit" ]] || return 1
    dropin_file="/etc/systemd/system/${pm2_unit}.d/zzzz-flowmaster-pm2-recovery.conf"
    is_known_flowmaster_pm2_dropin "$dropin_file" || return 1

    mkdir -p -- "$BACKUP_ROOT" || return 1
    work_dir="$(mktemp -d "${BACKUP_ROOT}/pm2-converge-$(date +%Y%m%d-%H%M%S).XXXXXX")" || return 1
    chmod 0700 "$work_dir" || return 1
    temporary_candidate="$work_dir/temporary.conf"
    persistent_candidate="$work_dir/persistent.conf"
    cat >"$temporary_candidate" <<'EOF' || return 1
[Service]
Environment=PIDUSAGE_USE_PS=false
Restart=no
ExecStop=
TimeoutStopSec=15s
TimeoutStopFailureMode=kill
KillMode=control-group
KillSignal=SIGKILL
SendSIGKILL=yes
EOF
    cat >"$persistent_candidate" <<'EOF' || return 1
[Service]
Environment=PIDUSAGE_USE_PS=false
EOF
    chmod 0644 "$temporary_candidate" "$persistent_candidate" || return 1

    pm2_dump_has_entries "${pm2_home}/dump.pm2" && has_entries=0
    if (( has_entries == 0 )); then
        install_pm2_dropin_atomically "$persistent_candidate" "$dropin_file" || return 1
        systemctl_bounded daemon-reload || return 1
        [[ "$(effective_pm2_pidusage_setting "$pm2_unit")" == "false" ]] || return 1
        log "已收敛上次未完成的 PM2 迁移配置，无需再次重启其他应用"
        return 0
    fi

    pm2_starttime="$(get_process_starttime "$pm2_pid" 2>/dev/null || true)"
    [[ -n "$pm2_starttime" ]] || return 1
    install_pm2_dropin_atomically "$temporary_candidate" "$dropin_file" || return 1
    systemctl_bounded daemon-reload || return 1
    verify_pm2_recovery_unit_settings "$pm2_unit" || return 1
    stop_pm2_systemd_unit "$pm2_unit" "$pm2_pid" "$pm2_starttime" || return 1
    systemctl_bounded disable "$pm2_unit" >/dev/null 2>&1 || return 1
    install_pm2_dropin_atomically "$persistent_candidate" "$dropin_file" || return 1
    systemctl_bounded daemon-reload || return 1
    [[ "$(systemctl_bounded show "$pm2_unit" --property=ActiveState --value 2>/dev/null || true)" != "active" ]] || return 1
    pm2_unit_cgroup_is_empty "$pm2_unit" || return 1
    log "已收敛上次未完成的空 PM2 迁移，并禁用空 unit: $pm2_unit"
}

converge_stopped_pm2_migrations() {
    local dropin_file dropin_dir pm2_unit service_environment pm2_home dump_file work_dir persistent_candidate
    local restarted_identity restarted_pid restarted_starttime has_entries=1 found=0
    local -a known_dropins=()
    shopt -s nullglob
    known_dropins=(/etc/systemd/system/pm2*.service.d/zzzz-flowmaster-pm2-recovery.conf)
    shopt -u nullglob

    for dropin_file in "${known_dropins[@]}"; do
        # 仅带 Restart=no/ExecStop= 的临时 drop-in 代表中断事务；永久配置可能是管理员主动停止。
        is_temporary_flowmaster_pm2_dropin "$dropin_file" || continue
        dropin_dir="$(dirname "$dropin_file")"
        pm2_unit="$(basename "$dropin_dir")"
        pm2_unit="${pm2_unit%.d}"
        [[ "$pm2_unit" =~ ^pm2[-_.@a-zA-Z0-9]+\.service$ ]] || continue
        [[ "$(systemctl_bounded show "$pm2_unit" --property=ActiveState --value 2>/dev/null || true)" != "active" ]] || continue
        pm2_unit_cgroup_is_empty "$pm2_unit" || return 1
        service_environment="$(systemctl_bounded show "$pm2_unit" --property=Environment --value 2>/dev/null || true)"
        pm2_home="$(tr ' ' '\n' <<<"$service_environment" | sed -n 's/^PM2_HOME=//p' | tail -n 1)"
        [[ "$pm2_home" == /* && "$pm2_home" != *[[:space:]]* ]] || return 1
        validate_pm2_home_directory "$pm2_home" || return 1
        [[ -r "${pm2_home}/dump.pm2" ]] || return 1
        for dump_file in "${pm2_home}/dump.pm2" "${pm2_home}/dump.pm2.bak"; do
            [[ -e "$dump_file" ]] || continue
            validate_pm2_dump_file "$dump_file" || return 1
            ! pm2_dump_contains_app "$dump_file" || return 1
        done

        mkdir -p -- "$BACKUP_ROOT" || return 1
        work_dir="$(mktemp -d "${BACKUP_ROOT}/pm2-converge-$(date +%Y%m%d-%H%M%S).XXXXXX")" || return 1
        chmod 0700 "$work_dir" || return 1
        persistent_candidate="$work_dir/persistent.conf"
        printf '%s\n' '[Service]' 'Environment=PIDUSAGE_USE_PS=false' >"$persistent_candidate" || return 1
        chmod 0644 "$persistent_candidate" || return 1
        install_pm2_dropin_atomically "$persistent_candidate" "$dropin_file" || return 1
        systemctl_bounded daemon-reload || return 1

        has_entries=1
        pm2_dump_has_entries "${pm2_home}/dump.pm2" && has_entries=0
        if (( has_entries == 0 )); then
            restarted_identity="$(start_pm2_systemd_unit "$pm2_unit" "$pm2_home")" || return 1
            restarted_pid="${restarted_identity%%:*}"
            restarted_starttime="${restarted_identity#*:}"
            [[ "$restarted_pid" =~ ^[1-9][0-9]*$ && "$restarted_starttime" =~ ^[1-9][0-9]*$ ]] || return 1
            verify_restarted_pm2 "$pm2_home" "${pm2_home}/dump.pm2" "$pm2_unit" "$restarted_pid" "$restarted_starttime" || return 1
            log "已从上次中断点恢复 PM2 的已保存应用: $pm2_unit"
        else
            systemctl_bounded disable "$pm2_unit" >/dev/null 2>&1 || return 1
            log "已禁用上次迁移留下的空 PM2 unit: $pm2_unit"
        fi
        found=1
    done
    (( found == 0 )) || log "PM2 中断恢复状态已收敛"
}

recover_unresponsive_pm2() (
    command -v pm2 >/dev/null 2>&1 || return 1
    command -v node >/dev/null 2>&1 || return 1
    command -v systemctl >/dev/null 2>&1 || return 1
    command -v flock >/dev/null 2>&1 || return 1

    local require_flowmaster="${1:-1}"
    local allow_responsive="${2:-0}"
    [[ "$require_flowmaster" == "0" || "$require_flowmaster" == "1" ]] || return 1
    [[ "$allow_responsive" == "0" || "$allow_responsive" == "1" ]] || return 1
    local pm2_home="${PM2_HOME:-/root/.pm2}"
    local pm2_pid_file="${pm2_home}/pm2.pid"
    local pm2_dump="${pm2_home}/dump.pm2"
    [[ -r "$pm2_pid_file" && -r "$pm2_dump" ]] || return 1

    local pm2_pid pm2_starttime probe_status=0 pm2_unit recovery_answer recovery_dir current_cgroup responsive=0
    local dropin_dir dropin_file dropin_backup="" dropin_candidate persistent_candidate legacy_candidate had_dropin=0
    local had_dump_backup=0 pm2_unit_exec pm2_cli_exec pm2_was_enabled=0
    local restarted_identity="" restarted_pid="" restarted_starttime="" expected_dump known_dropin_path
    local recovery_stage=0 recovery_success=0 recovery_external_change=0 handoff_state="inactive"
    exec {pm2_recovery_lock_fd}>/run/lock/flowmaster-pm2-recovery.lock || return 1
    flock -n "$pm2_recovery_lock_fd" || { warn "另一个 PM2 恢复流程正在运行"; return 1; }

    pm2_pid="$(<"$pm2_pid_file")"
    [[ "$pm2_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pm2_pid" >/dev/null 2>&1 || return 1
    pm2_starttime="$(get_process_starttime "$pm2_pid" 2>/dev/null || true)"
    [[ -n "$pm2_starttime" ]] || return 1

    timeout --signal=TERM --kill-after=2s 5s env PM2_HOME="$pm2_home" PIDUSAGE_USE_PS=false \
        pm2 ping >/dev/null 2>&1 || probe_status=$?
    if (( probe_status == 0 )); then
        responsive=1
        (( allow_responsive == 1 )) || return 1
    elif ! is_timeout_status "$probe_status"; then
        warn "PM2 健康探测失败，且不是可控超时，拒绝自动操作"
        return 1
    fi

    validate_pm2_home_directory "$pm2_home" || { warn "PM2_HOME 不是可信的 root 私有目录"; return 1; }
    validate_pm2_dump_file "$pm2_dump" || { warn "PM2 dump.pm2 不是可信的 root 普通 JSON 文件"; return 1; }
    if pm2_dump_contains_app "$pm2_dump"; then
        handoff_state="$(pm2_saved_handoff_state "$pm2_dump")" || return 1
    fi
    if [[ -e "${pm2_home}/dump.pm2.bak" ]]; then
        validate_pm2_dump_file "${pm2_home}/dump.pm2.bak" || { warn "PM2 dump.pm2.bak 不可信，拒绝自动恢复"; return 1; }
        had_dump_backup=1
    fi
    pm2_unit="$(find_pm2_systemd_unit "$pm2_pid" "$pm2_home" || true)"
    if [[ -z "$pm2_unit" ]]; then
        current_cgroup="$(sed -n 's/^[^:]*:[^:]*://p' "/proc/${pm2_pid}/cgroup" 2>/dev/null | tail -n 1)"
        warn "无法将 PM2 PID ${pm2_pid} 安全定位到独立的标准 root pm2-*.service，拒绝直接杀死 daemon 以免留下孤儿或重复应用。"
        [[ -z "$current_cgroup" ]] || warn "检测到的 PM2 cgroup: $current_cgroup"
        return 1
    fi
    if systemctl_bounded is-enabled --quiet "$pm2_unit" 2>/dev/null; then
        pm2_was_enabled=1
    fi
    pm2_unit_exec="$(systemctl_bounded show "$pm2_unit" --property=ExecStart --value 2>/dev/null || true)"
    pm2_unit_exec="${pm2_unit_exec#*path=}"
    pm2_unit_exec="${pm2_unit_exec%% *}"
    pm2_cli_exec="$(command -v pm2)"
    if [[ "$pm2_unit_exec" != /* || ! -x "$pm2_unit_exec" || \
          "$(readlink -f "$pm2_unit_exec" 2>/dev/null || true)" != "$(readlink -f "$pm2_cli_exec" 2>/dev/null || true)" ]]; then
        warn "当前 pm2 CLI 与 ${pm2_unit} 的 ExecStart 不是同一可执行文件，拒绝跨版本恢复"
        return 1
    fi
    if (( require_flowmaster == 1 )) && ! pm2_dump_contains_app "$pm2_dump"; then
        known_dropin_path="/etc/systemd/system/${pm2_unit}.d/zzzz-flowmaster-pm2-recovery.conf"
        if (( responsive == 0 )) && is_known_flowmaster_pm2_dropin "$known_dropin_path"; then
            warn "PM2 清单已不含 FlowMaster，但检测到可信的 FlowMaster 1.1.19 恢复配置；按故障现场兼容路径继续收敛。"
            require_flowmaster=0
        else
            warn "PM2 已保存清单中没有 FlowMaster，且无法确认这是 FlowMaster 迁移留下的故障现场"
            return 1
        fi
    fi

    if (( responsive == 1 )); then
        warn "检测到旧 FlowMaster 仍由 ${pm2_unit} 管理（PM2 PID ${pm2_pid}）。"
    else
        warn "PM2 守护进程无响应（PID ${pm2_pid}）。"
    fi
    warn "无需重启主机。安装器将有界停止 ${pm2_unit}，离线移除旧 FlowMaster，然后只恢复以下其他已保存应用："
    print_pm2_recovery_apps "$pm2_dump" || return 1
    warn "未执行 pm2 save 的应用无法从现有保存清单中可靠恢复；确认后会先备份 PM2 主/备清单与 unit 配置。"
    if [[ "${FLOWMASTER_RECOVER_UNRESPONSIVE_PM2:-}" == "1" ]]; then
        recovery_answer="RECOVER-PM2"
    elif [[ "${FLOWMASTER_RECOVER_UNRESPONSIVE_PM2:-}" == "0" || ! -t 0 ]]; then
        warn "未授权短暂停止 PM2 管理的应用，已保持现状。非交互运行可显式设置 FLOWMASTER_RECOVER_UNRESPONSIVE_PM2=1。"
        return 1
    else
        if ! read -r -p "如确认有界停止 PM2 并恢复上述其他应用，请输入 RECOVER-PM2: " recovery_answer; then
            warn "未读取到恢复确认，已保持现状"
            return 1
        fi
    fi
    [[ "$recovery_answer" == "RECOVER-PM2" ]] || { warn "已取消 PM2 原地恢复"; return 1; }

    mkdir -p "$BACKUP_ROOT" || return 1
    recovery_dir="$(mktemp -d "${BACKUP_ROOT}/pm2-recovery-$(date +%Y%m%d-%H%M%S).XXXXXX")" || return 1
    chmod 0700 "$recovery_dir" || return 1
    cp -a -- "$pm2_dump" "$recovery_dir/dump.pm2.original" || return 1
    if [[ -e "${pm2_home}/dump.pm2.bak" ]]; then
        cp -a -- "${pm2_home}/dump.pm2.bak" "$recovery_dir/dump.pm2.bak.original" || return 1
    fi
    systemctl_bounded cat "$pm2_unit" >"$recovery_dir/${pm2_unit}.txt" 2>/dev/null || return 1
    chmod 0600 "$recovery_dir/dump.pm2.original" "$recovery_dir/${pm2_unit}.txt" || return 1
    [[ ! -e "$recovery_dir/dump.pm2.bak.original" ]] || chmod 0600 "$recovery_dir/dump.pm2.bak.original" || return 1
    log "PM2 恢复前备份已写入: $recovery_dir"

    dropin_dir="/etc/systemd/system/${pm2_unit}.d"
    dropin_file="${dropin_dir}/zzzz-flowmaster-pm2-recovery.conf"
    validate_pm2_dropin_directory "$dropin_dir" || { warn "PM2 drop-in 目录不可信，拒绝写入"; return 1; }
    dropin_candidate="$recovery_dir/zzzz-flowmaster-pm2-recovery.conf.temporary"
    persistent_candidate="$recovery_dir/zzzz-flowmaster-pm2-recovery.conf.persistent"
    legacy_candidate="$recovery_dir/zzzz-flowmaster-pm2-recovery.conf.v1.1.19"
    cat >"$dropin_candidate" <<'EOF' || return 1
[Service]
Environment=PIDUSAGE_USE_PS=false
Restart=no
ExecStop=
TimeoutStopSec=15s
TimeoutStopFailureMode=kill
KillMode=control-group
KillSignal=SIGKILL
SendSIGKILL=yes
EOF
    chmod 0644 "$dropin_candidate" || return 1
    cat >"$persistent_candidate" <<'EOF' || return 1
[Service]
Environment=PIDUSAGE_USE_PS=false
EOF
    chmod 0644 "$persistent_candidate" || return 1
    cat >"$legacy_candidate" <<'EOF' || return 1
[Service]
Environment=PIDUSAGE_USE_PS=false
TimeoutStopSec=15s
TimeoutStopFailureMode=kill
KillMode=control-group
SendSIGKILL=yes
EOF
    chmod 0644 "$legacy_candidate" || return 1
    if [[ -e "$dropin_file" || -L "$dropin_file" ]]; then
        [[ -f "$dropin_file" && ! -L "$dropin_file" && "$(stat -c '%u' "$dropin_file" 2>/dev/null || true)" == "0" ]] || {
            warn "PM2 drop-in 不是可信的 root 普通文件，拒绝覆盖"
            return 1
        }
        if ! cmp -s -- "$dropin_file" "$dropin_candidate" && \
           ! cmp -s -- "$dropin_file" "$persistent_candidate" && \
           ! cmp -s -- "$dropin_file" "$legacy_candidate"; then
            warn "${dropin_file} 已存在且不是 FlowMaster 预期配置，拒绝覆盖"
            return 1
        fi
        dropin_backup="$recovery_dir/zzzz-flowmaster-pm2-recovery.conf.original"
        cp -a -- "$dropin_file" "$dropin_backup" || return 1
        had_dropin=1
    fi

    # 从修改 drop-in 开始，任何信号或错误都必须恢复到一个可运行、可再次尝试的状态。
    pm2_recovery_rollback() {
        local original_status="$?" current_pid current_starttime restored_identity restored_pid restored_starttime
        trap - EXIT
        trap '' INT TERM HUP
        (( recovery_success == 0 && recovery_stage > 0 )) || return "$original_status"
        set +e

        if (( recovery_external_change == 1 )); then
            warn "PM2 清单在事务期间被外部修改，已保持 unit 停止且未覆盖现场；备份位于: $recovery_dir"
            return "$original_status"
        fi

        if (( recovery_stage == 1 )) && process_matches_starttime "$pm2_pid" "$pm2_starttime"; then
            restore_pm2_dropin "$pm2_unit" "$dropin_file" "$dropin_backup" "$had_dropin" 0
            warn "PM2 在停止前失败，已恢复原 unit 配置且未重启应用"
            return "$original_status"
        fi

        if (( recovery_stage < 4 )); then
            current_pid="$(systemctl_bounded show "$pm2_unit" --property=MainPID --value 2>/dev/null || true)"
            if [[ "$current_pid" =~ ^[1-9][0-9]*$ ]]; then
                current_starttime="$(get_process_starttime "$current_pid" 2>/dev/null || true)"
                if [[ -n "$current_starttime" ]]; then
                    systemctl_bounded kill --kill-whom=all --signal=KILL "$pm2_unit" >/dev/null 2>&1
                    systemctl_bounded --no-block stop "$pm2_unit" >/dev/null 2>&1
                    for _ in {1..100}; do
                        pm2_unit_cgroup_is_empty "$pm2_unit" && break
                        sleep 0.1
                    done
                fi
            fi

            if restore_pm2_dump_atomically "$recovery_dir/dump.pm2.original" "$pm2_dump"; then
                if [[ -e "$recovery_dir/dump.pm2.bak.original" ]]; then
                    restore_pm2_dump_atomically "$recovery_dir/dump.pm2.bak.original" "${pm2_home}/dump.pm2.bak"
                elif [[ -e "${pm2_home}/dump.pm2.bak" ]]; then
                    validate_pm2_dump_file "${pm2_home}/dump.pm2.bak" && rm -f -- "${pm2_home}/dump.pm2.bak"
                fi
                install_pm2_dropin_atomically "$persistent_candidate" "$dropin_file"
                systemctl_bounded daemon-reload
                (( pm2_was_enabled == 0 )) || systemctl_bounded enable "$pm2_unit" >/dev/null 2>&1
                restored_identity="$(start_pm2_systemd_unit "$pm2_unit" "$pm2_home")"
                restored_pid="${restored_identity%%:*}"
                restored_starttime="${restored_identity#*:}"
                if [[ "$restored_pid" =~ ^[1-9][0-9]*$ && "$restored_starttime" =~ ^[1-9][0-9]*$ ]] && \
                   verify_restarted_pm2 "$pm2_home" "$recovery_dir/dump.pm2.original" "$pm2_unit" "$restored_pid" "$restored_starttime"; then
                    # marker 可能已在 recovery_stage=3 写入；既然原 PM2 已完整恢复，
                    # 必须同步撤销交接标记，避免外层事务再启动一个 systemd 副本。
                    clear_pm2_handoff || {
                        warn "PM2 已恢复，但无法清除 systemd 交接标记；事务回滚将保持失败状态"
                        return 1
                    }
                    warn "PM2 迁移中断，已使用原清单恢复全部已保存应用；可直接重新运行安装器"
                    return "$original_status"
                fi
            fi
            warn "PM2 自动回滚未完整通过验证；原清单与 unit 备份位于: $recovery_dir"
            return "$original_status"
        fi

        # 已验证过滤后的应用集合后不再把旧 FlowMaster 拉回；只收敛安全配置。
        if ! pm2_dump_has_entries "$expected_dump"; then
            if systemctl_bounded disable "$pm2_unit" >/dev/null 2>&1; then
                install_pm2_dropin_atomically "$persistent_candidate" "$dropin_file"
                systemctl_bounded daemon-reload
            fi
        else
            install_pm2_dropin_atomically "$persistent_candidate" "$dropin_file"
            systemctl_bounded daemon-reload
        fi
        warn "PM2 应用迁移已完成，但收尾检查失败；安装器下次运行会继续收敛安全配置"
        return "$original_status"
    }
    trap pm2_recovery_rollback EXIT
    trap 'exit 130' INT TERM HUP

    recovery_stage=1
    install_pm2_dropin_atomically "$dropin_candidate" "$dropin_file" || return 1
    if ! systemctl_bounded daemon-reload; then
        restore_pm2_dropin "$pm2_unit" "$dropin_file" "$dropin_backup" "$had_dropin" 0 || true
        return 1
    fi
    if ! verify_pm2_recovery_unit_settings "$pm2_unit"; then
        warn "PM2 unit 的有效停止边界被其他配置覆盖，已在停止前安全退出"
        restore_pm2_dropin "$pm2_unit" "$dropin_file" "$dropin_backup" "$had_dropin" 0 || true
        return 1
    fi
    if ! cmp -s -- "$pm2_dump" "$recovery_dir/dump.pm2.original" || \
       { (( had_dump_backup == 1 )) && ! cmp -s -- "${pm2_home}/dump.pm2.bak" "$recovery_dir/dump.pm2.bak.original"; } || \
       { (( had_dump_backup == 0 )) && [[ -e "${pm2_home}/dump.pm2.bak" ]]; }; then
        warn "PM2 清单在确认后发生变化，已取消停止以避免恢复错误应用集合"
        restore_pm2_dropin "$pm2_unit" "$dropin_file" "$dropin_backup" "$had_dropin" 0 || true
        return 1
    fi

    if ! stop_pm2_systemd_unit "$pm2_unit" "$pm2_pid" "$pm2_starttime"; then
        warn "PM2 unit 未在 45 秒内完全停止，已保留 15 秒有界配置并停止后续安装。"
        warn "PM2 清单备份位于: $recovery_dir"
        return 1
    fi
    recovery_stage=2

    if ! cmp -s -- "$pm2_dump" "$recovery_dir/dump.pm2.original" || \
       { (( had_dump_backup == 1 )) && ! cmp -s -- "${pm2_home}/dump.pm2.bak" "$recovery_dir/dump.pm2.bak.original"; } || \
       { (( had_dump_backup == 0 )) && [[ -e "${pm2_home}/dump.pm2.bak" ]]; }; then
        recovery_external_change=1
        warn "PM2 清单在 unit 停止期间发生变化；为避免恢复未确认的应用集合，已保持 unit 停止。"
        warn "停止前清单备份位于: $recovery_dir"
        return 1
    fi
    validate_pm2_dump_file "$pm2_dump" || {
        recovery_external_change=1
        warn "PM2 停止后 dump.pm2 不再可信；为避免启动错误应用，已保持 unit 停止。备份位于: $recovery_dir"
        return 1
    }
    if [[ -e "${pm2_home}/dump.pm2.bak" ]]; then
        validate_pm2_dump_file "${pm2_home}/dump.pm2.bak" || {
            recovery_external_change=1
            warn "PM2 停止后 dump.pm2.bak 不再可信；已保持 unit 停止。备份位于: $recovery_dir"
            return 1
        }
    fi
    if ! sanitize_saved_pm2_dumps "$pm2_home" "$recovery_dir"; then
        warn "PM2 离线清单过滤失败，已保持 unit 停止。备份位于: $recovery_dir"
        return 1
    fi
    recovery_stage=3
    expected_dump="$recovery_dir/dump.pm2.filtered"
    cp -a -- "$pm2_dump" "$expected_dump" || return 1
    chmod 0600 "$expected_dump" || return 1

    if pm2_dump_has_entries "$expected_dump"; then
        restarted_identity="$(start_pm2_systemd_unit "$pm2_unit" "$pm2_home")" || {
            warn "PM2 已离线移除旧 FlowMaster，但其他已保存应用恢复失败；已停止后续安装。"
            warn "PM2 清单备份位于: $recovery_dir"
            return 1
        }
        restarted_pid="${restarted_identity%%:*}"
        restarted_starttime="${restarted_identity#*:}"
        if [[ ! "$restarted_pid" =~ ^[1-9][0-9]*$ || ! "$restarted_starttime" =~ ^[1-9][0-9]*$ ]] || \
           ! verify_restarted_pm2 "$pm2_home" "$expected_dump" "$pm2_unit" "$restarted_pid" "$restarted_starttime"; then
            warn "PM2 已离线移除旧 FlowMaster，但其他已保存应用集合或运行状态验证失败。"
            warn "已保留有界 PM2 配置并停止后续安装；备份位于: $recovery_dir"
            return 1
        fi
    else
        systemctl_bounded reset-failed "$pm2_unit" >/dev/null 2>&1 || true
        if [[ "$(systemctl_bounded show "$pm2_unit" --property=ActiveState --value 2>/dev/null || true)" == "active" ]] || \
           ! pm2_unit_cgroup_is_empty "$pm2_unit"; then
            warn "PM2 保存清单只剩空集，但 unit 未保持完全停止；已停止后续安装"
            return 1
        fi
    fi
    if ! pm2_dump_has_entries "$expected_dump"; then
        systemctl_bounded disable "$pm2_unit" >/dev/null 2>&1 || {
            warn "空 PM2 unit 未能禁用；保留临时安全配置供下次安装继续收敛"
            return 1
        }
    fi

    if ! install_pm2_dropin_atomically "$persistent_candidate" "$dropin_file" || \
       ! systemctl_bounded daemon-reload || \
       [[ "$(effective_pm2_pidusage_setting "$pm2_unit")" != "false" ]]; then
        warn "PM2 离线迁移已完成，但 PIDUSAGE_USE_PS=false 未能持久化；保留有界配置并停止后续安装"
        install_pm2_dropin_atomically "$dropin_candidate" "$dropin_file" || true
        systemctl_bounded daemon-reload || true
        return 1
    fi

    record_pm2_handoff "$handoff_state" || {
        warn "无法持久记录 PM2 到 systemd 的交接状态，正在恢复 PM2 原清单"
        return 1
    }
    recovery_stage=4

    if pm2_dump_has_entries "$expected_dump"; then
        log "旧 FlowMaster 已从 PM2 离线移除；其他已保存应用已在不重启主机的情况下恢复"
    else
        log "PM2 保存清单中只有旧 FlowMaster；该条目已离线移除，${pm2_unit} 已保持停止"
    fi
    recovery_success=1
    return 0
)

retire_legacy_pm2_app() {
    command -v pm2 >/dev/null 2>&1 || return 0

    converge_stopped_pm2_migrations || return 1

    local pm2_home="${PM2_HOME:-/root/.pm2}"
    local pm2_pid_file="${pm2_home}/pm2.pid"
    local pm2_pid="" presence presence_status=0 handoff_state="inactive"
    if [[ -r "${pm2_home}/dump.pm2" ]] && validate_pm2_dump_file "${pm2_home}/dump.pm2" && \
       pm2_dump_contains_app "${pm2_home}/dump.pm2"; then
        handoff_state="$(pm2_saved_handoff_state "${pm2_home}/dump.pm2")" || return 1
    fi
    if [[ ! -r "$pm2_pid_file" ]]; then
        finalize_pm2_dump_migration "$pm2_home" "$handoff_state" || return 1
        return 0
    fi
    pm2_pid="$(<"$pm2_pid_file")"
    if [[ ! "$pm2_pid" =~ ^[1-9][0-9]*$ ]] || ! kill -0 "$pm2_pid" >/dev/null 2>&1 || ! is_root_pm2_daemon "$pm2_pid"; then
        finalize_pm2_dump_migration "$pm2_home" "$handoff_state" || return 1
        return 0
    fi

    log "检查旧版 PM2 中的 FlowMaster..."
    presence="$(get_pm2_app_presence "$pm2_home")" || presence_status=$?
    if is_timeout_status "$presence_status"; then
        warn "PM2 守护进程无响应，改用单次离线迁移；不会调用会递归执行 ps 的 pm2 delete。"
        recover_unresponsive_pm2 1 0 || return 1
        return 0
    fi
    if (( presence_status != 0 )); then
        warn "无法读取 PM2 进程清单，拒绝把通信错误误判为 FlowMaster 不存在"
        return 1
    fi
    if [[ "$presence" == "absent" ]]; then
        finalize_pm2_dump_migration "$pm2_home" "$handoff_state" || return 1
        local known_dropin_path pm2_unit
        pm2_unit="$(find_pm2_systemd_unit "$pm2_pid" "$pm2_home" 2>/dev/null || true)"
        known_dropin_path="/etc/systemd/system/${pm2_unit}.d/zzzz-flowmaster-pm2-recovery.conf"
        if [[ -n "$pm2_unit" ]] && is_known_flowmaster_pm2_dropin "$known_dropin_path"; then
            mkdir -p -- "$BACKUP_ROOT" || return 1
            converge_known_pm2_migration "$pm2_home" "$pm2_pid" || return 1
        fi
        return 0
    fi

    warn "旧 FlowMaster 将通过 PM2 unit 的单次有界停止和离线清单过滤迁移，避免触发 PM2 5.x TreeKill 的递归 ps。"
    recover_unresponsive_pm2 1 1 || return 1
    return 0
}

systemctl_bounded() {
    timeout --signal=TERM --kill-after=2s 5s systemctl "$@"
}

query_systemd_unit_state() {
    local unit_name="$1" output key value
    local load_state="" active_state="" unit_file_state="" main_pid="" control_pid=""
    output="$(systemctl_bounded show "$unit_name" \
        --property=LoadState --property=ActiveState --property=UnitFileState \
        --property=MainPID --property=ControlPID 2>/dev/null)" || return 1
    while IFS='=' read -r key value; do
        case "$key" in
            LoadState) load_state="$value" ;;
            ActiveState) active_state="$value" ;;
            UnitFileState) unit_file_state="$value" ;;
            MainPID) main_pid="$value" ;;
            ControlPID) control_pid="$value" ;;
        esac
    done <<<"$output"

    [[ "$load_state" == "loaded" || "$load_state" == "not-found" ]] || return 1
    [[ "$active_state" =~ ^(active|inactive|failed|activating|deactivating|reloading)$ ]] || return 1
    [[ "$main_pid" =~ ^[0-9]+$ && "$control_pid" =~ ^[0-9]+$ ]] || return 1
    if [[ "$load_state" == "not-found" ]]; then
        unit_file_state="not-found"
    else
        [[ "$unit_file_state" =~ ^(enabled|enabled-runtime|disabled|static|indirect|generated|transient|linked|linked-runtime|masked)$ ]] || return 1
    fi
    printf '%s|%s|%s|%s|%s\n' "$load_state" "$active_state" "$unit_file_state" "$main_pid" "$control_pid"
}

stop_systemd_service() {
    local state_line load_state active_state unit_file_state main_pid control_pid deadline
    state_line="$(query_systemd_unit_state "$SERVICE_NAME")" || {
        warn "无法可靠读取 $SERVICE_NAME 状态，拒绝把查询故障当作服务不存在"
        return 1
    }
    IFS='|' read -r load_state active_state unit_file_state main_pid control_pid <<<"$state_line"
    [[ "$load_state" != "not-found" ]] || return 0

    if [[ "$active_state" =~ ^(inactive|failed)$ && "$main_pid" == "0" && "$control_pid" == "0" ]]; then
        return 0
    fi
    systemctl_bounded --no-block stop "$SERVICE_NAME" >/dev/null 2>&1 || {
        warn "无法停止 $SERVICE_NAME，拒绝继续替换程序文件"
        return 1
    }
    deadline=$((SECONDS + 30))
    while (( SECONDS < deadline )); do
        state_line="$(query_systemd_unit_state "$SERVICE_NAME")" || {
            warn "停止后无法确认 $SERVICE_NAME 状态"
            return 1
        }
        IFS='|' read -r load_state active_state unit_file_state main_pid control_pid <<<"$state_line"
        [[ "$load_state" != "not-found" ]] || return 0
        if [[ "$active_state" =~ ^(inactive|failed)$ && "$main_pid" == "0" && "$control_pid" == "0" ]]; then
            return 0
        fi
        sleep 0.25
    done
    warn "$SERVICE_NAME 未在 30 秒内完全停止"
    return 1
}

start_existing_systemd_service() {
    local state_line load_state active_state unit_file_state main_pid control_pid deadline
    systemctl_bounded --no-block start "$SERVICE_NAME" >/dev/null 2>&1 || return 1
    deadline=$((SECONDS + 30))
    while (( SECONDS < deadline )); do
        state_line="$(query_systemd_unit_state "$SERVICE_NAME")" || return 1
        IFS='|' read -r load_state active_state unit_file_state main_pid control_pid <<<"$state_line"
        if [[ "$load_state" == "loaded" && "$active_state" == "active" && "$main_pid" =~ ^[1-9][0-9]*$ ]]; then
            return 0
        fi
        [[ "$active_state" != "failed" ]] || return 1
        sleep 0.25
    done
    return 1
}

atomic_install_file() {
    local source_file="$1"
    local target_file="$2"
    local mode="$3"
    local target_dir temporary_file
    target_dir="$(dirname "$target_file")"
    [[ -d "$target_dir" && ! -L "$target_dir" ]] || return 1
    temporary_file="$(mktemp "${target_file}.tmp.XXXXXX")" || return 1
    if ! install -o root -g root -m "$mode" "$source_file" "$temporary_file" || \
       ! sync -f "$temporary_file" || \
       ! mv -fT -- "$temporary_file" "$target_file" || \
       ! sync -f "$target_dir"; then
        rm -f -- "$temporary_file"
        return 1
    fi
}

resolve_nologin_shell() {
    local nologin_shell resolved_shell
    for nologin_shell in /usr/sbin/nologin /sbin/nologin; do
        [[ -x "$nologin_shell" ]] || continue
        resolved_shell="$(readlink -f -- "$nologin_shell" 2>/dev/null || true)"
        [[ -n "$resolved_shell" && -x "$resolved_shell" ]] || continue
        printf '%s\n' "$resolved_shell"
        return 0
    done
    warn "系统缺少可信的 nologin，无法创建或验证受限服务账号"
    return 1
}

validate_existing_service_identity() {
    local group_record passwd_record shadow_record
    local group_name service_gid group_members passwd_name service_uid primary_gid service_home service_shell
    local expected_shell actual_shell shadow_password vnstat_gid="" member gid gid_list
    local passwd_conflict group_conflict
    local -a explicit_members=() account_gids=()

    group_record="$(getent group "$SERVICE_USER")" || return 1
    passwd_record="$(getent passwd "$SERVICE_USER")" || return 1
    shadow_record="$(getent shadow "$SERVICE_USER")" || {
        warn "无法验证 $SERVICE_USER 的密码锁定状态，拒绝接管现有账号"
        return 1
    }
    IFS=: read -r group_name _ service_gid group_members <<<"$group_record"
    IFS=: read -r passwd_name _ service_uid primary_gid _ service_home service_shell <<<"$passwd_record"
    IFS=: read -r _ shadow_password _ <<<"$shadow_record"

    [[ "$group_name" == "$SERVICE_USER" && "$service_gid" =~ ^[0-9]+$ && \
       "$service_gid" != "0" && "$service_gid" -lt 1000 ]] || {
        warn "已存在的 $SERVICE_USER 组不是可信的专用系统服务组"
        return 1
    }
    [[ "$passwd_name" == "$SERVICE_USER" && "$service_uid" =~ ^[0-9]+$ && \
       "$service_uid" != "0" && "$service_uid" -lt 1000 && \
       "$primary_gid" == "$service_gid" && "$service_home" == "$APP_DIR" ]] || {
        warn "已存在的 $SERVICE_USER 账号 UID、主组或主目录不符合专用服务账号约束"
        return 1
    }

    expected_shell="$(resolve_nologin_shell)" || return 1
    actual_shell="$(readlink -f -- "$service_shell" 2>/dev/null || true)"
    [[ -n "$actual_shell" && "$actual_shell" == "$expected_shell" ]] || {
        warn "已存在的 $SERVICE_USER 账号不是 nologin 账号，拒绝接管"
        return 1
    }
    case "${shadow_password:0:1}" in
        '!'|'*') ;;
        *)
            warn "已存在的 $SERVICE_USER 账号密码未锁定，拒绝接管"
            return 1
            ;;
    esac

    IFS=',' read -r -a explicit_members <<<"$group_members"
    for member in "${explicit_members[@]}"; do
        [[ -z "$member" || "$member" == "$SERVICE_USER" ]] || {
            warn "$SERVICE_USER 组包含其他账号 $member，拒绝授予其程序配置读取权限"
            return 1
        }
    done

    passwd_conflict="$({ getent passwd || exit 1; } | awk -F: \
        -v name="$SERVICE_USER" -v uid="$service_uid" -v gid="$service_gid" \
        '$1 != name && ($3 == uid || $4 == gid) && conflict == "" { conflict = $1 } END { print conflict }')" || return 1
    [[ -z "$passwd_conflict" ]] || {
        warn "$SERVICE_USER 的 UID 或主组还被账号 $passwd_conflict 使用，拒绝作为专用服务身份"
        return 1
    }
    group_conflict="$({ getent group || exit 1; } | awk -F: \
        -v name="$SERVICE_USER" -v gid="$service_gid" \
        '$1 != name && $3 == gid && conflict == "" { conflict = $1 } END { print conflict }')" || return 1
    [[ -z "$group_conflict" ]] || {
        warn "$SERVICE_USER 的 GID 还被组 $group_conflict 使用，拒绝作为专用服务组"
        return 1
    }

    if getent group vnstat >/dev/null 2>&1; then
        vnstat_gid="$(getent group vnstat | awk -F: 'NR == 1 { print $3 }')"
        [[ "$vnstat_gid" =~ ^[0-9]+$ && "$vnstat_gid" != "0" && "$vnstat_gid" -lt 1000 ]] || {
            warn "已存在的 vnstat 组不是可信的系统服务组"
            return 1
        }
    fi
    gid_list="$(id -G "$SERVICE_USER")" || return 1
    read -r -a account_gids <<<"$gid_list"
    for gid in "${account_gids[@]}"; do
        [[ "$gid" == "$service_gid" || ( -n "$vnstat_gid" && "$gid" == "$vnstat_gid" ) ]] || {
            warn "$SERVICE_USER 账号属于非预期附属组 GID=$gid，拒绝作为隔离服务账号使用"
            return 1
        }
    done
}

validate_service_identity_preflight() {
    local group_exists=0 user_exists=0
    getent group "$SERVICE_USER" >/dev/null 2>&1 && group_exists=1
    getent passwd "$SERVICE_USER" >/dev/null 2>&1 && user_exists=1
    if (( group_exists == 0 && user_exists == 0 )); then
        return 0
    fi
    if (( group_exists != user_exists )); then
        warn "检测到不完整或冲突的 $SERVICE_USER 用户/组，拒绝接管现有系统身份"
        return 1
    fi
    validate_existing_service_identity
}

validate_environment_file() {
    local application_dir="$1"
    local environment_file="$application_dir/.env"
    if [[ ! -e "$environment_file" && ! -L "$environment_file" ]]; then
        return 0
    fi
    [[ -f "$environment_file" && ! -L "$environment_file" ]] || {
        warn "$environment_file 必须是普通文件；为避免 systemd 隔离后配置丢失，拒绝迁移符号链接或特殊文件"
        return 1
    }
}

validate_existing_environment_file() {
    validate_environment_file "$APP_DIR"
}

word_sets_equal() {
    local left="$1" right="$2" word candidate found
    local -a left_words=() right_words=()
    read -r -a left_words <<<"$left"
    read -r -a right_words <<<"$right"
    (( ${#left_words[@]} == ${#right_words[@]} )) || return 1

    for word in "${left_words[@]}"; do
        found=0
        for candidate in "${right_words[@]}"; do
            [[ "$word" == "$candidate" ]] && found=1
        done
        (( found == 1 )) || return 1
    done
    for word in "${right_words[@]}"; do
        found=0
        for candidate in "${left_words[@]}"; do
            [[ "$word" == "$candidate" ]] && found=1
        done
        (( found == 1 )) || return 1
    done
}

cleanup_created_service_identity() {
    local cleanup_failed=0 passwd_record group_record current_uid current_gid current_gids vnstat_gid
    local passwd_name passwd_uid passwd_gid passwd_home group_name group_gid group_members primary_group_user

    if (( DEPLOY_SERVICE_USER_CREATED == 1 )); then
        passwd_record="$(getent passwd "$SERVICE_USER" 2>/dev/null || true)"
        if [[ -n "$passwd_record" ]]; then
            IFS=: read -r passwd_name _ passwd_uid passwd_gid _ passwd_home _ <<<"$passwd_record"
            if [[ "$passwd_name" != "$SERVICE_USER" || "$passwd_uid" != "$DEPLOY_SERVICE_UID" || \
                  "$passwd_gid" != "$DEPLOY_SERVICE_GID" || "$passwd_home" != "$APP_DIR" ]]; then
                warn "本次创建的 $SERVICE_USER 账号身份在回滚前发生变化，拒绝自动删除"
                cleanup_failed=1
            elif ps -eo uid= 2>/dev/null | awk -v uid="$passwd_uid" '$1 == uid { found = 1 } END { exit !found }'; then
                warn "本次创建的 $SERVICE_USER 账号仍有运行进程，拒绝自动删除"
                cleanup_failed=1
            elif ! userdel "$SERVICE_USER"; then
                warn "无法删除本次事务创建的 $SERVICE_USER 账号"
                cleanup_failed=1
            elif getent passwd "$SERVICE_USER" >/dev/null 2>&1; then
                warn "删除后仍能查询到本次事务创建的 $SERVICE_USER 账号"
                cleanup_failed=1
            else
                DEPLOY_SERVICE_USER_CREATED=0
                DEPLOY_VNSTAT_MEMBERSHIP_ADDED=0
                DEPLOY_SERVICE_UID=""
            fi
        else
            DEPLOY_SERVICE_USER_CREATED=0
            DEPLOY_VNSTAT_MEMBERSHIP_ADDED=0
            DEPLOY_SERVICE_UID=""
        fi
    elif (( DEPLOY_VNSTAT_MEMBERSHIP_ADDED == 1 )); then
        current_uid="$(id -u "$SERVICE_USER" 2>/dev/null || true)"
        current_gid="$(id -g "$SERVICE_USER" 2>/dev/null || true)"
        vnstat_gid="$(getent group vnstat 2>/dev/null | awk -F: 'NR == 1 { print $3 }')"
        if [[ "$current_uid" != "$DEPLOY_SERVICE_UID" || "$current_gid" != "$DEPLOY_SERVICE_GID" || \
              "$vnstat_gid" != "$DEPLOY_VNSTAT_GID" ]]; then
            warn "服务账号或 vnstat 组在回滚前发生变化，拒绝自动移除组成员关系"
            cleanup_failed=1
        elif ! gpasswd --delete "$SERVICE_USER" vnstat >/dev/null; then
            warn "无法移除本次事务新增的 vnstat 组成员关系"
            cleanup_failed=1
        else
            current_gids="$(id -G "$SERVICE_USER" 2>/dev/null || true)"
            if [[ " $current_gids " == *" $vnstat_gid "* ]]; then
                warn "移除后服务账号仍属于 vnstat 组"
                cleanup_failed=1
            else
                DEPLOY_VNSTAT_MEMBERSHIP_ADDED=0
                DEPLOY_VNSTAT_GID=""
            fi
        fi
    fi

    if (( DEPLOY_SERVICE_GROUP_CREATED == 1 )); then
        group_record="$(getent group "$SERVICE_USER" 2>/dev/null || true)"
        if [[ -n "$group_record" ]]; then
            IFS=: read -r group_name _ group_gid group_members <<<"$group_record"
            primary_group_user="$({ getent passwd || exit 1; } | awk -F: -v gid="$group_gid" '$4 == gid { print $1; exit }')" || {
                warn "无法检查本次创建服务组的使用情况，拒绝自动删除"
                cleanup_failed=1
                primary_group_user="__query_failed__"
            }
            if [[ "$group_name" != "$SERVICE_USER" || "$group_gid" != "$DEPLOY_SERVICE_GID" || \
                  -n "$group_members" || -n "$primary_group_user" ]]; then
                warn "本次创建的 $SERVICE_USER 组在回滚前被使用，拒绝自动删除"
                cleanup_failed=1
            elif ! groupdel "$SERVICE_USER"; then
                warn "无法删除本次事务创建的 $SERVICE_USER 组"
                cleanup_failed=1
            elif getent group "$SERVICE_USER" >/dev/null 2>&1; then
                warn "删除后仍能查询到本次事务创建的 $SERVICE_USER 组"
                cleanup_failed=1
            else
                DEPLOY_SERVICE_GROUP_CREATED=0
                DEPLOY_SERVICE_GID=""
            fi
        else
            DEPLOY_SERVICE_GROUP_CREATED=0
            DEPLOY_SERVICE_GID=""
        fi
    fi

    (( cleanup_failed == 0 ))
}

create_service_user() {
    local group_exists=0 user_exists=0 nologin_shell vnstat_gid current_gids
    getent group "$SERVICE_USER" >/dev/null 2>&1 && group_exists=1
    getent passwd "$SERVICE_USER" >/dev/null 2>&1 && user_exists=1

    if (( group_exists == 0 && user_exists == 0 )); then
        nologin_shell="$(resolve_nologin_shell)" || return 1
        groupadd --system "$SERVICE_USER" || return 1
        DEPLOY_SERVICE_GROUP_CREATED=1
        DEPLOY_SERVICE_GID="$(getent group "$SERVICE_USER" | awk -F: 'NR == 1 { print $3 }')" || {
            if groupdel "$SERVICE_USER" && ! getent group "$SERVICE_USER" >/dev/null 2>&1; then
                DEPLOY_SERVICE_GROUP_CREATED=0
                DEPLOY_SERVICE_GID=""
            else
                warn "无法验证或清理本次刚创建的 $SERVICE_USER 组"
            fi
            return 1
        }
        [[ "$DEPLOY_SERVICE_GID" =~ ^[1-9][0-9]*$ ]] || {
            cleanup_created_service_identity || true
            return 1
        }
        if ! useradd --system --gid "$SERVICE_USER" --home-dir "$APP_DIR" --shell "$nologin_shell" --no-create-home "$SERVICE_USER"; then
            cleanup_created_service_identity || true
            return 1
        fi
        DEPLOY_SERVICE_USER_CREATED=1
        DEPLOY_SERVICE_UID="$(id -u "$SERVICE_USER")" || {
            cleanup_created_service_identity || true
            return 1
        }
    elif (( group_exists != user_exists )); then
        warn "检测到不完整或冲突的 $SERVICE_USER 用户/组，拒绝接管现有系统身份"
        return 1
    else
        validate_existing_service_identity || return 1
        DEPLOY_SERVICE_UID="$(id -u "$SERVICE_USER")" || return 1
        DEPLOY_SERVICE_GID="$(id -g "$SERVICE_USER")" || return 1
    fi
    if getent group vnstat >/dev/null 2>&1; then
        vnstat_gid="$(getent group vnstat | awk -F: 'NR == 1 { print $3 }')"
        [[ "$vnstat_gid" =~ ^[0-9]+$ && "$vnstat_gid" != "0" && "$vnstat_gid" -lt 1000 ]] || {
            warn "已存在的 vnstat 组不是可信的系统服务组"
            return 1
        }
        current_gids="$(id -G "$SERVICE_USER")" || return 1
        if [[ " $current_gids " != *" $vnstat_gid "* ]]; then
            if ! usermod -a -G vnstat "$SERVICE_USER"; then
                current_gids="$(id -G "$SERVICE_USER" 2>/dev/null || true)"
                if [[ " $current_gids " == *" $vnstat_gid "* ]]; then
                    DEPLOY_VNSTAT_MEMBERSHIP_ADDED=1
                    DEPLOY_VNSTAT_GID="$vnstat_gid"
                fi
                return 1
            fi
            DEPLOY_VNSTAT_MEMBERSHIP_ADDED=1
            DEPLOY_VNSTAT_GID="$vnstat_gid"
        fi
    fi
    validate_existing_service_identity
}

secure_application_tree() {
    local target_dir="$1"
    [[ -d "$target_dir" && ! -L "$target_dir" ]] || return 1
    chown -R "root:${SERVICE_USER}" "$target_dir" || return 1
    chmod -R u=rwX,g=rX,o= "$target_dir" || return 1
    find "$target_dir" -type d -exec chmod 0750 {} + || return 1
    if [[ -f "$target_dir/.env" && ! -L "$target_dir/.env" ]]; then
        chmod 0640 "$target_dir/.env" || return 1
    fi
}

secure_application_files() {
    secure_application_tree "$APP_DIR"
}

validate_service_runtime_as_user() {
    local target_dir="$1" node_path configured_port
    node_path="$(readlink -f "$(command -v node)")"
    [[ "$node_path" == /* && -x "$node_path" ]] || return 1
    case "$node_path" in
        /root/*|/home/*|/run/user/*)
            warn "Node.js 位于 systemd ProtectHome 隔离范围内: $node_path；请改用 /usr 或 /opt 下的系统级 Node.js"
            return 1
            ;;
    esac

    runuser -u "$SERVICE_USER" -- env HOME=/nonexistent "$node_path" --version >/dev/null 2>&1 || {
        warn "Node.js 位于 $SERVICE_USER 无法执行的路径（常见于 /root/.nvm），请改用系统级 Node.js"
        return 1
    }
    runuser -u "$SERVICE_USER" -- env LC_ALL=C LANG=C vnstat --dbiflist 1 >/dev/null 2>&1 || {
        warn "$SERVICE_USER 无法读取 vnstat 数据库，请检查 vnstat 目录权限"
        return 1
    }
    configured_port="$(
        cd "$target_dir"
        runuser -u "$SERVICE_USER" -- env HOME=/nonexistent "$node_path" -e \
            "require('dotenv').config({path:'.env',quiet:true});const raw=String(process.env.PORT||'10089').trim();const n=/^\\d+$/.test(raw)?Number(raw):10089;process.stdout.write(String(Number.isSafeInteger(n)&&n>=1&&n<=65535?n:10089));"
    )" || return 1
    [[ "$configured_port" =~ ^[0-9]+$ ]] || return 1
    if (( configured_port < 1024 )); then
        warn "非 root 服务不能直接监听特权端口 $configured_port；请使用 1024-65535 并由反向代理提供公网端口"
        return 1
    fi
}

create_service_file() {
    local node_path unit_work_dir unit_candidate supplementary_groups=""
    node_path="$(readlink -f "$(command -v node)")"
    [[ "$node_path" == /* && -x "$node_path" ]] || return 1
    case "$node_path" in
        /root/*|/home/*|/run/user/*)
            warn "拒绝把 systemd 无法访问的用户目录 Node.js 写入服务 unit: $node_path"
            return 1
            ;;
    esac
    if getent group vnstat >/dev/null 2>&1; then
        supplementary_groups="SupplementaryGroups=vnstat"
    fi
    SERVICE_INSTANCE_TOKEN="$("$node_path" -e "process.stdout.write(require('node:crypto').randomBytes(32).toString('hex'))")" || return 1
    [[ "$SERVICE_INSTANCE_TOKEN" =~ ^[0-9a-f]{64}$ ]] || {
        warn "无法生成本次部署的实例校验令牌"
        SERVICE_INSTANCE_TOKEN=""
        return 1
    }
    unit_work_dir="$(mktemp -d /run/flowmaster-unit.XXXXXX)" || return 1
    unit_candidate="$unit_work_dir/$SERVICE_NAME"
    if ! cat >"$unit_candidate" <<EOF
[Unit]
Description=FlowMaster Network Traffic Monitor
After=network-online.target vnstat.service
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
$supplementary_groups
WorkingDirectory=$APP_DIR
Environment=NODE_ENV=production
Environment=FLOWMASTER_INSTANCE_TOKEN=$SERVICE_INSTANCE_TOKEN
ExecStart=$node_path $APP_DIR/server.js
Restart=on-failure
RestartSec=3
TimeoutStopSec=20
KillSignal=SIGTERM
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectHostname=true
ProtectClock=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectProc=invisible
ProcSubset=pid
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictNamespaces=true
LockPersonality=true
CapabilityBoundingSet=
AmbientCapabilities=
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
EOF
    then
        rm -rf -- "$unit_work_dir"
        return 1
    fi
    chmod 0644 "$unit_candidate" || { rm -rf -- "$unit_work_dir"; return 1; }
    if command -v systemd-analyze >/dev/null 2>&1; then
        timeout --signal=TERM --kill-after=2s 10s systemd-analyze verify "$unit_candidate" >/dev/null || {
            rm -rf -- "$unit_work_dir"
            return 1
        }
    fi
    atomic_install_file "$unit_candidate" "$SERVICE_FILE" 0644 || { rm -rf -- "$unit_work_dir"; return 1; }
    rm -rf -- "$unit_work_dir"
    systemctl_bounded daemon-reload
}

validate_effective_systemd_unit() {
    local output key value property expected_family found_family expected_supplementary_groups=""
    local -a effective_address_families=()
    local -A actual=()
    local -A required=(
        [Type]="simple"
        [User]="$SERVICE_USER"
        [Group]="$SERVICE_USER"
        [WorkingDirectory]="$APP_DIR"
        [Restart]="on-failure"
        [RestartUSec]="3s"
        [NoNewPrivileges]="yes"
        [PrivateTmp]="yes"
        [PrivateDevices]="yes"
        [ProtectSystem]="strict"
        [ProtectHome]="yes"
        [ProtectHostname]="yes"
        [ProtectClock]="yes"
        [ProtectKernelTunables]="yes"
        [ProtectKernelModules]="yes"
        [ProtectKernelLogs]="yes"
        [ProtectControlGroups]="yes"
        [ProtectProc]="invisible"
        [ProcSubset]="pid"
        [RestrictSUIDSGID]="yes"
        [RestrictRealtime]="yes"
        [RestrictNamespaces]="yes"
        [LockPersonality]="yes"
        [CapabilityBoundingSet]=""
        [AmbientCapabilities]=""
        [SystemCallArchitectures]="native"
    )

    output="$(systemctl_bounded show "$SERVICE_NAME" \
        --property=Type --property=User --property=Group --property=SupplementaryGroups \
        --property=WorkingDirectory --property=Restart --property=RestartUSec \
        --property=NoNewPrivileges \
        --property=PrivateTmp --property=PrivateDevices \
        --property=ProtectSystem --property=ProtectHome --property=ProtectHostname \
        --property=ProtectClock --property=ProtectKernelTunables \
        --property=ProtectKernelModules --property=ProtectKernelLogs \
        --property=ProtectControlGroups --property=ProtectProc --property=ProcSubset \
        --property=RestrictSUIDSGID --property=RestrictRealtime \
        --property=RestrictNamespaces --property=LockPersonality \
        --property=CapabilityBoundingSet --property=AmbientCapabilities \
        --property=RestrictAddressFamilies --property=SystemCallArchitectures \
        2>/dev/null)" || {
        warn "无法读取 $SERVICE_NAME 的有效安全配置"
        return 1
    }

    while IFS='=' read -r key value; do
        [[ -n "$key" ]] && actual["$key"]="$value"
    done <<<"$output"

    for property in "${!required[@]}"; do
        if [[ ! -v "actual[$property]" || "${actual[$property]}" != "${required[$property]}" ]]; then
            warn "$SERVICE_NAME 的有效安全配置被 drop-in 或外部配置覆盖: $property"
            return 1
        fi
    done

    if getent group vnstat >/dev/null 2>&1; then
        expected_supplementary_groups="vnstat"
    fi
    if [[ ! -v 'actual[SupplementaryGroups]' ]] || \
       ! word_sets_equal "${actual[SupplementaryGroups]}" "$expected_supplementary_groups"; then
        warn "$SERVICE_NAME 的有效附属组被 drop-in 或外部配置覆盖: SupplementaryGroups"
        return 1
    fi

    [[ -v 'actual[RestrictAddressFamilies]' ]] || {
        warn "$SERVICE_NAME 缺少有效 RestrictAddressFamilies 配置"
        return 1
    }
    read -r -a effective_address_families <<<"${actual[RestrictAddressFamilies]}"
    (( ${#effective_address_families[@]} == 3 )) || {
        warn "$SERVICE_NAME 的有效安全配置被 drop-in 或外部配置覆盖: RestrictAddressFamilies"
        return 1
    }
    for expected_family in AF_UNIX AF_INET AF_INET6; do
        found_family=0
        for property in "${effective_address_families[@]}"; do
            [[ "$property" == "$expected_family" ]] && found_family=1
        done
        (( found_family == 1 )) || {
            warn "$SERVICE_NAME 的有效安全配置被 drop-in 或外部配置覆盖: RestrictAddressFamilies"
            return 1
        }
    done
}

process_has_service_identity() {
    local process_pid="$1" expected_uid expected_gid expected_groups process_groups=""
    local field values first second third fourth extra group_id
    local uid_real="" uid_effective="" uid_saved="" uid_filesystem=""
    local gid_real="" gid_effective="" gid_saved="" gid_filesystem=""
    local -a process_group_ids=() expected_group_ids=()

    [[ "$process_pid" =~ ^[1-9][0-9]*$ && -r "/proc/${process_pid}/status" ]] || return 1
    expected_uid="$(id -u "$SERVICE_USER" 2>/dev/null)" || return 1
    expected_gid="$(id -g "$SERVICE_USER" 2>/dev/null)" || return 1
    expected_groups="$(id -G "$SERVICE_USER" 2>/dev/null)" || return 1
    while read -r field values; do
        case "$field" in
            Uid:)
                extra=""
                read -r first second third fourth extra <<<"$values"
                [[ -z "$extra" ]] || return 1
                uid_real="$first"
                uid_effective="$second"
                uid_saved="$third"
                uid_filesystem="$fourth"
                ;;
            Gid:)
                extra=""
                read -r first second third fourth extra <<<"$values"
                [[ -z "$extra" ]] || return 1
                gid_real="$first"
                gid_effective="$second"
                gid_saved="$third"
                gid_filesystem="$fourth"
                ;;
            Groups:)
                process_groups="$values"
                ;;
        esac
    done <"/proc/${process_pid}/status"

    read -r -a process_group_ids <<<"$process_groups"
    read -r -a expected_group_ids <<<"$expected_groups"
    (( ${#process_group_ids[@]} > 0 && ${#expected_group_ids[@]} > 0 )) || return 1
    for group_id in "${process_group_ids[@]}" "${expected_group_ids[@]}"; do
        [[ "$group_id" =~ ^[0-9]+$ ]] || return 1
    done

    [[ "$uid_real" == "$expected_uid" && "$uid_effective" == "$expected_uid" && \
       "$uid_saved" == "$expected_uid" && "$uid_filesystem" == "$expected_uid" && \
       "$gid_real" == "$expected_gid" && "$gid_effective" == "$expected_gid" && \
       "$gid_saved" == "$expected_gid" && "$gid_filesystem" == "$expected_gid" ]] && \
        word_sets_equal "$process_groups" "$expected_groups"
}

process_matches_service_command() {
    local process_pid="$1" expected_node_path actual_executable
    local -a command_arguments=()
    [[ "$process_pid" =~ ^[1-9][0-9]*$ && -r "/proc/${process_pid}/cmdline" && \
       -e "/proc/${process_pid}/exe" ]] || return 1
    expected_node_path="$(readlink -f "$(command -v node)" 2>/dev/null)" || return 1
    actual_executable="$(readlink -f "/proc/${process_pid}/exe" 2>/dev/null)" || return 1
    mapfile -d '' -t command_arguments <"/proc/${process_pid}/cmdline" || return 1
    (( ${#command_arguments[@]} == 2 )) || return 1
    [[ "$actual_executable" == "$expected_node_path" && \
       "${command_arguments[0]}" == "$expected_node_path" && \
       "${command_arguments[1]}" == "$APP_DIR/server.js" ]]
}

query_deployed_service_snapshot() {
    local output key value
    local active_state="" sub_state="" result="" main_pid="" restart_count=""
    output="$(systemctl_bounded show "$SERVICE_NAME" \
        --property=ActiveState --property=SubState --property=Result \
        --property=MainPID --property=NRestarts 2>/dev/null)" || return 1
    while IFS='=' read -r key value; do
        case "$key" in
            ActiveState) active_state="$value" ;;
            SubState) sub_state="$value" ;;
            Result) result="$value" ;;
            MainPID) main_pid="$value" ;;
            NRestarts) restart_count="$value" ;;
        esac
    done <<<"$output"
    [[ "$active_state" == "active" && "$sub_state" == "running" && "$result" == "success" && \
       "$main_pid" =~ ^[1-9][0-9]*$ && "$restart_count" =~ ^[0-9]+$ ]] || return 1
    printf '%s|%s\n' "$main_pid" "$restart_count"
}

version_response_matches_instance() {
    local response="$1" expected_version="$2" allow_legacy_response="${3:-0}"
    [[ "$allow_legacy_response" == "0" || "$allow_legacy_response" == "1" ]] || return 1
    node -e '
const response = JSON.parse(process.argv[1]);
const keys = Object.keys(response).sort();
const bound = keys.length === 2 && keys[0] === "instanceTokenMatched" && keys[1] === "version" &&
    response.version === process.argv[2] && response.instanceTokenMatched === true;
const legacy = process.argv[3] === "1" && keys.length === 1 && keys[0] === "version" &&
    response.version === process.argv[2];
if (!bound && !legacy) process.exit(1);
' "$response" "$expected_version" "$allow_legacy_response" >/dev/null 2>&1
}

start_systemd_service() {
    local expected_version="$1"
    local allow_legacy_response="${2:-0}"
    local health_url main_pid restart_count enable_state snapshot
    local stable_pid stable_restart_count stable_observations stable_failed
    [[ "$SERVICE_INSTANCE_TOKEN" =~ ^[0-9a-f]{64}$ ]] || {
        warn "缺少本次部署的实例校验令牌"
        return 1
    }
    [[ "$allow_legacy_response" == "0" || "$allow_legacy_response" == "1" ]] || return 1
    health_url="$(
        cd "$APP_DIR" || exit 1
        node -e "require('dotenv').config({ path: '.env', quiet: true }); let host = process.env.HOST || '0.0.0.0'; const port = Number.parseInt(process.env.PORT || '10089', 10); if (host === '0.0.0.0' || host === '::') host = '127.0.0.1'; if (host.includes(':')) host = '[' + host + ']'; process.stdout.write('http://' + host + ':' + (Number.isInteger(port) && port > 0 && port <= 65535 ? port : 10089) + '/api/version');"
    )" || {
        warn "无法根据已部署配置生成服务健康检查地址"
        return 1
    }
    systemctl_bounded enable "$SERVICE_NAME" >/dev/null 2>&1 || {
        warn "无法启用 $SERVICE_NAME 的开机自启"
        return 1
    }
    enable_state="$(systemctl_bounded is-enabled "$SERVICE_NAME" 2>/dev/null || true)"
    [[ "$enable_state" == "enabled" ]] || {
        warn "$SERVICE_NAME 未处于持久开机自启状态"
        return 1
    }
    validate_effective_systemd_unit || return 1
    systemctl_bounded reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl_bounded --no-block restart "$SERVICE_NAME" || {
        warn "无法提交 $SERVICE_NAME 重启请求"
        return 1
    }

    local deadline=$((SECONDS + 20))
    local response=""
    while (( SECONDS < deadline )); do
        snapshot="$(query_deployed_service_snapshot 2>/dev/null || true)"
        if [[ ! "$snapshot" =~ ^[1-9][0-9]*\|[0-9]+$ ]]; then
            sleep 0.5
            continue
        fi
        IFS='|' read -r main_pid restart_count <<<"$snapshot"
        if ! process_matches_service_command "$main_pid" || ! process_has_service_identity "$main_pid"; then
            sleep 0.5
            continue
        fi
        response="$(curl \
            --fail \
            --silent \
            --show-error \
            --noproxy '*' \
            --connect-timeout 1 \
            --max-time 2 \
            --header "X-FlowMaster-Instance-Token: ${SERVICE_INSTANCE_TOKEN}" \
            "$health_url" \
            2>/dev/null || true)"
        if version_response_matches_instance "$response" "$expected_version" "$allow_legacy_response"; then
            stable_pid="$main_pid"
            stable_restart_count="$restart_count"
            stable_observations=0
            stable_failed=0
            # RestartSec=3，连续观察超过四秒，拒绝“启动后短暂成功再崩溃”的实例。
            while (( stable_observations < 9 && SECONDS < deadline )); do
                snapshot="$(query_deployed_service_snapshot 2>/dev/null || true)"
                if [[ ! "$snapshot" =~ ^${stable_pid}\|${stable_restart_count}$ ]]; then
                    stable_failed=1
                    break
                fi
                if ! process_matches_service_command "$stable_pid" || ! process_has_service_identity "$stable_pid"; then
                    stable_failed=1
                    break
                fi
                ((stable_observations += 1))
                (( stable_observations == 9 )) || sleep 0.5
            done
            if (( stable_failed == 1 || stable_observations != 9 )); then
                sleep 0.5
                continue
            fi
            response="$(curl \
                --fail \
                --silent \
                --show-error \
                --noproxy '*' \
                --connect-timeout 1 \
                --max-time 2 \
                --header "X-FlowMaster-Instance-Token: ${SERVICE_INSTANCE_TOKEN}" \
                "$health_url" \
                2>/dev/null || true)"
            version_response_matches_instance "$response" "$expected_version" "$allow_legacy_response" || {
                sleep 0.5
                continue
            }
            enable_state="$(systemctl_bounded is-enabled "$SERVICE_NAME" 2>/dev/null || true)"
            [[ "$enable_state" == "enabled" ]] || {
                warn "$SERVICE_NAME 在启动验证期间失去持久开机自启状态"
                return 1
            }
            validate_effective_systemd_unit || return 1
            snapshot="$(query_deployed_service_snapshot 2>/dev/null || true)"
            if [[ ! "$snapshot" =~ ^${stable_pid}\|${stable_restart_count}$ ]] || \
               ! process_matches_service_command "$stable_pid" || \
               ! process_has_service_identity "$stable_pid"; then
                sleep 0.5
                continue
            fi
            return 0
        fi
        sleep 0.5
    done

    warn "systemd 服务启动验证失败，最近日志:"
    timeout --signal=TERM --kill-after=2s 5s journalctl -u "$SERVICE_NAME" -n 30 --no-pager >&2 || true
    return 1
}

validate_root_backup_directory() {
    local target_dir="$1" mode
    [[ -d "$target_dir" && ! -L "$target_dir" ]] || return 1
    validate_trusted_directory_chain "$target_dir" || return 1
    [[ "$(stat -c '%u' "$target_dir" 2>/dev/null || true)" == "0" ]] || return 1
    mode="$(stat -c '%a' "$target_dir" 2>/dev/null || true)"
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 8#22) == 0 ))
}

remove_deploy_state_dir() {
    [[ -n "$DEPLOY_STATE_DIR" ]] || return 0
    if [[ "$DEPLOY_STATE_DIR" == "$BACKUP_ROOT"/deploy-transaction-* && \
          -d "$DEPLOY_STATE_DIR" && ! -L "$DEPLOY_STATE_DIR" ]]; then
        rm -rf -- "$DEPLOY_STATE_DIR" || return 1
        sync -f "$BACKUP_ROOT" || return 1
        DEPLOY_STATE_DIR=""
        PM2_HANDOFF_MARKER=""
        return 0
    fi
    warn "拒绝清理非预期部署事务目录: $DEPLOY_STATE_DIR"
    return 1
}

begin_deploy_transaction() {
    local state_line load_state active_state unit_file_state main_pid control_pid
    DEPLOY_OLD_APP_MOVED=0
    DEPLOY_NEW_APP_INSTALLED=0
    DEPLOY_OLD_SERVICE_ACTIVE=0
    DEPLOY_OLD_SERVICE_ENABLE_STATE="disabled"
    DEPLOY_HAD_SERVICE_FILE=0
    DEPLOY_HAD_CONTROL_SCRIPT=0
    DEPLOY_SYSTEMD_TOUCHED=0
    DEPLOY_SERVICE_GROUP_CREATED=0
    DEPLOY_SERVICE_USER_CREATED=0
    DEPLOY_VNSTAT_MEMBERSHIP_ADDED=0
    DEPLOY_SERVICE_UID=""
    DEPLOY_SERVICE_GID=""
    DEPLOY_VNSTAT_GID=""
    SERVICE_INSTANCE_TOKEN=""
    ROLLBACK_DIR=""

    [[ ! -e "$APP_DIR" && ! -L "$APP_DIR" || -d "$APP_DIR" && ! -L "$APP_DIR" ]] || {
        warn "$APP_DIR 不是可信的普通目录，拒绝建立部署事务"
        return 1
    }
    [[ ! -e "$SERVICE_FILE" && ! -L "$SERVICE_FILE" || -f "$SERVICE_FILE" && ! -L "$SERVICE_FILE" ]] || {
        warn "$SERVICE_FILE 不是可信的普通文件，拒绝建立部署事务"
        return 1
    }
    [[ ! -e "$CONTROL_SCRIPT" && ! -L "$CONTROL_SCRIPT" || -f "$CONTROL_SCRIPT" && ! -L "$CONTROL_SCRIPT" ]] || {
        warn "$CONTROL_SCRIPT 不是可信的普通文件，拒绝建立部署事务"
        return 1
    }

    mkdir -p -- "$BACKUP_ROOT" || return 1
    validate_root_backup_directory "$BACKUP_ROOT" || {
        warn "$BACKUP_ROOT 必须是 root 所有且不可由组或其他用户写入的普通目录"
        return 1
    }
    DEPLOY_STATE_DIR="$(mktemp -d "${BACKUP_ROOT}/deploy-transaction-$(date +%Y%m%d-%H%M%S).XXXXXX")" || return 1
    chmod 0700 "$DEPLOY_STATE_DIR" || { remove_deploy_state_dir || true; return 1; }
    PM2_HANDOFF_MARKER="$DEPLOY_STATE_DIR/pm2-flowmaster-retired"
    if [[ -f "$SERVICE_FILE" && ! -L "$SERVICE_FILE" ]]; then
        DEPLOY_HAD_SERVICE_FILE=1
        cp -a -- "$SERVICE_FILE" "$DEPLOY_STATE_DIR/$SERVICE_NAME.original" || {
            remove_deploy_state_dir || true
            return 1
        }
    fi
    if [[ -f "$CONTROL_SCRIPT" && ! -L "$CONTROL_SCRIPT" ]]; then
        DEPLOY_HAD_CONTROL_SCRIPT=1
        cp -a -- "$CONTROL_SCRIPT" "$DEPLOY_STATE_DIR/flowmaster-control.original" || {
            remove_deploy_state_dir || true
            return 1
        }
    fi
    state_line="$(query_systemd_unit_state "$SERVICE_NAME")" || {
        remove_deploy_state_dir || true
        warn "无法可靠读取 $SERVICE_NAME 的初始状态"
        return 1
    }
    IFS='|' read -r load_state active_state unit_file_state main_pid control_pid <<<"$state_line"
    if [[ "$active_state" =~ ^(activating|deactivating|reloading)$ ]]; then
        remove_deploy_state_dir || true
        warn "$SERVICE_NAME 正在转换状态，请稍后重试"
        return 1
    fi
    case "$unit_file_state" in
        enabled|enabled-runtime|disabled|not-found) ;;
        *)
            remove_deploy_state_dir || true
            warn "$SERVICE_NAME 的启用状态为 $unit_file_state，安装器无法无损恢复，已拒绝继续"
            return 1
            ;;
    esac
    if [[ "$active_state" == "active" ]]; then
        DEPLOY_OLD_SERVICE_ACTIVE=1
    fi
    DEPLOY_OLD_SERVICE_ENABLE_STATE="$unit_file_state"
    DEPLOY_TRANSACTION_ACTIVE=1
}

restore_service_enable_state() {
    local expected_state="$1" actual_state
    case "$expected_state" in
        enabled)
            systemctl_bounded enable "$SERVICE_NAME" >/dev/null 2>&1 || return 1
            ;;
        enabled-runtime)
            systemctl_bounded disable "$SERVICE_NAME" >/dev/null 2>&1 || return 1
            systemctl_bounded enable --runtime "$SERVICE_NAME" >/dev/null 2>&1 || return 1
            ;;
        disabled)
            systemctl_bounded disable "$SERVICE_NAME" >/dev/null 2>&1 || return 1
            ;;
        not-found)
            ;;
        *)
            return 1
            ;;
    esac
    actual_state="$(systemctl_bounded is-enabled "$SERVICE_NAME" 2>/dev/null || true)"
    [[ "$actual_state" == "$expected_state" ]]
}

rollback_deploy_transaction() {
    local rollback_failed=0 failed_new_dir rollback_version handoff_state="" rollback_required=0 marker_size=""
    local identity_changed=0 preserve_identity_for_handoff=0
    (( DEPLOY_TRANSACTION_ACTIVE == 1 )) || return 0
    DEPLOY_TRANSACTION_ACTIVE=0

    if [[ -e "$PM2_HANDOFF_MARKER" || -L "$PM2_HANDOFF_MARKER" ]]; then
        rollback_required=1
        marker_size="$(stat -c '%s' "$PM2_HANDOFF_MARKER" 2>/dev/null || true)"
        if [[ -f "$PM2_HANDOFF_MARKER" && ! -L "$PM2_HANDOFF_MARKER" && \
              "$(stat -c '%u' "$PM2_HANDOFF_MARKER" 2>/dev/null || true)" == "0" && \
              "$marker_size" =~ ^[1-9][0-9]*$ ]] && (( marker_size <= 16 )); then
            handoff_state="$(<"$PM2_HANDOFF_MARKER")"
            [[ "$handoff_state" == "online" || "$handoff_state" == "inactive" ]] || {
                handoff_state=""
                rollback_failed=1
            }
        else
            rollback_failed=1
        fi
    fi
    if (( DEPLOY_OLD_APP_MOVED == 1 || DEPLOY_NEW_APP_INSTALLED == 1 || DEPLOY_SYSTEMD_TOUCHED == 1 )); then
        rollback_required=1
    fi
    if (( DEPLOY_SERVICE_GROUP_CREATED == 1 || DEPLOY_SERVICE_USER_CREATED == 1 || DEPLOY_VNSTAT_MEMBERSHIP_ADDED == 1 )); then
        identity_changed=1
    fi
    if (( rollback_required == 0 )); then
        if (( identity_changed == 1 )); then
            cleanup_created_service_identity || {
                warn "部署在切换运行状态前终止，但无法完整恢复服务账号状态"
                return 1
            }
        fi
        remove_deploy_state_dir || return 1
        log "部署在切换运行状态前终止；现有服务、文件和账号状态已保持不变"
        return 0
    fi

    warn "部署未完成，正在恢复部署前文件与服务状态..."
    stop_systemd_service || rollback_failed=1
    if (( DEPLOY_NEW_APP_INSTALLED == 1 )) && [[ -d "$APP_DIR" && ! -L "$APP_DIR" ]]; then
        failed_new_dir="/opt/.flowmaster-failed-$(date +%Y%m%d-%H%M%S).${$}"
        [[ ! -e "$failed_new_dir" ]] && mv -- "$APP_DIR" "$failed_new_dir" || rollback_failed=1
        sync -f /opt || rollback_failed=1
    fi
    if (( DEPLOY_OLD_APP_MOVED == 1 )); then
        if [[ -n "$ROLLBACK_DIR" && -d "$ROLLBACK_DIR" && ! -L "$ROLLBACK_DIR" && ! -e "$APP_DIR" ]]; then
            mv -- "$ROLLBACK_DIR" "$APP_DIR" || rollback_failed=1
            sync -f /opt || rollback_failed=1
            ROLLBACK_DIR=""
        elif [[ -d "$APP_DIR" && ! -L "$APP_DIR" ]]; then
            if [[ -n "$ROLLBACK_DIR" && -d "$ROLLBACK_DIR" && ! -L "$ROLLBACK_DIR" && \
                  -z "$(find "$ROLLBACK_DIR" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
                rmdir -- "$ROLLBACK_DIR" || rollback_failed=1
            elif [[ -n "$ROLLBACK_DIR" && -e "$ROLLBACK_DIR" ]]; then
                rollback_failed=1
            fi
            ROLLBACK_DIR=""
        else
            rollback_failed=1
        fi
    fi

    # 在删除本次 unit 前先移除 enable 创建的链接；unit 消失后 systemctl disable
    # 可能无法定位这些链接，因此该失败不能被吞掉。
    if [[ -f "$SERVICE_FILE" && ! -L "$SERVICE_FILE" ]]; then
        # 即使原状态为 enabled，也先清掉新 unit 可能声明的不同 WantedBy 链接，
        # 再基于恢复后的旧 unit 重建精确启用状态。
        systemctl_bounded disable "$SERVICE_NAME" >/dev/null 2>&1 || rollback_failed=1
    elif [[ -e "$SERVICE_FILE" || -L "$SERVICE_FILE" ]]; then
        rollback_failed=1
    fi
    if (( DEPLOY_HAD_SERVICE_FILE == 1 )); then
        atomic_install_file "$DEPLOY_STATE_DIR/$SERVICE_NAME.original" "$SERVICE_FILE" 0644 || rollback_failed=1
    else
        rm -f -- "$SERVICE_FILE" || rollback_failed=1
    fi
    if (( DEPLOY_HAD_CONTROL_SCRIPT == 1 )); then
        atomic_install_file "$DEPLOY_STATE_DIR/flowmaster-control.original" "$CONTROL_SCRIPT" 0755 || rollback_failed=1
    else
        rm -f -- "$CONTROL_SCRIPT" || rollback_failed=1
    fi

    systemctl_bounded daemon-reload || rollback_failed=1

    restore_service_enable_state "$DEPLOY_OLD_SERVICE_ENABLE_STATE" || rollback_failed=1

    if (( DEPLOY_OLD_SERVICE_ACTIVE == 0 )) && \
       [[ ( "$handoff_state" == "online" || "$handoff_state" == "inactive" ) && \
          -d "$APP_DIR" && ! -L "$APP_DIR" && -f "$APP_DIR/server.js" && -f "$APP_DIR/package.json" ]]; then
        preserve_identity_for_handoff=1
    fi
    if (( preserve_identity_for_handoff == 0 && identity_changed == 1 )); then
        cleanup_created_service_identity || rollback_failed=1
    fi
    if (( DEPLOY_OLD_SERVICE_ACTIVE == 1 )); then
        start_existing_systemd_service || rollback_failed=1
    elif [[ ( "$handoff_state" == "online" || "$handoff_state" == "inactive" ) && \
            -d "$APP_DIR" && ! -L "$APP_DIR" && -f "$APP_DIR/server.js" && -f "$APP_DIR/package.json" ]]; then
        # 旧版本原先由 PM2 管理时，PM2 已完成离线迁移；回滚后改由隔离的 systemd 服务承接。
        # 即使磁盘上原本残留 inactive unit，也重新生成本次实例令牌；否则旧 unit
        # 无法满足绑定实例的启动校验，可能把同版本的其他监听进程误认为回滚服务。
        create_service_user || rollback_failed=1
        secure_application_files || rollback_failed=1
        create_service_file || rollback_failed=1
        if (( DEPLOY_HAD_CONTROL_SCRIPT == 0 )); then
            create_control_script || rollback_failed=1
        fi
        if [[ "$handoff_state" == "online" ]]; then
            rollback_version="$(node -p "require('${APP_DIR}/package.json').version" 2>/dev/null || true)"
            # 1.1.20 及更早版本不会回显实例令牌；此兼容仅用于已由 systemd
            # MainPID/exe/argv/身份/稳定窗口绑定的 PM2 回滚服务，正式新部署仍强制令牌响应。
            [[ -n "$rollback_version" ]] && start_systemd_service "$rollback_version" 1 || rollback_failed=1
        else
            restore_service_enable_state disabled || rollback_failed=1
            stop_systemd_service || rollback_failed=1
        fi
    elif [[ "$handoff_state" == "online" || "$handoff_state" == "inactive" ]]; then
        # PM2 已完成不可逆的离线过滤，却没有可承接的旧程序时，必须把回滚标为不完整。
        rollback_failed=1
    fi

    if (( rollback_failed == 0 )); then
        DEPLOY_SERVICE_GROUP_CREATED=0
        DEPLOY_SERVICE_USER_CREATED=0
        DEPLOY_VNSTAT_MEMBERSHIP_ADDED=0
        log "已恢复部署前状态；事务记录保留在 $DEPLOY_STATE_DIR"
        [[ -z "${failed_new_dir:-}" ]] || warn "失败的新版本保留在: $failed_new_dir"
        return 0
    fi
    warn "自动回滚不完整，诊断文件保留在: $DEPLOY_STATE_DIR"
    return 1
}

commit_deploy_transaction() {
    local retained_state_dir="$DEPLOY_STATE_DIR"
    # 先越过提交点；此后即使清理诊断目录失败，也不能把已验证的新服务回滚。
    DEPLOY_TRANSACTION_ACTIVE=0
    DEPLOY_SERVICE_GROUP_CREATED=0
    DEPLOY_SERVICE_USER_CREATED=0
    DEPLOY_VNSTAT_MEMBERSHIP_ADDED=0
    if ! remove_deploy_state_dir; then
        warn "部署已提交，但旧事务记录未能清理: $retained_state_dir"
        DEPLOY_STATE_DIR=""
        PM2_HANDOFF_MARKER=""
    fi
}

deploy() {
    install_recovery_dependencies
    validate_service_identity_preflight || fail "已存在的 flowmaster 用户/组不符合专用服务账号安全约束"
    validate_existing_environment_file || fail "旧版 .env 不可安全迁移，现有服务和 PM2 未被修改"
    begin_deploy_transaction || fail "无法建立部署回滚点，现有服务和文件未被替换"
    recover_pm2_before_health_check
    check_process_health
    install_dependencies
    detect_network_interface

    mkdir -p /opt "$BACKUP_ROOT"
    STAGE_DIR="$(mktemp -d /opt/.flowmaster-stage.XXXXXX)"
    log "下载并验证 FlowMaster 源码..."
    download_source "$STAGE_DIR"

    if [[ -e "$APP_DIR/.env" || -L "$APP_DIR/.env" ]]; then
        validate_existing_environment_file || fail "旧版 .env 在部署期间变为不可信文件，现有服务未被替换"
        cp --no-dereference -- "$APP_DIR/.env" "$STAGE_DIR/.env"
        [[ -f "$STAGE_DIR/.env" && ! -L "$STAGE_DIR/.env" ]] || \
            fail "无法把旧版 .env 安全复制为暂存普通文件"
    fi

    (
        cd "$STAGE_DIR"
        npm ci --omit=dev --ignore-scripts --no-audit --no-fund
        npm run check
    )
    create_service_user || fail "无法创建或验证 FlowMaster 专用服务账号"
    secure_application_tree "$STAGE_DIR" || fail "无法设置暂存程序的只读服务权限"
    validate_service_runtime_as_user "$STAGE_DIR" || fail "专用服务账号运行预检失败，现有服务未被替换"
    smoke_test "$STAGE_DIR" "$SERVICE_USER" || fail "新版本非 root 冒烟测试失败，现有服务未被替换"

    retire_legacy_pm2_app || fail "旧 PM2 异常，现有服务和文件未被替换"
    DEPLOY_SYSTEMD_TOUCHED=1
    stop_systemd_service || fail "无法安全停止旧 FlowMaster，未替换程序文件"

    if [[ -d "$APP_DIR" ]]; then
        # 与 /opt/flowmaster 同一文件系统，保证旧目录切换是原子的。
        ROLLBACK_DIR="$(mktemp -d "/opt/.flowmaster-rollback-$(date +%Y%m%d-%H%M%S).XXXXXX")"
        DEPLOY_OLD_APP_MOVED=1
        rmdir -- "$ROLLBACK_DIR"
        mv -- "$APP_DIR" "$ROLLBACK_DIR"
        sync -f /opt
    fi

    DEPLOY_NEW_APP_INSTALLED=1
    mv -- "$STAGE_DIR" "$APP_DIR"
    sync -f /opt
    STAGE_DIR=""

    secure_application_files || fail "无法设置 FlowMaster 程序文件权限"
    create_service_file || fail "无法安全写入或验证 systemd unit"
    local installed_version
    installed_version="$(node -p "require('${APP_DIR}/package.json').version")"
    start_systemd_service "$installed_version" || fail "新版本启动验证失败"

    create_control_script || fail "无法安全安装 FlowMaster 控制命令"
    commit_deploy_transaction
    log "FlowMaster v${installed_version} 已部署完成"
    if [[ -n "$ROLLBACK_DIR" ]]; then
        warn "旧版本保留在: $ROLLBACK_DIR"
    fi
}

create_control_script() {
    local candidate
    candidate="$(mktemp)" || return 1
    if ! cat >"$candidate" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
    start) systemctl start flowmaster.service ;;
    stop) systemctl stop flowmaster.service ;;
    restart) systemctl restart flowmaster.service ;;
    status) systemctl status flowmaster.service --no-pager ;;
    logs) journalctl -u flowmaster.service -f ;;
    *) echo "用法: flowmaster {start|stop|restart|status|logs}"; exit 1 ;;
esac
EOF
    then
        rm -f -- "$candidate"
        return 1
    fi
    chmod 0755 "$candidate" || { rm -f -- "$candidate"; return 1; }
    atomic_install_file "$candidate" "$CONTROL_SCRIPT" 0755 || { rm -f -- "$candidate"; return 1; }
    rm -f -- "$candidate"
}

uninstall() {
    local confirmation archived_dir="" archive_parent="$BACKUP_ROOT"
    local state_line load_state active_state unit_file_state main_pid control_pid
    read -r -p "确认卸载 FlowMaster？vnstat 历史数据将被保留 [y/N]: " confirmation
    [[ "$confirmation" =~ ^[Yy]$ ]] || { warn "已取消"; return; }

    install_recovery_dependencies
    validate_existing_environment_file || fail "旧版 .env 不是普通文件；为保证 PM2 迁移可回滚，已取消卸载"
    begin_deploy_transaction || fail "无法建立卸载回滚点，FlowMaster 未被修改"
    retire_legacy_pm2_app || fail "旧 PM2 无法安全迁移，已取消卸载且未修改 FlowMaster 文件"
    DEPLOY_SYSTEMD_TOUCHED=1
    stop_systemd_service || fail "FlowMaster 服务无法完全停止，已取消卸载"

    state_line="$(query_systemd_unit_state "$SERVICE_NAME")" || fail "无法确认 $SERVICE_NAME 状态，正在回滚卸载"
    IFS='|' read -r load_state active_state unit_file_state main_pid control_pid <<<"$state_line"
    if [[ "$load_state" != "not-found" ]]; then
        systemctl_bounded disable "$SERVICE_NAME" >/dev/null 2>&1 || fail "无法禁用 $SERVICE_NAME，正在回滚卸载"
    fi

    if [[ -d "$APP_DIR" ]]; then
        if [[ "$(stat -c '%d' /opt)" != "$(stat -c '%d' "$BACKUP_ROOT")" ]]; then
            archive_parent="/opt"
            warn "$BACKUP_ROOT 与程序目录不在同一文件系统；为保证原子卸载，归档将保留在 /opt"
        fi
        archived_dir="$(mktemp -d "${archive_parent}/.flowmaster-uninstalled-$(date +%Y%m%d-%H%M%S).XXXXXX")"
        ROLLBACK_DIR="$archived_dir"
        DEPLOY_OLD_APP_MOVED=1
        rmdir -- "$ROLLBACK_DIR"
        mv -- "$APP_DIR" "$ROLLBACK_DIR" || fail "无法原子归档程序文件，正在回滚卸载"
        sync -f "$archive_parent" || fail "程序目录同步失败，正在回滚卸载"
    fi

    rm -f -- "$SERVICE_FILE" "$CONTROL_SCRIPT" || fail "无法移除服务文件，正在回滚卸载"
    systemctl_bounded daemon-reload || fail "systemd 重载失败，正在回滚卸载"
    state_line="$(query_systemd_unit_state "$SERVICE_NAME")" || fail "无法验证卸载后的 systemd 状态，正在回滚卸载"
    IFS='|' read -r load_state active_state unit_file_state main_pid control_pid <<<"$state_line"
    [[ "$load_state" == "not-found" ]] || fail "$SERVICE_NAME 仍可被 systemd 加载，正在回滚卸载"

    commit_deploy_transaction || fail "无法提交卸载事务，正在回滚"
    [[ -z "$archived_dir" ]] || log "程序文件已归档到 $archived_dir，可手工恢复"
    log "卸载完成；/var/lib/vnstat 未被修改"
}

show_menu() {
    echo -e "${GREEN}================================${NC}"
    echo -e "${GREEN}       FlowMaster 管理菜单${NC}"
    echo -e "${GREEN}================================${NC}"
    if check_installation; then
        echo "1) 安全更新/重新部署 FlowMaster"
        echo "2) 卸载 FlowMaster（保留 vnstat 数据）"
        echo "3) 退出"
    else
        echo "1) 安装 FlowMaster"
        echo "2) 退出"
    fi
}

main() {
    require_root
    validate_configured_paths
    bootstrap_lock_dependency
    acquire_installer_lock
    show_menu
    local choice
    read -r -p "请选择操作: " choice
    if check_installation; then
        case "$choice" in
            1) deploy ;;
            2) uninstall ;;
            3) exit 0 ;;
            *) fail "无效选择" ;;
        esac
    else
        case "$choice" in
            1) deploy ;;
            2) exit 0 ;;
            *) fail "无效选择" ;;
        esac
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
