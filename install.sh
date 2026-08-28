#!/usr/bin/env bash

set -Eeuo pipefail

readonly APP_NAME="flowmaster"
readonly APP_DIR="/opt/flowmaster"
readonly CONTROL_SCRIPT="/usr/local/bin/flowmaster"
readonly BACKUP_ROOT="${FLOWMASTER_BACKUP_ROOT:-/var/backups/flowmaster}"
readonly SERVICE_NAME="flowmaster.service"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
readonly SOURCE_REF="${FLOWMASTER_VERSION:-main}"
if [[ "$SOURCE_REF" == "main" ]]; then
    readonly DEFAULT_DOWNLOAD_URL="https://github.com/vbskycn/FlowMaster/archive/refs/heads/main.tar.gz"
else
    readonly DEFAULT_DOWNLOAD_URL="https://github.com/vbskycn/FlowMaster/archive/refs/tags/${SOURCE_REF}.tar.gz"
fi
readonly DOWNLOAD_URL="${FLOWMASTER_DOWNLOAD_URL:-$DEFAULT_DOWNLOAD_URL}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

STAGE_DIR=""
ROLLBACK_DIR=""
SMOKE_PID=""
SMOKE_OUTPUT_FILE=""

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
    stop_smoke_process
    if [[ -n "$SMOKE_OUTPUT_FILE" ]]; then
        rm -f -- "$SMOKE_OUTPUT_FILE"
        SMOKE_OUTPUT_FILE=""
    fi
    if [[ -n "$STAGE_DIR" && -d "$STAGE_DIR" ]]; then
        case "$STAGE_DIR" in
            /opt/.flowmaster-stage.*) rm -rf -- "$STAGE_DIR" ;;
            *) warn "拒绝清理非预期临时目录: $STAGE_DIR" ;;
        esac
    fi
}
trap cleanup EXIT

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "请使用 root 权限运行此脚本"
}

acquire_installer_lock() {
    command -v flock >/dev/null 2>&1 || fail "缺少 flock，无法防止并发安装"
    exec {flowmaster_installer_lock_fd}>/run/lock/flowmaster-installer.lock || fail "无法创建安装锁"
    flock -n "$flowmaster_installer_lock_fd" || fail "另一个 FlowMaster 安装或卸载流程正在运行"
}

check_installation() {
    [[ -d "$APP_DIR" || -f "$SERVICE_FILE" ]] || command -v flowmaster >/dev/null 2>&1
}

install_package() {
    local package="$1"
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$package"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "$package"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "$package"
    else
        fail "无法识别包管理器，请手动安装 $package"
    fi
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
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
    fi
    for command_package in \
        "curl:curl" \
        "tar:tar" \
        "node:nodejs" \
        "npm:npm" \
        "vnstat:vnstat" \
        "timeout:coreutils" \
        "setsid:util-linux"; do
        local command_name="${command_package%%:*}"
        local package_name="${command_package##*:}"
        command -v "$command_name" >/dev/null 2>&1 || install_package "$package_name"
    done

    local node_major
    node_major="$(node -p 'Number(process.versions.node.split(".")[0])')"
    (( node_major >= 18 )) || fail "Node.js 版本过低，需要 18 或更高版本"

    command -v systemctl >/dev/null 2>&1 || fail "一键部署需要 systemd；当前系统未找到 systemctl"
    [[ -d /run/systemd/system ]] || fail "systemd 当前未作为系统初始化进程运行，无法安全安装服务"

    systemctl enable --now vnstat >/dev/null 2>&1 || service vnstat start
}

detect_network_interface() {
    local selected_interface
    selected_interface="$(ip route show default 2>/dev/null | awk 'NR==1 {print $5}')"
    if [[ -z "$selected_interface" ]]; then
        selected_interface="$(ip -o link show up | awk -F': ' '$2 != "lo" {print $2; exit}')"
    fi
    [[ -n "$selected_interface" ]] || fail "未检测到可用网络接口"

    log "检测到网络接口: $selected_interface"
    if ! vnstat --iflist 2>/dev/null | grep -Eq "(^|[[:space:]])${selected_interface}([[:space:]]|$)"; then
        warn "vnstat 尚未记录 $selected_interface，正在添加；现有数据库不会被删除。"
        vnstat --add -i "$selected_interface" >/dev/null 2>&1 || vnstat -u -i "$selected_interface" >/dev/null 2>&1 || true
        systemctl restart vnstat >/dev/null 2>&1 || service vnstat restart
    fi
}

download_source() {
    local target_dir="$1"
    local archive
    archive="$(mktemp)"
    curl \
        --fail \
        --location \
        --retry 3 \
        --retry-delay 2 \
        --connect-timeout 10 \
        --max-time 120 \
        --output "$archive" \
        "$DOWNLOAD_URL"

    if [[ -n "${FLOWMASTER_SHA256:-}" ]]; then
        echo "${FLOWMASTER_SHA256}  ${archive}" | sha256sum --check --status || fail "下载文件 SHA-256 校验失败"
    fi

    tar -xzf "$archive" -C "$target_dir" --strip-components=1
    rm -f -- "$archive"
    [[ -f "$target_dir/package.json" && -f "$target_dir/server.js" && -f "$target_dir/package-lock.json" ]] || \
        fail "下载内容不完整，拒绝覆盖现有安装"
}

smoke_test() {
    local target_dir="$1"
    local smoke_port="${FLOWMASTER_SMOKE_PORT:-19089}"
    local smoke_timeout="${FLOWMASTER_SMOKE_TIMEOUT_SECONDS:-15}"
    local curl_timeout="${FLOWMASTER_SMOKE_CURL_TIMEOUT_SECONDS:-2}"
    if [[ ! "$smoke_port" =~ ^[0-9]+$ ]] || (( smoke_port < 1 || smoke_port > 65535 )); then
        fail "FLOWMASTER_SMOKE_PORT 必须是 1-65535 之间的端口"
    fi
    [[ "$smoke_timeout" =~ ^[1-9][0-9]*$ ]] || fail "FLOWMASTER_SMOKE_TIMEOUT_SECONDS 必须是正整数"
    [[ "$curl_timeout" =~ ^[1-9][0-9]*$ ]] || fail "FLOWMASTER_SMOKE_CURL_TIMEOUT_SECONDS 必须是正整数"

    local expected_version
    expected_version="$(node -p "require('${target_dir}/package.json').version")"
    SMOKE_OUTPUT_FILE="$(mktemp)"

    log "执行临时服务冒烟测试（最多 ${smoke_timeout} 秒）..."
    (
        cd "$target_dir"
        exec setsid env HOST=127.0.0.1 PORT="$smoke_port" node server.js >"$SMOKE_OUTPUT_FILE" 2>&1
    ) &
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
            "http://127.0.0.1:${smoke_port}/api/version" 2>/dev/null || true)"
        if [[ "$response" == "{\"version\":\"${expected_version}\"}" ]]; then
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
    main_pid="$(systemctl show "$candidate" --property=MainPID --value 2>/dev/null || true)"
    service_type="$(systemctl show "$candidate" --property=Type --value 2>/dev/null || true)"
    kill_mode="$(systemctl show "$candidate" --property=KillMode --value 2>/dev/null || true)"
    pid_file="$(systemctl show "$candidate" --property=PIDFile --value 2>/dev/null || true)"
    exec_start="$(systemctl show "$candidate" --property=ExecStart --value 2>/dev/null || true)"
    service_user="$(systemctl show "$candidate" --property=User --value 2>/dev/null || true)"
    service_environment="$(systemctl show "$candidate" --property=Environment --value 2>/dev/null || true)"
    control_group="$(systemctl show "$candidate" --property=ControlGroup --value 2>/dev/null || true)"
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
    node - "$expected_dump" <<'NODE'
'use strict';
const fs = require('node:fs');
const apps = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const clean = value => String(value || '未命名').replace(/[\u0000-\u001f\u007f]/g, '?').slice(0, 120);
for (const app of apps) {
    if (app && app.pmx_module) continue;
    console.log(`  - ${clean(app && app.name)} (${clean(app && app.status || '已保存')})`);
}
NODE
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

finalize_pm2_dump_migration() {
    local pm2_home="$1"
    local dump_state=0 migration_backup
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
    sanitize_saved_pm2_dumps "$pm2_home" "$migration_backup" || {
        warn "PM2 主/备清单校验或过滤失败，备份位于: $migration_backup"
        return 1
    }
}

restart_pm2_systemd_unit() {
    local pm2_unit="$1"
    local pm2_pid="$2"
    local pm2_starttime="$3"
    local pm2_home="$4"
    local deadline=$((SECONDS + 45))
    local main_pid control_pid active_state new_starttime

    process_matches_starttime "$pm2_pid" "$pm2_starttime" || return 1
    systemctl --no-block restart "$pm2_unit" >/dev/null 2>&1 || return 1
    while (( SECONDS < deadline )); do
        main_pid="$(systemctl show "$pm2_unit" --property=MainPID --value 2>/dev/null || true)"
        control_pid="$(systemctl show "$pm2_unit" --property=ControlPID --value 2>/dev/null || true)"
        active_state="$(systemctl show "$pm2_unit" --property=ActiveState --value 2>/dev/null || true)"
        if [[ "$active_state" == "active" && "$control_pid" == "0" && "$main_pid" =~ ^[1-9][0-9]*$ && "$main_pid" != "$pm2_pid" ]]; then
            new_starttime="$(get_process_starttime "$main_pid" 2>/dev/null || true)"
            [[ -n "$new_starttime" ]] || return 1
            is_root_pm2_daemon "$main_pid" || return 1
            [[ "$(find_pm2_systemd_unit "$main_pid" "$pm2_home" 2>/dev/null || true)" == "$pm2_unit" ]] || return 1
            grep -zqx 'PIDUSAGE_USE_PS=false' "/proc/${main_pid}/environ" 2>/dev/null || return 1
            return 0
        fi
        sleep 0.5
    done
    return 1
}

verify_restarted_pm2() {
    local pm2_home="$1"
    local expected_dump="$2"
    local process_list deadline=$((SECONDS + 30))

    timeout --signal=TERM --kill-after=2s 10s env PM2_HOME="$pm2_home" PIDUSAGE_USE_PS=false \
        pm2 ping >/dev/null 2>&1 || return 1
    process_list="$(mktemp)" || return 1
    chmod 0600 "$process_list" || { rm -f -- "$process_list"; return 1; }
    while (( SECONDS < deadline )); do
        : >"$process_list" || { rm -f -- "$process_list"; return 1; }
        if timeout --signal=TERM --kill-after=2s 10s env PM2_HOME="$pm2_home" PIDUSAGE_USE_PS=false \
            pm2 jlist >"$process_list" 2>/dev/null && verify_pm2_runtime "$expected_dump" "$process_list"; then
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
    systemctl show "$pm2_unit" --property=Environment --value 2>/dev/null | \
        tr ' ' '\n' | sed -n 's/^PIDUSAGE_USE_PS=//p' | tail -n 1
}

verify_pm2_recovery_unit_settings() {
    local pm2_unit="$1"
    [[ "$(systemctl show "$pm2_unit" --property=TimeoutStopUSec --value 2>/dev/null || true)" == "15s" ]] || return 1
    [[ "$(systemctl show "$pm2_unit" --property=TimeoutStopFailureMode --value 2>/dev/null || true)" == "kill" ]] || return 1
    [[ "$(systemctl show "$pm2_unit" --property=KillMode --value 2>/dev/null || true)" == "control-group" ]] || return 1
    [[ "$(systemctl show "$pm2_unit" --property=SendSIGKILL --value 2>/dev/null || true)" == "yes" ]] || return 1
    [[ "$(effective_pm2_pidusage_setting "$pm2_unit")" == "false" ]] || return 1
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
    systemctl daemon-reload || return 1
    (( restart_unit == 0 )) || systemctl --no-block restart "$pm2_unit" >/dev/null 2>&1
}

recover_unresponsive_pm2() (
    command -v pm2 >/dev/null 2>&1 || return 1
    command -v node >/dev/null 2>&1 || return 1
    command -v systemctl >/dev/null 2>&1 || return 1
    command -v flock >/dev/null 2>&1 || return 1

    local require_flowmaster="${1:-1}"
    [[ "$require_flowmaster" == "0" || "$require_flowmaster" == "1" ]] || return 1
    local pm2_home="${PM2_HOME:-/root/.pm2}"
    local pm2_pid_file="${pm2_home}/pm2.pid"
    local pm2_dump="${pm2_home}/dump.pm2"
    [[ -r "$pm2_pid_file" && -r "$pm2_dump" ]] || return 1

    local pm2_pid pm2_starttime probe_status=0 pm2_unit recovery_answer recovery_dir current_cgroup
    local dropin_dir dropin_file dropin_backup="" dropin_candidate persistent_candidate had_dropin=0
    local had_dump_backup=0 pm2_unit_exec pm2_cli_exec
    exec {pm2_recovery_lock_fd}>/run/lock/flowmaster-pm2-recovery.lock || return 1
    flock -n "$pm2_recovery_lock_fd" || { warn "另一个 PM2 恢复流程正在运行"; return 1; }

    pm2_pid="$(<"$pm2_pid_file")"
    [[ "$pm2_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pm2_pid" >/dev/null 2>&1 || return 1
    pm2_starttime="$(get_process_starttime "$pm2_pid" 2>/dev/null || true)"
    [[ -n "$pm2_starttime" ]] || return 1

    timeout --signal=TERM --kill-after=2s 5s env PM2_HOME="$pm2_home" PIDUSAGE_USE_PS=false \
        pm2 ping >/dev/null 2>&1 || probe_status=$?
    is_timeout_status "$probe_status" || return 1

    validate_pm2_home_directory "$pm2_home" || { warn "PM2_HOME 不是可信的 root 私有目录"; return 1; }
    validate_pm2_dump_file "$pm2_dump" || { warn "PM2 dump.pm2 不是可信的 root 普通 JSON 文件"; return 1; }
    if [[ -e "${pm2_home}/dump.pm2.bak" ]]; then
        validate_pm2_dump_file "${pm2_home}/dump.pm2.bak" || { warn "PM2 dump.pm2.bak 不可信，拒绝自动恢复"; return 1; }
        had_dump_backup=1
    fi
    if (( require_flowmaster == 1 )) && ! pm2_dump_contains_app "$pm2_dump"; then
        warn "PM2 已保存清单中没有 FlowMaster，无法保证未保存应用的恢复完整性"
        return 1
    fi

    pm2_unit="$(find_pm2_systemd_unit "$pm2_pid" "$pm2_home" || true)"
    if [[ -z "$pm2_unit" ]]; then
        current_cgroup="$(sed -n 's/^[^:]*:[^:]*://p' "/proc/${pm2_pid}/cgroup" 2>/dev/null | tail -n 1)"
        warn "无法将 PM2 PID ${pm2_pid} 安全定位到独立的标准 root pm2-*.service，拒绝直接杀死 daemon 以免留下孤儿或重复应用。"
        [[ -z "$current_cgroup" ]] || warn "检测到的 PM2 cgroup: $current_cgroup"
        return 1
    fi
    pm2_unit_exec="$(systemctl show "$pm2_unit" --property=ExecStart --value 2>/dev/null || true)"
    pm2_unit_exec="${pm2_unit_exec#*path=}"
    pm2_unit_exec="${pm2_unit_exec%% *}"
    pm2_cli_exec="$(command -v pm2)"
    if [[ "$pm2_unit_exec" != /* || ! -x "$pm2_unit_exec" || \
          "$(readlink -f "$pm2_unit_exec" 2>/dev/null || true)" != "$(readlink -f "$pm2_cli_exec" 2>/dev/null || true)" ]]; then
        warn "当前 pm2 CLI 与 ${pm2_unit} 的 ExecStart 不是同一可执行文件，拒绝跨版本恢复"
        return 1
    fi

    warn "PM2 守护进程无响应（PID ${pm2_pid}）。"
    warn "无需重启主机，但会短暂重启 ${pm2_unit} 中以下已保存应用："
    print_pm2_recovery_apps "$pm2_dump" || return 1
    warn "未执行 pm2 save 的应用无法从无响应守护进程中可靠导出；确认后会先备份 PM2 清单与 unit 配置。"
    if [[ "${FLOWMASTER_RECOVER_UNRESPONSIVE_PM2:-}" == "1" ]]; then
        recovery_answer="RECOVER-PM2"
    elif [[ "${FLOWMASTER_RECOVER_UNRESPONSIVE_PM2:-}" == "0" || ! -t 0 ]]; then
        warn "未授权重启 PM2 管理的其他应用，已保持现状。非交互运行可显式设置 FLOWMASTER_RECOVER_UNRESPONSIVE_PM2=1。"
        return 1
    else
        if ! read -r -p "如确认短暂重启上述 PM2 应用，请输入 RECOVER-PM2: " recovery_answer; then
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
    systemctl cat "$pm2_unit" >"$recovery_dir/${pm2_unit}.txt" 2>/dev/null || return 1
    chmod 0600 "$recovery_dir/dump.pm2.original" "$recovery_dir/${pm2_unit}.txt" || return 1
    [[ ! -e "$recovery_dir/dump.pm2.bak.original" ]] || chmod 0600 "$recovery_dir/dump.pm2.bak.original" || return 1
    log "PM2 恢复前备份已写入: $recovery_dir"

    dropin_dir="/etc/systemd/system/${pm2_unit}.d"
    dropin_file="${dropin_dir}/zzzz-flowmaster-pm2-recovery.conf"
    validate_pm2_dropin_directory "$dropin_dir" || { warn "PM2 drop-in 目录不可信，拒绝写入"; return 1; }
    dropin_candidate="$recovery_dir/zzzz-flowmaster-pm2-recovery.conf.temporary"
    persistent_candidate="$recovery_dir/zzzz-flowmaster-pm2-recovery.conf.persistent"
    cat >"$dropin_candidate" <<'EOF' || return 1
[Service]
Environment=PIDUSAGE_USE_PS=false
TimeoutStopSec=15s
TimeoutStopFailureMode=kill
KillMode=control-group
SendSIGKILL=yes
EOF
    chmod 0644 "$dropin_candidate" || return 1
    cat >"$persistent_candidate" <<'EOF' || return 1
[Service]
Environment=PIDUSAGE_USE_PS=false
EOF
    chmod 0644 "$persistent_candidate" || return 1
    if [[ -e "$dropin_file" || -L "$dropin_file" ]]; then
        [[ -f "$dropin_file" && ! -L "$dropin_file" && "$(stat -c '%u' "$dropin_file" 2>/dev/null || true)" == "0" ]] || {
            warn "PM2 drop-in 不是可信的 root 普通文件，拒绝覆盖"
            return 1
        }
        if ! cmp -s -- "$dropin_file" "$dropin_candidate" && ! cmp -s -- "$dropin_file" "$persistent_candidate"; then
            warn "${dropin_file} 已存在且不是 FlowMaster 预期配置，拒绝覆盖"
            return 1
        fi
        dropin_backup="$recovery_dir/zzzz-flowmaster-pm2-recovery.conf.original"
        cp -a -- "$dropin_file" "$dropin_backup" || return 1
        had_dropin=1
    fi
    install_pm2_dropin_atomically "$dropin_candidate" "$dropin_file" || return 1
    if ! systemctl daemon-reload; then
        restore_pm2_dropin "$pm2_unit" "$dropin_file" "$dropin_backup" "$had_dropin" 0 || true
        return 1
    fi
    if ! verify_pm2_recovery_unit_settings "$pm2_unit"; then
        warn "PM2 unit 的有效停止边界被其他配置覆盖，已在重启前安全退出"
        restore_pm2_dropin "$pm2_unit" "$dropin_file" "$dropin_backup" "$had_dropin" 0 || true
        return 1
    fi
    if ! cmp -s -- "$pm2_dump" "$recovery_dir/dump.pm2.original" || \
       { (( had_dump_backup == 1 )) && ! cmp -s -- "${pm2_home}/dump.pm2.bak" "$recovery_dir/dump.pm2.bak.original"; } || \
       { (( had_dump_backup == 0 )) && [[ -e "${pm2_home}/dump.pm2.bak" ]]; }; then
        warn "PM2 清单在确认后发生变化，已取消重启以避免恢复错误应用集合"
        restore_pm2_dropin "$pm2_unit" "$dropin_file" "$dropin_backup" "$had_dropin" 0 || true
        return 1
    fi

    if ! restart_pm2_systemd_unit "$pm2_unit" "$pm2_pid" "$pm2_starttime" "$pm2_home" || \
       ! verify_restarted_pm2 "$pm2_home" "$pm2_dump"; then
        warn "PM2 原地重启或应用集合验证失败，已停止后续安装。"
        if install_pm2_dropin_atomically "$persistent_candidate" "$dropin_file" && systemctl daemon-reload; then
            warn "已仅保留 PIDUSAGE_USE_PS=false 防护；PM2 清单备份位于: $recovery_dir"
        else
            warn "无法收敛为持久防护配置，暂时保留 15 秒有界恢复配置；请检查: $dropin_file"
        fi
        return 1
    fi

    if ! install_pm2_dropin_atomically "$persistent_candidate" "$dropin_file" || \
       ! systemctl daemon-reload || \
       [[ "$(effective_pm2_pidusage_setting "$pm2_unit")" != "false" ]]; then
        warn "PM2 已恢复，但 PIDUSAGE_USE_PS=false 未能持久化；保留有界恢复配置并停止后续安装"
        install_pm2_dropin_atomically "$dropin_candidate" "$dropin_file" || true
        systemctl daemon-reload || true
        return 1
    fi

    log "PM2 已在不重启主机的情况下恢复，已保存应用集合保持不变"
    return 0
)

retire_legacy_pm2_app() {
    command -v pm2 >/dev/null 2>&1 || return 0

    local pm2_home="${PM2_HOME:-/root/.pm2}"
    local pm2_pid_file="${pm2_home}/pm2.pid"
    local pm2_pid="" presence presence_status delete_status save_status
    local recovery_attempts=0 delete_started=0
    if [[ ! -r "$pm2_pid_file" ]]; then
        finalize_pm2_dump_migration "$pm2_home" || return 1
        return 0
    fi
    pm2_pid="$(<"$pm2_pid_file")"
    if [[ ! "$pm2_pid" =~ ^[1-9][0-9]*$ ]] || ! kill -0 "$pm2_pid" >/dev/null 2>&1 || ! is_root_pm2_daemon "$pm2_pid"; then
        finalize_pm2_dump_migration "$pm2_home" || return 1
        return 0
    fi

    log "检查旧版 PM2 中的 FlowMaster..."
    while (( recovery_attempts <= 2 )); do
        presence_status=0
        presence="$(get_pm2_app_presence "$pm2_home")" || presence_status=$?
        if is_timeout_status "$presence_status"; then
            (( recovery_attempts++ )) || true
            warn "PM2 守护进程无响应，尝试在不重启主机的情况下原地恢复。"
            # 删除动作开始前必须确认已保存清单仍包含 FlowMaster；开始后则允许
            # 以已经写入的清单为权威，兼容 delete/save 超时但落盘成功的情况。
            recover_unresponsive_pm2 "$((1 - delete_started))" || return 1
            continue
        fi
        if (( presence_status != 0 )); then
            warn "无法读取 PM2 进程清单，拒绝把通信错误误判为 FlowMaster 不存在"
            return 1
        fi
        if [[ "$presence" == "absent" ]]; then
            finalize_pm2_dump_migration "$pm2_home" || return 1
            (( delete_started == 0 )) || log "旧 FlowMaster 已从 PM2 安全迁移；其他 PM2 应用保持不变"
            return 0
        fi

        delete_started=1
        delete_status=0
        timeout --signal=TERM --kill-after=2s 15s env PM2_HOME="$pm2_home" PIDUSAGE_USE_PS=false \
            pm2 delete "$APP_NAME" >/dev/null 2>&1 || delete_status=$?
        if is_timeout_status "$delete_status"; then
            (( recovery_attempts++ )) || true
            warn "从 PM2 移除旧 FlowMaster 超时，尝试原地恢复后重试。"
            recover_unresponsive_pm2 0 || return 1
            continue
        fi
        (( delete_status == 0 )) || { warn "PM2 拒绝删除旧 FlowMaster"; return 1; }

        save_status=0
        timeout --signal=TERM --kill-after=2s 10s env PM2_HOME="$pm2_home" PIDUSAGE_USE_PS=false \
            pm2 save --force >/dev/null 2>&1 || save_status=$?
        if is_timeout_status "$save_status"; then
            (( recovery_attempts++ )) || true
            warn "PM2 进程列表保存超时，尝试原地恢复后重试。"
            recover_unresponsive_pm2 0 || return 1
            continue
        fi
        (( save_status == 0 )) || { warn "PM2 进程列表保存失败"; return 1; }
        finalize_pm2_dump_migration "$pm2_home" || return 1
        log "旧 FlowMaster 已从 PM2 安全迁移；其他 PM2 应用保持不变"
        return 0
    done

    warn "PM2 连续恢复后仍无响应，已停止安装"
    return 1
}

stop_systemd_service() {
    if systemctl list-unit-files "$SERVICE_NAME" --no-legend 2>/dev/null | grep -q "^${SERVICE_NAME}"; then
        systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    fi
}

create_service_file() {
    local node_path
    node_path="$(readlink -f "$(command -v node)")"
    cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=FlowMaster Network Traffic Monitor
After=network-online.target vnstat.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR
Environment=NODE_ENV=production
ExecStart=$node_path $APP_DIR/server.js
Restart=on-failure
RestartSec=3
TimeoutStopSec=20
KillSignal=SIGTERM
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=read-only

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$SERVICE_FILE"
    systemctl daemon-reload
}

start_systemd_service() {
    local expected_version="$1"
    local health_url
    health_url="$(
        cd "$APP_DIR"
        node -e "require('dotenv').config({ path: '.env', quiet: true }); let host = process.env.HOST || '0.0.0.0'; const port = Number.parseInt(process.env.PORT || '10089', 10); if (host === '0.0.0.0' || host === '::') host = '127.0.0.1'; if (host.includes(':')) host = '[' + host + ']'; process.stdout.write('http://' + host + ':' + (Number.isInteger(port) && port > 0 && port <= 65535 ? port : 10089) + '/api/version');"
    )"
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    systemctl restart "$SERVICE_NAME"

    local deadline=$((SECONDS + 20))
    local response=""
    while (( SECONDS < deadline )); do
        if ! systemctl is-active --quiet "$SERVICE_NAME"; then
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
            "$health_url" \
            2>/dev/null || true)"
        if [[ "$response" == "{\"version\":\"${expected_version}\"}" ]]; then
            return 0
        fi
        sleep 0.5
    done

    warn "systemd 服务启动验证失败，最近日志:"
    journalctl -u "$SERVICE_NAME" -n 30 --no-pager >&2 || true
    return 1
}

deploy() {
    recover_pm2_before_health_check
    check_process_health
    install_dependencies
    detect_network_interface

    mkdir -p /opt "$BACKUP_ROOT"
    STAGE_DIR="$(mktemp -d /opt/.flowmaster-stage.XXXXXX)"
    log "下载并验证 FlowMaster 源码..."
    download_source "$STAGE_DIR"

    if [[ -f "$APP_DIR/.env" ]]; then
        cp -a "$APP_DIR/.env" "$STAGE_DIR/.env"
    fi

    (
        cd "$STAGE_DIR"
        npm ci --omit=dev
        npm run check
    )
    smoke_test "$STAGE_DIR" || fail "新版本冒烟测试失败，现有服务未被替换"

    retire_legacy_pm2_app || fail "旧 PM2 异常，现有服务和文件未被替换"
    stop_systemd_service

    if [[ -d "$APP_DIR" ]]; then
        ROLLBACK_DIR="$BACKUP_ROOT/rollback-$(date +%Y%m%d-%H%M%S)"
        mv "$APP_DIR" "$ROLLBACK_DIR"
    fi

    mv "$STAGE_DIR" "$APP_DIR"
    STAGE_DIR=""

    create_service_file
    local installed_version
    installed_version="$(node -p "require('${APP_DIR}/package.json').version")"
    if ! start_systemd_service "$installed_version"; then
        warn "新版本启动失败，正在回滚..."
        stop_systemd_service
        rm -rf -- "$APP_DIR"
        if [[ -n "$ROLLBACK_DIR" && -d "$ROLLBACK_DIR" ]]; then
            mv "$ROLLBACK_DIR" "$APP_DIR"
            create_service_file
            local rollback_version
            rollback_version="$(node -p "require('${APP_DIR}/package.json').version")"
            start_systemd_service "$rollback_version" || true
        else
            rm -f -- "$SERVICE_FILE"
            systemctl daemon-reload
        fi
        fail "部署失败，已尝试恢复旧版本"
    fi

    create_control_script
    log "FlowMaster v${installed_version} 已部署完成"
    if [[ -n "$ROLLBACK_DIR" ]]; then
        warn "旧版本保留在: $ROLLBACK_DIR"
    fi
}

create_control_script() {
    cat >"$CONTROL_SCRIPT" <<'EOF'
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
    chmod 0755 "$CONTROL_SCRIPT"
}

uninstall() {
    local confirmation
    read -r -p "确认卸载 FlowMaster？vnstat 历史数据将被保留 [y/N]: " confirmation
    [[ "$confirmation" =~ ^[Yy]$ ]] || { warn "已取消"; return; }

    stop_systemd_service
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f -- "$SERVICE_FILE"
    systemctl daemon-reload
    retire_legacy_pm2_app || warn "旧 PM2 无响应，未自动修改其进程；请手工确认没有遗留 FlowMaster"
    rm -f -- "$CONTROL_SCRIPT"

    if [[ -d "$APP_DIR" ]]; then
        mkdir -p "$BACKUP_ROOT"
        local archived_dir
        archived_dir="$BACKUP_ROOT/uninstalled-$(date +%Y%m%d-%H%M%S)"
        mv "$APP_DIR" "$archived_dir"
        log "程序文件已归档到 $archived_dir，可手工恢复"
    fi
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
