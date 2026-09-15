#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly REQUESTED_BACKUP_DIR="${FLOWMASTER_BACKUP_DIR:-/var/backups/flowmaster/vnstat}"
readonly REQUESTED_VNSTAT_DATA_DIR="${VNSTAT_DATA_DIR:-/var/lib/vnstat}"
readonly REQUESTED_LOG_FILE="${FLOWMASTER_BACKUP_LOG:-/var/log/flowmaster-vnstat-backup.log}"
readonly REQUESTED_MAINTENANCE_LOCK="${FLOWMASTER_MAINTENANCE_LOCK_FILE:-/run/lock/flowmaster-maintenance.lock}"
readonly SYSTEMCTL_TIMEOUT_SECONDS="${FLOWMASTER_SYSTEMCTL_TIMEOUT_SECONDS:-10}"
readonly ARCHIVE_MAX_BYTES=536870912
readonly ARCHIVE_MAX_EXPANDED_BYTES=2147483648
readonly ARCHIVE_MAX_MEMBERS=20000

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

VNSTAT_DATA_PATH=""
BACKUP_PATH=""
LOG_PATH=""
MAINTENANCE_LOCK_PATH=""
PATHS_VALIDATED=false

VNSTAT_WAS_ACTIVE=false
FLOWMASTER_WAS_ACTIVE=false
SERVICES_STOPPED=false
MAINTENANCE_LOCK_FD=""

ARCHIVE_SNAPSHOT_DIR=""
ARCHIVE_TMP_FILE=""
ARCHIVE_SIDECAR_TMP_FILE=""
ARCHIVE_PENDING_FILE=""
RESTORE_EXTRACT_DIR=""
RESTORE_STAGED_PATH=""
RESTORE_TRANSACTION_ACTIVE=false
RESTORE_ORIGINAL_PRESENT=false
RESTORE_TARGET_CREATED=false
RESTORE_ROLLBACK_PATH=""
UNIQUE_ROLLBACK_PATH=""
LAST_ARCHIVE_HASH=""
_flowmaster_status=0

log() { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}$*${NC}"; }
fail() { echo -e "${RED}$*${NC}" >&2; return 1; }

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || { echo -e "${RED}请使用 root 权限运行此脚本${NC}" >&2; exit 1; }
}

canonicalize_without_symlinks() {
    local requested="$1"
    local label="$2"
    local lexical resolved

    [[ "$requested" == /* ]] || { fail "${label}必须是绝对路径"; return 1; }
    lexical="$(realpath -ms -- "$requested")" || return 1
    resolved="$(realpath -m -- "$requested")" || return 1
    if [[ "$lexical" != "$resolved" || -L "$requested" ]]; then
        fail "${label}不得包含符号链接: $requested"
        return 1
    fi
    printf '%s\n' "$resolved"
}

path_is_same_or_descendant() {
    local candidate="${1%/}"
    local parent="${2%/}"
    [[ "$candidate" == "$parent" || "$candidate" == "$parent/"* ]]
}

directory_is_trusted_ancestor() {
    local directory="$1" owner mode numeric_mode current_uid
    [[ -d "$directory" && ! -L "$directory" ]] || return 1
    owner="$(stat -c '%u' -- "$directory" 2>/dev/null)" || return 1
    mode="$(stat -c '%a' -- "$directory" 2>/dev/null)" || return 1
    current_uid="${EUID:-$(id -u)}"
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    numeric_mode=$((8#$mode))
    if (( (numeric_mode & 8#22) == 0 )); then
        [[ "$owner" == "0" || "$owner" == "$current_uid" ]]
        return
    fi
    # /run/lock、/tmp 等 root 所有的 sticky 目录可安全保护 root 创建的直属项。
    [[ "$owner" == "0" ]] && (( (numeric_mode & 8#1000) != 0 ))
}

validate_trusted_ancestor_chain() {
    local current="$1" parent
    while [[ ! -e "$current" && ! -L "$current" ]]; do
        parent="$(dirname -- "$current")"
        [[ "$parent" != "$current" ]] || return 1
        current="$parent"
    done
    while true; do
        directory_is_trusted_ancestor "$current" || {
            fail "路径包含可被其他账号替换的不可信祖先目录: $current"
            return 1
        }
        [[ "$current" == "/" ]] && break
        current="$(dirname -- "$current")"
    done
}

validate_managed_directory() {
    local directory="$1" owner mode current_uid
    [[ -d "$directory" && ! -L "$directory" ]] || return 1
    owner="$(stat -c '%u' -- "$directory" 2>/dev/null)" || return 1
    mode="$(stat -c '%a' -- "$directory" 2>/dev/null)" || return 1
    current_uid="${EUID:-$(id -u)}"
    [[ "$owner" == "$current_uid" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 8#22) == 0 ))
}

validate_managed_regular_file() {
    local file="$1" current_uid
    current_uid="${EUID:-$(id -u)}"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    [[ "$(stat -c '%u' -- "$file" 2>/dev/null)" == "$current_uid" ]] || return 1
    [[ "$(stat -c '%h' -- "$file" 2>/dev/null)" == "1" ]]
}

create_managed_file_if_missing() {
    local file="$1"
    if [[ ! -e "$file" && ! -L "$file" ]]; then
        (set -o noclobber; umask 077; : >"$file") 2>/dev/null || true
    fi
    validate_managed_regular_file "$file"
}

validate_paths() {
    local resolved_data resolved_backup resolved_log resolved_lock

    resolved_data="$(canonicalize_without_symlinks "$REQUESTED_VNSTAT_DATA_DIR" "vnstat 数据目录")" || return 1
    resolved_backup="$(canonicalize_without_symlinks "$REQUESTED_BACKUP_DIR" "备份目录")" || return 1
    resolved_log="$(canonicalize_without_symlinks "$REQUESTED_LOG_FILE" "日志文件")" || return 1
    resolved_lock="$(canonicalize_without_symlinks "$REQUESTED_MAINTENANCE_LOCK" "维护锁文件")" || return 1

    if [[ "$resolved_data" != "/var/lib/vnstat" && "${FLOWMASTER_ALLOW_CUSTOM_VNSTAT_DATA_DIR:-0}" != "1" ]]; then
        fail "自定义 vnstat 数据目录需要显式设置 FLOWMASTER_ALLOW_CUSTOM_VNSTAT_DATA_DIR=1"
        return 1
    fi
    case "$resolved_data" in
        /|/bin|/bin/*|/boot|/boot/*|/dev|/dev/*|/etc|/etc/*|/lib|/lib/*|/lib64|/lib64/*|/proc|/proc/*|/run|/run/*|/sbin|/sbin/*|/sys|/sys/*|/usr|/usr/*|/var|/var/lib|/var/log|/var/log/*|/var/backups|/var/backups/*|/home|/root|/opt|/tmp)
            fail "拒绝对系统或过宽目录执行 vnstat 数据操作: $resolved_data"
            return 1
            ;;
    esac
    case "$resolved_backup" in
        /|/bin|/bin/*|/boot|/boot/*|/dev|/dev/*|/etc|/etc/*|/lib|/lib/*|/lib64|/lib64/*|/proc|/proc/*|/run|/run/*|/sbin|/sbin/*|/sys|/sys/*|/usr|/usr/*|/var|/var/lib|/var/lib/*|/var/log|/var/log/*|/var/backups|/home|/root|/opt|/tmp)
            fail "备份目录过宽或不安全: $resolved_backup"
            return 1
            ;;
    esac

    if path_is_same_or_descendant "$resolved_backup" "$resolved_data" || \
       path_is_same_or_descendant "$resolved_data" "$resolved_backup"; then
        fail "vnstat 数据目录与备份目录不得相同或互为祖先目录"
        return 1
    fi
    if path_is_same_or_descendant "$resolved_log" "$resolved_data"; then
        fail "备份日志不得位于 vnstat 数据目录内"
        return 1
    fi
    if path_is_same_or_descendant "$resolved_lock" "$resolved_data" || \
       path_is_same_or_descendant "$resolved_lock" "$resolved_backup"; then
        fail "维护锁文件不得位于 vnstat 数据目录或备份目录内"
        return 1
    fi

    validate_trusted_ancestor_chain "$(dirname -- "$resolved_data")" || return 1
    validate_trusted_ancestor_chain "$(dirname -- "$resolved_backup")" || return 1
    validate_trusted_ancestor_chain "$(dirname -- "$resolved_log")" || return 1
    validate_trusted_ancestor_chain "$(dirname -- "$resolved_lock")" || return 1

    if [[ -e "$resolved_data" && ( ! -d "$resolved_data" || -L "$resolved_data" ) ]]; then
        fail "vnstat 数据路径不是可信普通目录: $resolved_data"
        return 1
    fi
    if [[ -e "$resolved_backup" && ( ! -d "$resolved_backup" || -L "$resolved_backup" ) ]]; then
        fail "备份路径不是可信普通目录: $resolved_backup"
        return 1
    fi
    if [[ -e "$resolved_backup" ]] && ! validate_managed_directory "$resolved_backup"; then
        fail "备份目录必须由当前账号所有，且不可由组或其他账号写入: $resolved_backup"
        return 1
    fi
    if [[ -e "$resolved_log" && ( ! -f "$resolved_log" || -L "$resolved_log" ) ]]; then
        fail "日志路径不是可信普通文件: $resolved_log"
        return 1
    fi
    if [[ -e "$resolved_log" ]] && ! validate_managed_regular_file "$resolved_log"; then
        fail "日志文件必须由当前账号所有且不得是硬链接: $resolved_log"
        return 1
    fi
    if [[ -e "$resolved_lock" && ( ! -f "$resolved_lock" || -L "$resolved_lock" ) ]]; then
        fail "维护锁不是可信普通文件: $resolved_lock"
        return 1
    fi
    if [[ -e "$resolved_lock" ]] && ! validate_managed_regular_file "$resolved_lock"; then
        fail "维护锁必须由当前账号所有且不得是硬链接: $resolved_lock"
        return 1
    fi

    VNSTAT_DATA_PATH="$resolved_data"
    BACKUP_PATH="$resolved_backup"
    LOG_PATH="$resolved_log"
    MAINTENANCE_LOCK_PATH="$resolved_lock"
    PATHS_VALIDATED=true
}

ensure_paths_validated() {
    [[ "$PATHS_VALIDATED" == true ]] || validate_paths
}

prepare_backup_directory() {
    ensure_paths_validated || return 1
    mkdir -p -- "$BACKUP_PATH" || return 1
    [[ ! -L "$BACKUP_PATH" && "$(realpath -m -- "$BACKUP_PATH")" == "$BACKUP_PATH" ]] || return 1
    validate_trusted_ancestor_chain "$(dirname -- "$BACKUP_PATH")" || return 1
    [[ "$(stat -c '%u' -- "$BACKUP_PATH" 2>/dev/null)" == "${EUID:-$(id -u)}" ]] || return 1
    chmod 0700 -- "$BACKUP_PATH" || return 1
    validate_managed_directory "$BACKUP_PATH"
}

acquire_maintenance_lock() {
    ensure_paths_validated || return 1
    [[ -z "$MAINTENANCE_LOCK_FD" ]] || return 0
    command -v flock >/dev/null 2>&1 || { fail "缺少 flock，无法安全执行维护操作"; return 1; }

    local lock_parent lock_identity fd_identity
    lock_parent="$(dirname "$MAINTENANCE_LOCK_PATH")"
    validate_trusted_ancestor_chain "$lock_parent" || { fail "维护锁目录不存在或不可信: $lock_parent"; return 1; }
    create_managed_file_if_missing "$MAINTENANCE_LOCK_PATH" || { fail "维护锁不是可信的当前账号普通文件"; return 1; }
    chmod 0600 -- "$MAINTENANCE_LOCK_PATH" || { MAINTENANCE_LOCK_FD=""; return 1; }
    exec {MAINTENANCE_LOCK_FD}>>"$MAINTENANCE_LOCK_PATH" || { MAINTENANCE_LOCK_FD=""; return 1; }
    lock_identity="$(stat -Lc '%d:%i' -- "$MAINTENANCE_LOCK_PATH" 2>/dev/null)" || lock_identity=""
    fd_identity="$(stat -Lc '%d:%i' -- "/proc/self/fd/$MAINTENANCE_LOCK_FD" 2>/dev/null)" || fd_identity=""
    if [[ -z "$lock_identity" || "$lock_identity" != "$fd_identity" ]]; then
        exec {MAINTENANCE_LOCK_FD}>&-
        MAINTENANCE_LOCK_FD=""
        fail "维护锁在打开期间被替换"
        return 1
    fi
    if ! flock -n "$MAINTENANCE_LOCK_FD"; then
        exec {MAINTENANCE_LOCK_FD}>&-
        MAINTENANCE_LOCK_FD=""
        fail "另一个 FlowMaster 安装、备份或恢复流程正在运行"
        return 1
    fi
    if [[ "$(stat -Lc '%d:%i' -- "$MAINTENANCE_LOCK_PATH" 2>/dev/null || true)" != "$fd_identity" ]] || \
       ! validate_managed_regular_file "$MAINTENANCE_LOCK_PATH"; then
        flock -u "$MAINTENANCE_LOCK_FD" >/dev/null 2>&1 || true
        exec {MAINTENANCE_LOCK_FD}>&-
        MAINTENANCE_LOCK_FD=""
        fail "维护锁在加锁期间被替换"
        return 1
    fi
}

release_maintenance_lock() {
    [[ -n "$MAINTENANCE_LOCK_FD" ]] || return 0
    flock -u "$MAINTENANCE_LOCK_FD" >/dev/null 2>&1 || true
    exec {MAINTENANCE_LOCK_FD}>&-
    MAINTENANCE_LOCK_FD=""
}

sync_path_durably() {
    local path="$1"
    [[ -e "$path" && ! -L "$path" ]] || return 1
    sync -f -- "$path"
}

sync_parent_directory_durably() {
    local path="$1" parent
    parent="$(dirname -- "$path")" || return 1
    [[ -d "$parent" && ! -L "$parent" ]] || return 1
    sync -f -- "$parent"
}

run_systemctl_bounded() {
    [[ "$SYSTEMCTL_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || {
        fail "FLOWMASTER_SYSTEMCTL_TIMEOUT_SECONDS 必须是正整数"
        return 1
    }
    (( SYSTEMCTL_TIMEOUT_SECONDS <= 120 )) || {
        fail "FLOWMASTER_SYSTEMCTL_TIMEOUT_SECONDS 不能超过 120 秒"
        return 1
    }
    timeout --signal=TERM --kill-after=2s "${SYSTEMCTL_TIMEOUT_SECONDS}s" systemctl "$@"
}

read_service_state() {
    local service_name="$1"
    local state
    state="$(run_systemctl_bounded show "$service_name" --property=ActiveState --value 2>/dev/null)" || return 1
    case "$state" in
        active|inactive|failed|activating|deactivating|reloading|maintenance) printf '%s\n' "$state" ;;
        *) return 1 ;;
    esac
}

validate_control_group_path() {
    local control_group="$1"
    [[ "$control_group" == /* && "$control_group" != "/" ]] || return 1
    [[ "$control_group" != *$'\n'* && "$control_group" != *$'\r'* && "$control_group" != *//* ]] || return 1
    case "/${control_group#/}/" in
        */../*|*/./*) return 1 ;;
    esac
}

cgroup_tree_has_no_processes() {
    local cgroup_root="$1"
    local control_group="$2"
    local target process_file process_id unsafe_symlink
    local process_file_count=0

    [[ -d "$cgroup_root" && ! -L "$cgroup_root" ]] || return 1
    validate_control_group_path "$control_group" || return 1
    target="${cgroup_root%/}${control_group}"
    [[ "$target" == "${cgroup_root%/}/"* ]] || return 1

    # unit 已完全退出后 systemd 会删除 cgroup；不存在即表示没有可残留的成员。
    [[ -e "$target" || -L "$target" ]] || return 0
    [[ -d "$target" && ! -L "$target" ]] || return 1
    [[ "$(realpath -m -- "$target")" == "$target" ]] || return 1
    unsafe_symlink="$(find -P "$target" -type l -print -quit 2>/dev/null)" || return 1
    [[ -z "$unsafe_symlink" ]] || return 1
    find -P "$target" -type f \( -name cgroup.procs -o -name tasks \) -print -quit >/dev/null 2>&1 || return 1

    # 同时覆盖 cgroup v2 的 cgroup.procs 和 v1 的 tasks，并递归检查委派子 cgroup。
    while IFS= read -r -d '' process_file; do
        ((process_file_count += 1))
        [[ -f "$process_file" && ! -L "$process_file" && -r "$process_file" ]] || return 1
        process_id="$(cat -- "$process_file")" || return 1
        [[ -z "$process_id" ]] || return 1
    done < <(find -P "$target" -type f \( -name cgroup.procs -o -name tasks \) -print0 2>/dev/null)
    (( process_file_count > 0 ))
}

unit_cgroup_is_empty() {
    local control_group="$1"
    local cgroup_root=/sys/fs/cgroup
    local controller_root target

    # inactive unit 通常已经没有 ControlGroup；PID 同时为零时可视为已被 systemd 回收。
    [[ -n "$control_group" ]] || return 0
    validate_control_group_path "$control_group" || return 1
    [[ -d "$cgroup_root" && ! -L "$cgroup_root" ]] || return 1

    if [[ -f "$cgroup_root/cgroup.controllers" && ! -L "$cgroup_root/cgroup.controllers" ]]; then
        cgroup_tree_has_no_processes "$cgroup_root" "$control_group"
        return
    fi

    # 兼容仍使用多个 controller 挂载点的 cgroup v1 主机。
    for controller_root in "$cgroup_root"/*; do
        [[ -d "$controller_root" && ! -L "$controller_root" ]] || continue
        target="${controller_root%/}${control_group}"
        [[ -e "$target" || -L "$target" ]] || continue
        cgroup_tree_has_no_processes "$controller_root" "$control_group" || return 1
    done
    # 没有任何 controller 仍保留该 unit 的 cgroup，也表示 systemd 已完成回收。
    return 0
}

service_has_valid_inactive_runtime() {
    local service_name="$1"
    local signature_variable="${2:-}"
    local properties key value
    local active_state="" main_pid="" control_pid="" control_group=""
    local seen_active=0 seen_main_pid=0 seen_control_pid=0 seen_control_group=0

    properties="$(run_systemctl_bounded show "$service_name" \
        --property=ActiveState \
        --property=MainPID \
        --property=ControlPID \
        --property=ControlGroup 2>/dev/null)" || return 1

    while IFS='=' read -r key value; do
        case "$key" in
            ActiveState)
                (( seen_active == 0 )) || return 1
                active_state="$value"
                seen_active=1
                ;;
            MainPID)
                (( seen_main_pid == 0 )) || return 1
                main_pid="$value"
                seen_main_pid=1
                ;;
            ControlPID)
                (( seen_control_pid == 0 )) || return 1
                control_pid="$value"
                seen_control_pid=1
                ;;
            ControlGroup)
                (( seen_control_group == 0 )) || return 1
                control_group="$value"
                seen_control_group=1
                ;;
            '') ;;
            *) return 1 ;;
        esac
    done <<<"$properties"

    (( seen_active == 1 && seen_main_pid == 1 && seen_control_pid == 1 && seen_control_group == 1 )) || return 1
    [[ "$active_state" == "inactive" || "$active_state" == "failed" ]] || return 1
    [[ "$main_pid" == "0" && "$control_pid" == "0" ]] || return 1
    unit_cgroup_is_empty "$control_group" || return 1

    if [[ -n "$signature_variable" ]]; then
        [[ "$signature_variable" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || return 1
        printf -v "$signature_variable" '%s' "${active_state}:0:0:${control_group}"
    fi
}

service_has_valid_active_runtime() {
    local service_name="$1"
    local signature_variable="${2:-}"
    local properties key value
    local active_state="" sub_state="" service_type="" main_pid="" result=""
    local seen_active=0 seen_sub=0 seen_type=0 seen_pid=0 seen_result=0

    properties="$(run_systemctl_bounded show "$service_name" \
        --property=ActiveState \
        --property=SubState \
        --property=Type \
        --property=MainPID \
        --property=Result 2>/dev/null)" || return 1

    while IFS='=' read -r key value; do
        case "$key" in
            ActiveState)
                (( seen_active == 0 )) || return 1
                active_state="$value"
                seen_active=1
                ;;
            SubState)
                (( seen_sub == 0 )) || return 1
                sub_state="$value"
                seen_sub=1
                ;;
            Type)
                (( seen_type == 0 )) || return 1
                service_type="$value"
                seen_type=1
                ;;
            MainPID)
                (( seen_pid == 0 )) || return 1
                main_pid="$value"
                seen_pid=1
                ;;
            Result)
                (( seen_result == 0 )) || return 1
                result="$value"
                seen_result=1
                ;;
            '') ;;
            *) return 1 ;;
        esac
    done <<<"$properties"

    (( seen_active == 1 && seen_sub == 1 && seen_type == 1 && seen_pid == 1 && seen_result == 1 )) || return 1
    [[ "$active_state" == "active" && "$result" == "success" ]] || return 1

    local runtime_signature
    case "$service_type" in
        oneshot)
            # RemainAfterExit=yes 的 oneshot 没有常驻主进程，稳定状态应为 exited。
            [[ "$sub_state" == "exited" && "$main_pid" == "0" ]] || return 1
            runtime_signature="oneshot:exited:0"
            ;;
        simple|exec|forking|dbus|notify|notify-reload|idle)
            # 常驻 service 必须仍在 running，且 systemd 能给出有效主进程。
            [[ "$sub_state" == "running" && "$main_pid" =~ ^[1-9][0-9]*$ ]] || return 1
            runtime_signature="${service_type}:running:${main_pid}"
            ;;
        *) return 1 ;;
    esac
    if [[ -n "$signature_variable" ]]; then
        [[ "$signature_variable" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || return 1
        printf -v "$signature_variable" '%s' "$runtime_signature"
    fi
}

valid_service_wait_interval() {
    local interval="$1"
    [[ "$interval" =~ ^(0|[0-9]+([.][0-9]+)?)$ ]] || return 1
    awk -v interval="$interval" 'BEGIN { exit !(interval >= 0 && interval <= 5) }'
}

wait_for_service_state() {
    local service_name="$1"
    local expected_state="$2"
    local attempts="${FLOWMASTER_SERVICE_VERIFY_ATTEMPTS:-20}"
    local interval="${FLOWMASTER_SERVICE_VERIFY_INTERVAL_SECONDS:-0.25}"
    local stable_observations="${FLOWMASTER_SERVICE_STABILITY_OBSERVATIONS:-5}"
    local stability_interval="${FLOWMASTER_SERVICE_STABILITY_INTERVAL_SECONDS:-0.5}"
    [[ "$attempts" =~ ^[1-9][0-9]*$ ]] && (( attempts <= 120 )) || return 1
    valid_service_wait_interval "$interval" || return 1
    [[ "$expected_state" == "active" || "$expected_state" == "inactive" ]] || return 1

    local attempt observation initial_signature current_signature
    for ((attempt=0; attempt<attempts; attempt++)); do
        if [[ "$expected_state" == "active" ]]; then
            if service_has_valid_active_runtime "$service_name" initial_signature; then
                [[ "$stable_observations" =~ ^[0-9]+$ ]] && \
                    (( stable_observations >= 2 && stable_observations <= 20 )) || return 1
                valid_service_wait_interval "$stability_interval" || return 1
                for ((observation=1; observation<stable_observations; observation++)); do
                    sleep "$stability_interval"
                    service_has_valid_active_runtime "$service_name" current_signature || return 1
                    [[ "$current_signature" == "$initial_signature" ]] || return 1
                done
                return 0
            fi
        else
            if service_has_valid_inactive_runtime "$service_name" initial_signature; then
                [[ "$stable_observations" =~ ^[0-9]+$ ]] && \
                    (( stable_observations >= 2 && stable_observations <= 20 )) || return 1
                valid_service_wait_interval "$stability_interval" || return 1
                for ((observation=1; observation<stable_observations; observation++)); do
                    sleep "$stability_interval"
                    service_has_valid_inactive_runtime "$service_name" current_signature || return 1
                    [[ "$current_signature" == "$initial_signature" ]] || return 1
                done
                return 0
            fi
        fi
        (( attempt + 1 >= attempts )) || sleep "$interval"
    done
    return 1
}

stop_services() {
    [[ "$SERVICES_STOPPED" == false ]] || return 0
    VNSTAT_WAS_ACTIVE=false
    FLOWMASTER_WAS_ACTIVE=false
    local vnstat_state flowmaster_state
    vnstat_state="$(read_service_state vnstat)" || { warn "无法读取 vnstat 的 systemd 状态"; return 1; }
    flowmaster_state="$(read_service_state flowmaster.service)" || { warn "无法读取 flowmaster.service 的 systemd 状态"; return 1; }
    case "$vnstat_state" in
        active) VNSTAT_WAS_ACTIVE=true ;;
        inactive|failed) ;;
        *) warn "vnstat 当前处于过渡状态: $vnstat_state"; return 1 ;;
    esac
    case "$flowmaster_state" in
        active) FLOWMASTER_WAS_ACTIVE=true ;;
        inactive|failed) ;;
        *) warn "flowmaster.service 当前处于过渡状态: $flowmaster_state"; return 1 ;;
    esac

    # 先标记为已进入停服阶段，任何后续失败都由事务或 EXIT trap 恢复原状态。
    SERVICES_STOPPED=true
    local stop_failed=false
    if [[ "$FLOWMASTER_WAS_ACTIVE" == true ]] && \
       { ! run_systemctl_bounded --no-block stop flowmaster.service || ! wait_for_service_state flowmaster.service inactive; }; then
        warn "停止 flowmaster.service 失败"
        stop_failed=true
    fi
    if [[ "$stop_failed" == false && "$VNSTAT_WAS_ACTIVE" == true ]] && \
       { ! run_systemctl_bounded --no-block stop vnstat || ! wait_for_service_state vnstat inactive; }; then
        warn "停止 vnstat 失败"
        stop_failed=true
    fi
    if [[ "$stop_failed" == false ]] && \
       { ! wait_for_service_state flowmaster.service inactive || ! wait_for_service_state vnstat inactive; }; then
        warn "服务未保持稳定停止状态，拒绝操作 vnstat 数据库"
        stop_failed=true
    fi
    if [[ "$stop_failed" == true ]]; then
        if ! restore_services; then
            warn "停服失败后未能完整恢复原服务状态，请立即检查 systemd"
        fi
        return 1
    fi
    return 0
}

restore_services() {
    [[ "$SERVICES_STOPPED" == true ]] || return 0
    local restore_failed=false
    if [[ "$VNSTAT_WAS_ACTIVE" == true ]]; then
        if ! run_systemctl_bounded --no-block start vnstat || ! wait_for_service_state vnstat active; then
            warn "恢复 vnstat 失败或服务未保持 active"
            restore_failed=true
        fi
    fi
    if [[ "$FLOWMASTER_WAS_ACTIVE" == true ]]; then
        if [[ "$restore_failed" == true ]]; then
            warn "vnstat 未恢复，暂不启动 flowmaster.service"
        elif ! run_systemctl_bounded --no-block start flowmaster.service || ! wait_for_service_state flowmaster.service active; then
            warn "恢复 flowmaster.service 失败或服务未保持 active"
            restore_failed=true
        fi
    fi
    [[ "$restore_failed" == false ]] || return 1
    SERVICES_STOPPED=false
    return 0
}

safe_remove_temporary_path() {
    local target="$1"
    [[ -n "$target" ]] || return 0
    case "$target" in
        "$BACKUP_PATH"/.snapshot.*|"$BACKUP_PATH"/.restore.*)
            [[ ! -e "$target" && ! -L "$target" ]] || rm -rf --one-file-system -- "$target"
            ;;
        "$BACKUP_PATH"/vnstat-*.tar.gz.tmp)
            rm -f -- "$target"
            ;;
        "$BACKUP_PATH"/vnstat-*.tar.gz.sha256.tmp)
            rm -f -- "$target"
            ;;
        "${VNSTAT_DATA_PATH}.restore."*)
            [[ -n "$VNSTAT_DATA_PATH" ]] || return 1
            [[ ! -e "$target" && ! -L "$target" ]] || {
                [[ -d "$target" && ! -L "$target" ]] || return 1
                rm -rf --one-file-system -- "$target"
            }
            ;;
        *)
            warn "拒绝清理非预期临时路径: $target"
            return 1
            ;;
    esac
}

cleanup_temporary_paths() {
    local failed=0
    safe_remove_temporary_path "$ARCHIVE_SNAPSHOT_DIR" || failed=1
    safe_remove_temporary_path "$RESTORE_EXTRACT_DIR" || failed=1
    safe_remove_temporary_path "$ARCHIVE_TMP_FILE" || failed=1
    safe_remove_temporary_path "$ARCHIVE_SIDECAR_TMP_FILE" || failed=1
    safe_remove_temporary_path "$RESTORE_STAGED_PATH" || failed=1
    if [[ -n "$ARCHIVE_PENDING_FILE" ]]; then
        case "$ARCHIVE_PENDING_FILE" in
            "$BACKUP_PATH"/vnstat-*.tar.gz)
                rm -f -- "$ARCHIVE_PENDING_FILE" "${ARCHIVE_PENDING_FILE}.sha256" || failed=1
                ;;
            *)
                warn "拒绝清理非预期未提交归档: $ARCHIVE_PENDING_FILE"
                failed=1
                ;;
        esac
    fi
    ARCHIVE_SNAPSHOT_DIR=""
    RESTORE_EXTRACT_DIR=""
    ARCHIVE_TMP_FILE=""
    ARCHIVE_SIDECAR_TMP_FILE=""
    RESTORE_STAGED_PATH=""
    ARCHIVE_PENDING_FILE=""
    (( failed == 0 ))
}

cleanup_unique_rollback_reservation() {
    [[ -n "$UNIQUE_ROLLBACK_PATH" ]] || return 0
    case "$UNIQUE_ROLLBACK_PATH" in
        "${VNSTAT_DATA_PATH}.rollback."*)
            if [[ -e "$UNIQUE_ROLLBACK_PATH" || -L "$UNIQUE_ROLLBACK_PATH" ]]; then
                [[ -d "$UNIQUE_ROLLBACK_PATH" && ! -L "$UNIQUE_ROLLBACK_PATH" ]] || return 1
                # 这里只清理由 mktemp 预留、尚未承载原数据库的空目录。
                rmdir -- "$UNIQUE_ROLLBACK_PATH" || return 1
            fi
            UNIQUE_ROLLBACK_PATH=""
            ;;
        *)
            warn "拒绝清理非预期回滚预留路径: $UNIQUE_ROLLBACK_PATH"
            return 1
            ;;
    esac
}

quiesce_services_for_rollback() {
    local failed=false
    local flowmaster_state vnstat_state
    flowmaster_state="$(read_service_state flowmaster.service)" || {
        warn "回滚前无法读取 flowmaster.service 状态"
        return 1
    }
    if [[ "$flowmaster_state" != "inactive" && "$flowmaster_state" != "failed" ]] && \
       { ! run_systemctl_bounded --no-block stop flowmaster.service || ! wait_for_service_state flowmaster.service inactive; }; then
        warn "回滚前无法停止 flowmaster.service"
        failed=true
    fi
    vnstat_state="$(read_service_state vnstat)" || {
        warn "回滚前无法读取 vnstat 状态"
        return 1
    }
    if [[ "$failed" == false && "$vnstat_state" != "inactive" && "$vnstat_state" != "failed" ]] && \
       { ! run_systemctl_bounded --no-block stop vnstat || ! wait_for_service_state vnstat inactive; }; then
        warn "回滚前无法停止 vnstat"
        failed=true
    fi
    [[ "$failed" == false ]] || return 1
    SERVICES_STOPPED=true
}

remove_restore_target() {
    [[ "$PATHS_VALIDATED" == true && -n "$VNSTAT_DATA_PATH" ]] || return 1
    [[ ! -e "$VNSTAT_DATA_PATH" && ! -L "$VNSTAT_DATA_PATH" ]] && return 0
    [[ -d "$VNSTAT_DATA_PATH" && ! -L "$VNSTAT_DATA_PATH" ]] || return 1
    rm -rf --one-file-system -- "$VNSTAT_DATA_PATH"
}

rollback_restore_transaction() {
    [[ "$RESTORE_TRANSACTION_ACTIVE" == true ]] || return 0
    quiesce_services_for_rollback || return 1

    if [[ "$RESTORE_ORIGINAL_PRESENT" == true ]]; then
        if [[ -d "$RESTORE_ROLLBACK_PATH" && ! -L "$RESTORE_ROLLBACK_PATH" ]]; then
            # mv 与下一条 Shell 赋值之间也可能收到信号，因此以磁盘状态为准。
            remove_restore_target || return 1
            mv -- "$RESTORE_ROLLBACK_PATH" "$VNSTAT_DATA_PATH" || return 1
        elif [[ -d "$VNSTAT_DATA_PATH" && ! -L "$VNSTAT_DATA_PATH" ]]; then
            # 可能是原目录尚未移走，也可能是旧库刚移回后收到二次信号；
            # 两种磁盘状态都表示活动路径已经承载原数据库。
            :
        else
            return 1
        fi
        # 只有旧库内容及其目录项都已落盘，才允许重新启动原服务并结束回滚。
        sync_path_durably "$VNSTAT_DATA_PATH" || return 1
        sync_parent_directory_durably "$VNSTAT_DATA_PATH" || return 1
        # 先撤销“新目标可删除”标志，避免二次信号把刚移回的旧库误删。
        RESTORE_TARGET_CREATED=false
        RESTORE_ORIGINAL_PRESENT=false
        RESTORE_ROLLBACK_PATH=""
    elif [[ "$RESTORE_TARGET_CREATED" == true ]]; then
        remove_restore_target || return 1
        sync_parent_directory_durably "$VNSTAT_DATA_PATH" || return 1
        RESTORE_TARGET_CREATED=false
    fi

    RESTORE_ORIGINAL_PRESENT=false
    RESTORE_TARGET_CREATED=false
    RESTORE_ROLLBACK_PATH=""
    RESTORE_TRANSACTION_ACTIVE=false
    restore_services
}

handle_exit() {
    local original_status="$1"
    local cleanup_failed=0
    set +e
    if [[ "$RESTORE_TRANSACTION_ACTIVE" == true ]]; then
        rollback_restore_transaction || cleanup_failed=1
    elif [[ "$SERVICES_STOPPED" == true ]]; then
        restore_services || cleanup_failed=1
    fi
    cleanup_temporary_paths || cleanup_failed=1
    cleanup_unique_rollback_reservation || cleanup_failed=1
    release_maintenance_lock
    if (( original_status != 0 )); then
        return "$original_status"
    fi
    (( cleanup_failed == 0 ))
}

trap '_flowmaster_status=$?; trap - EXIT; trap "" INT TERM HUP; handle_exit "$_flowmaster_status"; exit $?' EXIT
trap 'exit 130' INT TERM HUP

record_log() {
    ensure_paths_validated || return 1
    local log_parent log_fd log_identity fd_identity
    log_parent="$(dirname "$LOG_PATH")"
    mkdir -p -- "$log_parent" || return 1
    [[ ! -L "$log_parent" && "$(realpath -m -- "$log_parent")" == "$log_parent" ]] || return 1
    validate_trusted_ancestor_chain "$log_parent" || return 1
    [[ "$(stat -c '%u' -- "$log_parent" 2>/dev/null)" == "${EUID:-$(id -u)}" ]] || return 1
    create_managed_file_if_missing "$LOG_PATH" || return 1
    chmod 0600 -- "$LOG_PATH" || return 1
    exec {log_fd}>>"$LOG_PATH" || return 1
    log_identity="$(stat -Lc '%d:%i' -- "$LOG_PATH" 2>/dev/null)" || log_identity=""
    fd_identity="$(stat -Lc '%d:%i' -- "/proc/self/fd/$log_fd" 2>/dev/null)" || fd_identity=""
    if [[ -z "$log_identity" || "$log_identity" != "$fd_identity" ]] || \
       ! validate_managed_regular_file "$LOG_PATH"; then
        exec {log_fd}>&-
        return 1
    fi
    printf '%s %s\n' "$(date --iso-8601=seconds)" "$*" >&"$log_fd"
    local write_status=$?
    exec {log_fd}>&-
    return "$write_status"
}

validate_data_tree() {
    local data_dir="$1"
    local unsafe=""
    [[ -d "$data_dir" && ! -L "$data_dir" ]] || return 1
    if IFS= read -r -d '' unsafe < <(
        find "$data_dir" -mindepth 1 \( -type l -o \( ! -type d ! -type f \) \) -print0
    ); then
        warn "备份数据包含不允许的链接或特殊文件: $unsafe"
        return 1
    fi
    if IFS= read -r -d '' unsafe < <(find "$data_dir" -type f -links +1 -print0); then
        warn "备份数据包含硬链接文件: $unsafe"
        return 1
    fi
}

write_data_manifest() {
    local archive_root="$1"
    local output_file="$2"
    (
        cd "$archive_root"
        find data -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
    ) >"$output_file"
}

validate_extracted_archive() {
    local extracted="$1"
    local entry name
    local seen_data=0 seen_metadata=0 seen_json=0 seen_checksums=0

    while IFS= read -r -d '' entry; do
        name="${entry##*/}"
        case "$name" in
            data) ((seen_data += 1)) ;;
            metadata.txt) ((seen_metadata += 1)) ;;
            vnstat.json) ((seen_json += 1)) ;;
            checksums.sha256) ((seen_checksums += 1)) ;;
            *) warn "归档包含未授权的顶层成员: $name"; return 1 ;;
        esac
    done < <(find "$extracted" -mindepth 1 -maxdepth 1 -print0)

    (( seen_data == 1 && seen_metadata == 1 && seen_json == 1 && seen_checksums == 1 )) || return 1
    [[ -d "$extracted/data" && ! -L "$extracted/data" ]] || return 1
    [[ -f "$extracted/metadata.txt" && ! -L "$extracted/metadata.txt" ]] || return 1
    [[ -f "$extracted/vnstat.json" && ! -L "$extracted/vnstat.json" ]] || return 1
    [[ -f "$extracted/checksums.sha256" && ! -L "$extracted/checksums.sha256" ]] || return 1
    validate_data_tree "$extracted/data" || return 1

    local actual_manifest="$extracted/.checksums.actual.$$.$RANDOM"
    if ! write_data_manifest "$extracted" "$actual_manifest" || \
       ! cmp -s -- "$extracted/checksums.sha256" "$actual_manifest"; then
        rm -f -- "$actual_manifest"
        return 1
    fi
    rm -f -- "$actual_manifest"
}

validate_archive_members() {
    local archive="$1"
    local member normalized line entry_size archive_size member_count=0 type_count=0 expanded_size=0
    local seen_data=0 seen_metadata=0 seen_json=0 seen_checksums=0
    declare -A seen_members=()

    validate_managed_regular_file "$archive" || return 1
    archive_size="$(stat -c '%s' -- "$archive" 2>/dev/null || true)"
    [[ "$archive_size" =~ ^[1-9][0-9]*$ ]] && (( archive_size <= ARCHIVE_MAX_BYTES )) || return 1
    LC_ALL=C tar --quoting-style=escape -tzf "$archive" >/dev/null || return 1
    while IFS= read -r member; do
        [[ -n "$member" ]] || continue
        normalized="${member%/}"
        [[ "$normalized" != /* && "$normalized" != "." && "$normalized" != *"//"* ]] || return 1
        case "/$normalized/" in
            */../*|*/./*) return 1 ;;
        esac
        case "$normalized" in
            data) ((seen_data += 1)) ;;
            data/*) ;;
            metadata.txt) ((seen_metadata += 1)) ;;
            vnstat.json) ((seen_json += 1)) ;;
            checksums.sha256) ((seen_checksums += 1)) ;;
            *) return 1 ;;
        esac
        [[ -z "${seen_members[$normalized]+x}" ]] || return 1
        seen_members["$normalized"]=1
        ((member_count += 1))
        (( member_count <= ARCHIVE_MAX_MEMBERS )) || return 1
    done < <(LC_ALL=C tar --quoting-style=escape -tzf "$archive")

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        case "${line:0:1}" in
            -|d) ;;
            *) return 1 ;;
        esac
        entry_size="$(awk '{ print $3 }' <<<"$line")"
        [[ "$entry_size" =~ ^[0-9]+$ ]] || return 1
        expanded_size=$((expanded_size + entry_size))
        (( expanded_size <= ARCHIVE_MAX_EXPANDED_BYTES )) || return 1
        ((type_count += 1))
    done < <(LC_ALL=C tar --quoting-style=escape -tvzf "$archive")

    (( member_count > 0 && member_count == type_count )) || return 1
    (( seen_data == 1 && seen_metadata == 1 && seen_json == 1 && seen_checksums == 1 ))
}

validate_vnstat_database() {
    local data_dir="$1"
    local interface_count
    validate_data_tree "$data_dir" || return 1
    interface_count="$(vnstat --dbdir "$data_dir" --dbiflist 2 2>/dev/null)" || return 1
    [[ "$interface_count" =~ ^[1-9][0-9]*$ ]] || return 1
    vnstat --dbdir "$data_dir" --json >/dev/null 2>&1
}

validate_archive_sidecar() {
    local archive="$1"
    local sidecar="${archive}.sha256"
    [[ -e "$sidecar" || -L "$sidecar" ]] || { warn "备份缺少外部 SHA-256 文件"; return 1; }
    [[ -f "$sidecar" && ! -L "$sidecar" ]] || return 1

    local -a lines=()
    mapfile -t lines <"$sidecar"
    (( ${#lines[@]} == 1 )) || return 1
    local line="${lines[0]}"
    local archive_name="${archive##*/}"
    (( ${#line} == 66 + ${#archive_name} )) || return 1
    local expected_hash="${line:0:64}"
    local separator="${line:64:2}"
    local expected_name="${line:66}"
    [[ "$expected_hash" =~ ^[[:xdigit:]]{64}$ && "$separator" == "  " && "$expected_name" == "$archive_name" ]] || return 1

    local actual_hash
    actual_hash="$(sha256sum "$archive" | awk '{print $1}')" || return 1
    [[ "${actual_hash,,}" == "${expected_hash,,}" ]]
}

create_archive() {
    local archive="$1"
    prepare_backup_directory || return 1
    LAST_ARCHIVE_HASH=""
    ARCHIVE_SNAPSHOT_DIR="$(mktemp -d "$BACKUP_PATH/.snapshot.XXXXXX")" || return 1
    ARCHIVE_TMP_FILE="${archive}.tmp"
    ARCHIVE_SIDECAR_TMP_FILE="${archive}.sha256.tmp"
    [[ ! -e "$archive" && ! -L "$archive" && \
       ! -e "${archive}.sha256" && ! -L "${archive}.sha256" ]] || {
        cleanup_temporary_paths
        return 1
    }
    ARCHIVE_PENDING_FILE="$archive"

    if ! cp -a -- "$VNSTAT_DATA_PATH" "$ARCHIVE_SNAPSHOT_DIR/data" || \
       ! validate_vnstat_database "$ARCHIVE_SNAPSHOT_DIR/data"; then
        cleanup_temporary_paths
        return 1
    fi
    vnstat --dbdir "$ARCHIVE_SNAPSHOT_DIR/data" --json >"$ARCHIVE_SNAPSHOT_DIR/vnstat.json" 2>/dev/null || true
    {
        printf 'created_at=%s\n' "$(date --iso-8601=seconds)"
        printf 'hostname=%s\n' "$(hostname)"
        printf 'vnstat_version=%s\n' "$(vnstat --version 2>/dev/null | head -n 1 || echo unknown)"
    } >"$ARCHIVE_SNAPSHOT_DIR/metadata.txt"
    if ! write_data_manifest "$ARCHIVE_SNAPSHOT_DIR" "$ARCHIVE_SNAPSHOT_DIR/checksums.sha256" || \
       ! (cd "$ARCHIVE_SNAPSHOT_DIR" && tar -czf "$ARCHIVE_TMP_FILE" data metadata.txt vnstat.json checksums.sha256) || \
       ! validate_archive_members "$ARCHIVE_TMP_FILE"; then
        cleanup_temporary_paths
        return 1
    fi

    chmod 0600 -- "$ARCHIVE_TMP_FILE" || { cleanup_temporary_paths; return 1; }
    LAST_ARCHIVE_HASH="$(sha256sum "$ARCHIVE_TMP_FILE" | awk '{print $1}')" || { cleanup_temporary_paths; return 1; }
    printf '%s  %s\n' "$LAST_ARCHIVE_HASH" "${archive##*/}" >"$ARCHIVE_SIDECAR_TMP_FILE" || { cleanup_temporary_paths; return 1; }
    chmod 0600 -- "$ARCHIVE_SIDECAR_TMP_FILE" || { cleanup_temporary_paths; return 1; }
    if ! sync_path_durably "$ARCHIVE_TMP_FILE" || \
       ! sync_path_durably "$ARCHIVE_SIDECAR_TMP_FILE"; then
        cleanup_temporary_paths
        return 1
    fi
    mv -- "$ARCHIVE_TMP_FILE" "$archive" || { cleanup_temporary_paths; return 1; }
    ARCHIVE_TMP_FILE=""
    mv -- "$ARCHIVE_SIDECAR_TMP_FILE" "${archive}.sha256" || { cleanup_temporary_paths; return 1; }
    ARCHIVE_SIDECAR_TMP_FILE=""
    if ! validate_archive_sidecar "$archive" || \
       ! sync_path_durably "$archive" || \
       ! sync_path_durably "${archive}.sha256" || \
       ! sync_parent_directory_durably "$archive"; then
        cleanup_temporary_paths
        return 1
    fi
    ARCHIVE_PENDING_FILE=""
    cleanup_temporary_paths
}

backup_data() {
    ensure_paths_validated || return 1
    [[ -d "$VNSTAT_DATA_PATH" && ! -L "$VNSTAT_DATA_PATH" ]] || { fail "vnstat 数据目录不存在或不可信: $VNSTAT_DATA_PATH"; return 1; }
    prepare_backup_directory || return 1
    acquire_maintenance_lock || return 1

    local archive
    archive="$BACKUP_PATH/vnstat-$(date +%Y%m%d-%H%M%S)-$$-${RANDOM}.tar.gz"
    log "正在创建一致性备份..."
    if ! stop_services; then
        [[ "$SERVICES_STOPPED" == false ]] && release_maintenance_lock
        return 1
    fi
    if ! create_archive "$archive"; then
        if restore_services; then
            release_maintenance_lock
        else
            warn "备份失败后未能完整恢复原服务状态"
        fi
        fail "创建备份归档失败"
        return 1
    fi
    if ! restore_services; then
        fail "备份已生成，但未能完整恢复原服务状态"
        return 1
    fi

    release_maintenance_lock
    record_log "backup_created archive=$archive sha256=$LAST_ARCHIVE_HASH"
    log "备份完成: $archive"
    echo -e "${BLUE}SHA-256: $LAST_ARCHIVE_HASH${NC}"
}

list_archive_paths() {
    ensure_paths_validated || return 1
    [[ -d "$BACKUP_PATH" ]] || return 0
    find "$BACKUP_PATH" -maxdepth 1 -type f -name 'vnstat-*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-
}

list_backups() {
    prepare_backup_directory || return 1
    local index=0 archive
    while IFS= read -r archive; do
        [[ -n "$archive" ]] || continue
        index=$((index + 1))
        printf '%-4s %-48s %-10s %s\n' "$index" "$(basename "$archive")" "$(du -h "$archive" | cut -f1)" "$(stat -c '%y' "$archive" | cut -d'.' -f1)"
    done < <(list_archive_paths)
    (( index > 0 )) || warn "没有找到备份"
}

create_unique_rollback_path() {
    UNIQUE_ROLLBACK_PATH="$(mktemp -d "${VNSTAT_DATA_PATH}.rollback.XXXXXX")" || return 1
    rmdir -- "$UNIQUE_ROLLBACK_PATH" || { UNIQUE_ROLLBACK_PATH=""; return 1; }
}

fail_restore_and_rollback() {
    local message="$1"
    local rollback_ok=true
    if ! rollback_restore_transaction; then
        rollback_ok=false
        warn "自动回滚未完整完成；服务保持停止，请从以下位置手工恢复: $RESTORE_ROLLBACK_PATH"
    fi
    cleanup_temporary_paths || true
    if [[ "$rollback_ok" == true ]]; then
        release_maintenance_lock
        fail "$message，已恢复原数据和服务状态"
    else
        fail "$message，且自动回滚失败"
    fi
    return 1
}

restore_data() {
    prepare_backup_directory || return 1
    mapfile -t backups < <(list_archive_paths)
    (( ${#backups[@]} > 0 )) || { fail "没有找到可恢复的备份"; return 1; }

    list_backups
    local choice confirmation
    read -r -p "请选择备份 [1-${#backups[@]}]: " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#backups[@]} )); then
        fail "无效选择"
        return 1
    fi
    local selected="${backups[$((choice - 1))]}"
    read -r -p "确认恢复 $(basename "$selected")？当前数据会先安全归档 [y/N]: " confirmation
    [[ "$confirmation" =~ ^[Yy]$ ]] || { warn "已取消"; return 0; }

    acquire_maintenance_lock || return 1
    [[ -f "$selected" && ! -L "$selected" && "$(dirname "$selected")" == "$BACKUP_PATH" ]] || {
        release_maintenance_lock
        fail "选择的备份路径不可信"
        return 1
    }
    if ! validate_archive_sidecar "$selected" || ! validate_archive_members "$selected"; then
        release_maintenance_lock
        fail "备份归档或外部校验失败"
        return 1
    fi

    RESTORE_EXTRACT_DIR="$(mktemp -d "$BACKUP_PATH/.restore.XXXXXX")" || { release_maintenance_lock; return 1; }
    if ! timeout --signal=TERM --kill-after=5s 120s tar -xzf "$selected" -C "$RESTORE_EXTRACT_DIR" || \
       ! validate_extracted_archive "$RESTORE_EXTRACT_DIR" || \
       ! validate_vnstat_database "$RESTORE_EXTRACT_DIR/data"; then
        cleanup_temporary_paths || true
        release_maintenance_lock
        fail "备份内部结构、文件清单或 vnstat 数据库校验失败"
        return 1
    fi

    # 先在 vnstat 数据目录所在文件系统准备并持久化完整的新库，停服后只做同文件系统 rename。
    RESTORE_STAGED_PATH="$(mktemp -d "${VNSTAT_DATA_PATH}.restore.XXXXXX")" || {
        cleanup_temporary_paths || true
        release_maintenance_lock
        return 1
    }
    rmdir -- "$RESTORE_STAGED_PATH" || {
        cleanup_temporary_paths || true
        release_maintenance_lock
        return 1
    }
    if ! cp -a -- "$RESTORE_EXTRACT_DIR/data" "$RESTORE_STAGED_PATH" || \
       ! validate_vnstat_database "$RESTORE_STAGED_PATH" || \
       ! sync_path_durably "$RESTORE_STAGED_PATH" || \
       ! sync_parent_directory_durably "$RESTORE_STAGED_PATH"; then
        cleanup_temporary_paths || true
        release_maintenance_lock
        fail "无法在 vnstat 文件系统上准备并持久化待恢复数据库"
        return 1
    fi

    if ! stop_services; then
        cleanup_temporary_paths || true
        [[ "$SERVICES_STOPPED" == false ]] && release_maintenance_lock
        return 1
    fi
    if ! create_unique_rollback_path; then
        local rollback_service_ok=true
        restore_services || rollback_service_ok=false
        cleanup_temporary_paths || true
        if [[ "$rollback_service_ok" == true ]]; then
            release_maintenance_lock
        else
            warn "创建回滚路径失败后未能完整恢复服务"
        fi
        return 1
    fi
    RESTORE_ROLLBACK_PATH="$UNIQUE_ROLLBACK_PATH"
    UNIQUE_ROLLBACK_PATH=""
    RESTORE_TRANSACTION_ACTIVE=true
    RESTORE_ORIGINAL_PRESENT=false
    RESTORE_TARGET_CREATED=false

    if [[ -e "$VNSTAT_DATA_PATH" || -L "$VNSTAT_DATA_PATH" ]]; then
        [[ -d "$VNSTAT_DATA_PATH" && ! -L "$VNSTAT_DATA_PATH" ]] || \
            { fail_restore_and_rollback "现有 vnstat 数据路径不可信"; return 1; }
        RESTORE_ORIGINAL_PRESENT=true
        if ! mv -- "$VNSTAT_DATA_PATH" "$RESTORE_ROLLBACK_PATH"; then
            fail_restore_and_rollback "归档当前 vnstat 数据失败"
            return 1
        fi
        if ! sync_path_durably "$RESTORE_ROLLBACK_PATH" || \
           ! sync_parent_directory_durably "$RESTORE_ROLLBACK_PATH"; then
            fail_restore_and_rollback "恢复前数据库归档未能可靠持久化"
            return 1
        fi
    fi

    RESTORE_TARGET_CREATED=true
    if [[ -e "$VNSTAT_DATA_PATH" || -L "$VNSTAT_DATA_PATH" ]] || \
       ! mv -- "$RESTORE_STAGED_PATH" "$VNSTAT_DATA_PATH"; then
        fail_restore_and_rollback "原子切换恢复数据库失败"
        return 1
    fi
    RESTORE_STAGED_PATH=""
    if ! validate_vnstat_database "$VNSTAT_DATA_PATH" || \
       ! sync_path_durably "$VNSTAT_DATA_PATH" || \
       ! sync_parent_directory_durably "$VNSTAT_DATA_PATH"; then
        fail_restore_and_rollback "恢复后 vnstat 数据库验证或持久化失败"
        return 1
    fi
    if ! restore_services; then
        fail_restore_and_rollback "数据恢复后服务启动验证失败"
        return 1
    fi

    local completed_rollback_path="$RESTORE_ROLLBACK_PATH"
    RESTORE_TRANSACTION_ACTIVE=false
    RESTORE_ORIGINAL_PRESENT=false
    RESTORE_TARGET_CREATED=false
    RESTORE_ROLLBACK_PATH=""
    cleanup_temporary_paths || { release_maintenance_lock; return 1; }
    release_maintenance_lock

    record_log "backup_restored archive=$selected rollback=$completed_rollback_path"
    log "恢复完成；恢复前数据保留在: $completed_rollback_path"
}

show_menu() {
    echo -e "${GREEN}================================${NC}"
    echo -e "${GREEN}      vnstat 数据管理工具${NC}"
    echo -e "${GREEN}================================${NC}"
    echo "1) 创建一致性备份"
    echo "2) 校验并恢复备份"
    echo "3) 列出备份"
    echo "4) 退出"
}

main() {
    require_root
    validate_paths
    while true; do
        show_menu
        local choice
        read -r -p "请选择操作 [1-4]: " choice
        case "$choice" in
            1) backup_data ;;
            2) restore_data ;;
            3) list_backups ;;
            4) exit 0 ;;
            *) warn "无效选择" ;;
        esac
        echo
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
