#!/usr/bin/env bash

set -Eeuo pipefail

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        printf 'BACKUP_VNSTAT_SAFETY_TESTS=SKIP(non-Linux permission semantics)\n'
        exit 0
        ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/flowmaster-backup-test.XXXXXX)"
readonly ROOT_DIR TEST_ROOT
readonly DATA_DIR="$TEST_ROOT/vnstat"
readonly BACKUP_DIR="$TEST_ROOT/backups"
readonly LOG_FILE="$TEST_ROOT/logs/backup.log"
readonly LOCK_FILE="$TEST_ROOT/flowmaster-maintenance.lock"
readonly TEST_BIN="$TEST_ROOT/bin"
readonly FAIL_START_MARKER="$TEST_ROOT/fail-start.once"
readonly FAIL_STABILITY_MARKER="$TEST_ROOT/fail-stability.once"
readonly FAIL_DB_MARKER="$TEST_ROOT/fail-db.once"
readonly FAIL_COPY_MARKER="$TEST_ROOT/fail-copy.once"
readonly FAIL_SYNC_MARKER="$TEST_ROOT/fail-sync.once"
readonly SYNC_CALL_LOG="$TEST_ROOT/sync.calls"

cleanup_test() {
    case "$TEST_ROOT" in
        /tmp/flowmaster-backup-test.*) rm -rf -- "$TEST_ROOT" ;;
        *) echo "拒绝清理非预期测试目录: $TEST_ROOT" >&2 ;;
    esac
}
trap cleanup_test EXIT

mkdir -p "$DATA_DIR" "$BACKUP_DIR" "$TEST_BIN"
printf 'VALID:original\n' >"$DATA_DIR/vnstat.db"

HAS_REAL_FLOCK=false
if command -v flock >/dev/null 2>&1; then
    HAS_REAL_FLOCK=true
else
    cat >"$TEST_BIN/flock" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$TEST_BIN/flock"
    export PATH="$TEST_BIN:$PATH"
fi

export FLOWMASTER_BACKUP_DIR="$BACKUP_DIR"
export VNSTAT_DATA_DIR="$DATA_DIR"
export FLOWMASTER_BACKUP_LOG="$LOG_FILE"
export FLOWMASTER_MAINTENANCE_LOCK_FILE="$LOCK_FILE"
export FLOWMASTER_ALLOW_CUSTOM_VNSTAT_DATA_DIR=1
export FLOWMASTER_SERVICE_VERIFY_ATTEMPTS=1
export FLOWMASTER_SERVICE_VERIFY_INTERVAL_SECONDS=0
export FLOWMASTER_SERVICE_STABILITY_OBSERVATIONS=2
export FLOWMASTER_SERVICE_STABILITY_INTERVAL_SECONDS=0

# shellcheck disable=SC1091
source "$ROOT_DIR/backup_vnstat.sh"
# backup_vnstat.sh 的退出 trap 负责恢复事务；测试清理在其后执行。
_test_status=0
trap '_test_status=$?; trap - EXIT; handle_exit "$_test_status"; _test_status=$?; cleanup_test; exit "$_test_status"' EXIT

flowmaster_active=true
vnstat_active=true

emit_runtime_properties() {
    local service_name="$1"
    local is_active state sub_state main_pid result
    case "$service_name" in
        flowmaster.service) is_active="$flowmaster_active" ;;
        vnstat) is_active="$vnstat_active" ;;
        *) return 1 ;;
    esac
    if [[ "$is_active" == true ]]; then
        state=active
        sub_state=running
        main_pid=12345
        result=success
    else
        state=inactive
        sub_state=dead
        main_pid=0
        result=success
    fi
    if [[ -f "$FAIL_STABILITY_MARKER" ]] && [[ "$(<"$FAIL_STABILITY_MARKER")" == "$service_name" ]]; then
        if [[ ! -e "${FAIL_STABILITY_MARKER}.seen" ]]; then
            : >"${FAIL_STABILITY_MARKER}.seen"
        else
            state=failed
            sub_state=failed
            main_pid=0
            result=exit-code
            rm -f -- "$FAIL_STABILITY_MARKER" "${FAIL_STABILITY_MARKER}.seen"
        fi
    fi
    printf 'Type=simple\nMainPID=%s\nResult=%s\nActiveState=%s\nSubState=%s\n' \
        "$main_pid" "$result" "$state" "$sub_state"
}

emit_inactive_properties() {
    local service_name="$1"
    local is_active state main_pid
    case "$service_name" in
        flowmaster.service) is_active="$flowmaster_active" ;;
        vnstat) is_active="$vnstat_active" ;;
        *) return 1 ;;
    esac
    if [[ "$is_active" == true ]]; then
        state=active
        main_pid=12345
    else
        state=inactive
        main_pid=0
    fi
    printf 'ActiveState=%s\nMainPID=%s\nControlPID=0\nControlGroup=\n' "$state" "$main_pid"
}

# service 生命周期测试使用模拟 PID；cgroup 解析本身在后文用临时目录单独验证。
unit_cgroup_is_empty() { return 0; }

systemctl() {
    local action="${1:-}"
    local service_name="${2:-}"
    if [[ "$action" == "--no-block" ]]; then
        action="${2:-}"
        service_name="${3:-}"
    elif [[ "$action" == "is-active" ]]; then
        service_name="${3:-}"
    fi
    case "$action" in
        show)
            if [[ "${3:-}" == "--property=ActiveState" && "${4:-}" == "--value" && $# -eq 4 ]]; then
                case "$service_name" in
                    flowmaster.service)
                        if [[ "$flowmaster_active" == true ]]; then printf 'active\n'; else printf 'inactive\n'; fi
                        ;;
                    vnstat)
                        if [[ "$vnstat_active" == true ]]; then printf 'active\n'; else printf 'inactive\n'; fi
                        ;;
                    *) return 1 ;;
                esac
            elif [[ "${3:-}" == "--property=ActiveState" && \
                    "${4:-}" == "--property=SubState" && \
                    "${5:-}" == "--property=Type" && \
                    "${6:-}" == "--property=MainPID" && \
                    "${7:-}" == "--property=Result" && $# -eq 7 ]]; then
                emit_runtime_properties "$service_name"
            elif [[ "${3:-}" == "--property=ActiveState" && \
                    "${4:-}" == "--property=MainPID" && \
                    "${5:-}" == "--property=ControlPID" && \
                    "${6:-}" == "--property=ControlGroup" && $# -eq 6 ]]; then
                emit_inactive_properties "$service_name"
            else
                return 1
            fi
            ;;
        is-active)
            [[ "${2:-}" == "--quiet" ]] || return 1
            case "$service_name" in
                flowmaster.service) [[ "$flowmaster_active" == true ]] ;;
                vnstat) [[ "$vnstat_active" == true ]] ;;
                *) return 1 ;;
            esac
            ;;
        stop)
            case "$service_name" in
                flowmaster.service) flowmaster_active=false ;;
                vnstat) vnstat_active=false ;;
                *) return 1 ;;
            esac
            ;;
        start)
            if [[ -f "$FAIL_START_MARKER" ]] &&
               [[ "$(<"$FAIL_START_MARKER")" == "$service_name" ]]; then
                rm -f -- "$FAIL_START_MARKER"
                return 1
            fi
            case "$service_name" in
                flowmaster.service) flowmaster_active=true ;;
                vnstat) vnstat_active=true ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

run_systemctl_bounded() {
    systemctl "$@"
}

# 生产包装器必须硬限制 systemctl/DBus 卡死的等待时间。
cat >"$TEST_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
exec sleep 10
EOF
chmod +x "$TEST_BIN/systemctl"
timeout_started_at=$SECONDS
if PATH="$TEST_BIN:$PATH" FLOWMASTER_SYSTEMCTL_TIMEOUT_SECONDS=1 \
   bash -c 'source "$1"; run_systemctl_bounded show vnstat --property=ActiveState --value' \
   _ "$ROOT_DIR/backup_vnstat.sh" >/dev/null 2>&1; then
    echo "超时的 systemctl 查询不应被视为成功" >&2
    exit 1
fi
(( SECONDS - timeout_started_at < 5 ))
rm -f -- "$TEST_BIN/systemctl"

vnstat() {
    if [[ "${1:-}" == "--version" ]]; then
        printf 'vnStat 2.test\n'
        return 0
    fi
    [[ "${1:-}" == "--dbdir" && -n "${2:-}" ]] || {
        echo "测试检测到未指定 --dbdir 的 vnstat 调用: $*" >&2
        return 1
    }
    local database_dir="$2"
    local operation="${3:-}"
    printf '%s\n' "$*" >>"$TEST_ROOT/vnstat.calls"
    if [[ "$database_dir" == "$VNSTAT_DATA_PATH" && -f "$FAIL_DB_MARKER" ]]; then
        rm -f -- "$FAIL_DB_MARKER"
        return 1
    fi
    [[ -f "$database_dir/vnstat.db" ]] || return 1
    grep -q '^VALID:' "$database_dir/vnstat.db" || return 1
    case "$operation" in
        --dbiflist)
            [[ "${4:-}" == "2" ]] || return 1
            printf '1\n'
            ;;
        --json)
            printf '{"interfaces":[{"name":"eth0"}]}\n'
            ;;
        *) return 1 ;;
    esac
}

cp() {
    local argument
    if [[ -f "$FAIL_COPY_MARKER" ]]; then
        for argument in "$@"; do
            if [[ "$argument" == "$RESTORE_EXTRACT_DIR/data" ]]; then
                rm -f -- "$FAIL_COPY_MARKER"
                return 1
            fi
        done
    fi
    command cp "$@"
}

sync() {
    local specification="" argument matched=false
    printf '%s\n' "$*" >>"$SYNC_CALL_LOG"
    if [[ -f "$FAIL_SYNC_MARKER" ]]; then
        specification="$(<"$FAIL_SYNC_MARKER")"
        for argument in "$@"; do
            case "$specification" in
                exact:*) [[ "$argument" == "${specification#exact:}" ]] && matched=true ;;
                contains:*) [[ "$argument" == *"${specification#contains:}"* ]] && matched=true ;;
            esac
        done
        if [[ "$matched" == true ]]; then
            rm -f -- "$FAIL_SYNC_MARKER"
            return 1
        fi
    fi
    command sync "$@"
}

validate_paths
[[ "$VNSTAT_DATA_PATH" == "$DATA_DIR" && "$BACKUP_PATH" == "$BACKUP_DIR" ]]

# ControlGroup 必须是受限绝对路径，并递归确认主 cgroup 与委派子 cgroup 都没有 PID。
cgroup_test_root="$TEST_ROOT/cgroup-root"
cgroup_test_unit="$cgroup_test_root/system.slice/flowmaster.service"
mkdir -p "$cgroup_test_unit/worker"
: >"$cgroup_test_unit/cgroup.procs"
: >"$cgroup_test_unit/worker/cgroup.procs"
cgroup_tree_has_no_processes "$cgroup_test_root" /system.slice/flowmaster.service
printf '4242' >"$cgroup_test_unit/worker/cgroup.procs"
if cgroup_tree_has_no_processes "$cgroup_test_root" /system.slice/flowmaster.service; then
    echo "子 cgroup 残留进程不应被视为空 cgroup" >&2
    exit 1
fi
: >"$cgroup_test_unit/worker/cgroup.procs"
ln -s /proc/self "$cgroup_test_unit/unsafe-link"
if cgroup_tree_has_no_processes "$cgroup_test_root" /system.slice/flowmaster.service; then
    echo "包含符号链接的伪造 cgroup 树不应通过校验" >&2
    exit 1
fi
rm -f -- "$cgroup_test_unit/unsafe-link"
for invalid_control_group in / ../escape /system.slice/../escape '//system.slice/flowmaster.service'; do
    if validate_control_group_path "$invalid_control_group"; then
        echo "不可信 ControlGroup 不应通过校验: $invalid_control_group" >&2
        exit 1
    fi
done

# 锁文件必须以非截断方式打开，并在持锁前后绑定同一 inode。
printf 'lock-sentinel\n' >"$MAINTENANCE_LOCK_PATH"
acquire_maintenance_lock
grep -qx 'lock-sentinel' "$MAINTENANCE_LOCK_PATH"
release_maintenance_lock

# 创建真实 tar/manifest/sidecar，再验证权限、拓扑和数据库命令参数。
backup_data >/dev/null
mapfile -t archives < <(list_archive_paths)
(( ${#archives[@]} == 1 ))
archive="${archives[0]}"
[[ "$(stat -c '%a' "$BACKUP_PATH")" == "700" ]]
[[ "$(stat -c '%a' "$archive")" == "600" ]]
[[ "$(stat -c '%a' "${archive}.sha256")" == "600" ]]
validate_archive_members "$archive"
validate_archive_sidecar "$archive"
grep -Fxq -- "-f -- $archive" "$SYNC_CALL_LOG"
grep -Fxq -- "-f -- ${archive}.sha256" "$SYNC_CALL_LOG"
grep -Fxq -- "-f -- $BACKUP_PATH" "$SYNC_CALL_LOG"
grep -q -- '--dbdir .* --json' "$TEST_ROOT/vnstat.calls"
if grep -q -- '--iflist' "$TEST_ROOT/vnstat.calls"; then
    echo "vnstat 数据库校验不得使用进程全局 --iflist" >&2
    exit 1
fi
[[ "$flowmaster_active" == true && "$vnstat_active" == true ]]

# 快照数据库验证失败时，不得提交半成品，并须恢复原服务与释放维护锁。
archive_count_before_failure="${#archives[@]}"
printf 'INVALID:corrupt-source\n' >"$VNSTAT_DATA_PATH/vnstat.db"
if backup_data >/dev/null 2>&1; then
    echo "无效 vnstat 数据库不应被备份" >&2
    exit 1
fi
mapfile -t archives_after_failure < <(list_archive_paths)
(( ${#archives_after_failure[@]} == archive_count_before_failure ))
[[ "$flowmaster_active" == true && "$vnstat_active" == true ]]
[[ -z "$MAINTENANCE_LOCK_FD" ]]
[[ -z "$(find "$BACKUP_PATH" -maxdepth 1 \( -name '.snapshot.*' -o -name '*.tmp' \) -print -quit)" ]]

# 临时归档未能持久化时，不能发布 archive/sidecar，也必须恢复服务并释放锁。
printf 'VALID:archive-sync-failure\n' >"$VNSTAT_DATA_PATH/vnstat.db"
printf 'contains:.tar.gz.tmp\n' >"$FAIL_SYNC_MARKER"
if backup_data >/dev/null 2>&1; then
    echo "归档 fsync 失败不应被视为备份成功" >&2
    exit 1
fi
mapfile -t archives_after_sync_failure < <(list_archive_paths)
(( ${#archives_after_sync_failure[@]} == archive_count_before_failure ))
[[ ! -e "$FAIL_SYNC_MARKER" ]]
[[ "$flowmaster_active" == true && "$vnstat_active" == true ]]
[[ -z "$MAINTENANCE_LOCK_FD" ]]
[[ -z "$(find "${VNSTAT_DATA_PATH%/*}" -maxdepth 1 -type d -name "${VNSTAT_DATA_PATH##*/}.restore.*" -print -quit)" ]]
[[ -z "$(find "$BACKUP_PATH" -maxdepth 1 \( -name '.snapshot.*' -o -name '*.tmp' \) -print -quit)" ]]

# 新库完成原子 rename 后若持久化失败，恢复事务必须换回并同步旧库。
printf 'VALID:current-before-restore-sync-failure\n' >"$VNSTAT_DATA_PATH/vnstat.db"
sync_calls_before_failure="$(grep -Fxc -- "-f -- $VNSTAT_DATA_PATH" "$SYNC_CALL_LOG" || true)"
printf 'exact:%s\n' "$VNSTAT_DATA_PATH" >"$FAIL_SYNC_MARKER"
if restore_data <<< $'1\ny\n' >/dev/null 2>&1; then
    echo "恢复目录 fsync 失败不应被视为恢复成功" >&2
    exit 1
fi
grep -qx 'VALID:current-before-restore-sync-failure' "$VNSTAT_DATA_PATH/vnstat.db"
sync_calls_after_failure="$(grep -Fxc -- "-f -- $VNSTAT_DATA_PATH" "$SYNC_CALL_LOG" || true)"
(( sync_calls_after_failure >= sync_calls_before_failure + 2 ))
[[ ! -e "$FAIL_SYNC_MARKER" ]]
[[ "$flowmaster_active" == true && "$vnstat_active" == true ]]
[[ -z "$MAINTENANCE_LOCK_FD" ]]
[[ -z "$(find "${VNSTAT_DATA_PATH%/*}" -maxdepth 1 -type d -name "${VNSTAT_DATA_PATH##*/}.restore.*" -print -quit)" ]]

# 成功恢复必须保留恢复前快照，并将归档数据恢复到活动路径。
printf 'VALID:current-before-success\n' >"$VNSTAT_DATA_PATH/vnstat.db"
restore_data <<< $'1\ny\n' >/dev/null
grep -qx 'VALID:original' "$VNSTAT_DATA_PATH/vnstat.db"
rollback_success="$(find "${VNSTAT_DATA_PATH%/*}" -maxdepth 1 -type d -name "${VNSTAT_DATA_PATH##*/}.rollback.*" -print -quit)"
[[ -n "$rollback_success" ]]
grep -qx 'VALID:current-before-success' "$rollback_success/vnstat.db"
[[ "$flowmaster_active" == true && "$vnstat_active" == true ]]
[[ -z "$(find "$BACKUP_PATH" -maxdepth 1 \( -name '.restore.*' -o -name '.snapshot.*' -o -name '*.tmp' \) -print -quit)" ]]
[[ -z "$(find "${VNSTAT_DATA_PATH%/*}" -maxdepth 1 -type d -name "${VNSTAT_DATA_PATH##*/}.restore.*" -print -quit)" ]]

# 目标数据库二次验证失败时，必须恢复旧数据库及原服务状态。
printf 'VALID:current-before-validation-failure\n' >"$VNSTAT_DATA_PATH/vnstat.db"
: >"$FAIL_DB_MARKER"
if restore_data <<< $'1\ny\n' >/dev/null 2>&1; then
    echo "目标数据库验证失败不应被视为恢复成功" >&2
    exit 1
fi
grep -qx 'VALID:current-before-validation-failure' "$VNSTAT_DATA_PATH/vnstat.db"
[[ "$flowmaster_active" == true && "$vnstat_active" == true ]]

# 复制故障同样必须恢复旧数据库，且不能遗留部分目标。
printf 'VALID:current-before-copy-failure\n' >"$VNSTAT_DATA_PATH/vnstat.db"
: >"$FAIL_COPY_MARKER"
if restore_data <<< $'1\ny\n' >/dev/null 2>&1; then
    echo "复制故障不应被视为恢复成功" >&2
    exit 1
fi
grep -qx 'VALID:current-before-copy-failure' "$VNSTAT_DATA_PATH/vnstat.db"
[[ "$flowmaster_active" == true && "$vnstat_active" == true ]]

# 新数据库启动后 FlowMaster 首次启动失败：回滚旧库，再次恢复原服务。
printf 'VALID:current-before-service-failure\n' >"$VNSTAT_DATA_PATH/vnstat.db"
printf '%s\n' 'flowmaster.service' >"$FAIL_START_MARKER"
if restore_data <<< $'1\ny\n' >/dev/null 2>&1; then
    echo "服务恢复故障不应被视为恢复成功" >&2
    exit 1
fi
grep -qx 'VALID:current-before-service-failure' "$VNSTAT_DATA_PATH/vnstat.db"
[[ "$flowmaster_active" == true && "$vnstat_active" == true ]]

# 新数据库启动时服务仅短暂 active 后失败，也必须换回旧库并恢复原服务。
printf 'VALID:current-before-transient-service-failure\n' >"$VNSTAT_DATA_PATH/vnstat.db"
printf '%s\n' 'flowmaster.service' >"$FAIL_STABILITY_MARKER"
if restore_data <<< $'1\ny\n' >/dev/null 2>&1; then
    echo "服务短暂 active 后失败不应被视为恢复成功" >&2
    exit 1
fi
grep -qx 'VALID:current-before-transient-service-failure' "$VNSTAT_DATA_PATH/vnstat.db"
[[ "$flowmaster_active" == true && "$vnstat_active" == true ]]
[[ ! -e "$FAIL_STABILITY_MARKER" && ! -e "${FAIL_STABILITY_MARKER}.seen" ]]

# manifest 必须覆盖全部数据文件，不能容忍未登记的额外文件。
malicious_root="$TEST_ROOT/malicious-extra"
mkdir -p "$malicious_root"
tar -xzf "$archive" -C "$malicious_root"
printf 'unchecked\n' >"$malicious_root/data/extra.db"
if validate_extracted_archive "$malicious_root" >/dev/null 2>&1; then
    echo "未登记的额外文件不应通过 manifest 校验" >&2
    exit 1
fi

# tar 中的符号链接必须在解包前被成员类型检查拒绝。
rm -rf -- "$malicious_root"
mkdir -p "$malicious_root"
tar -xzf "$archive" -C "$malicious_root"
ln -s /etc/passwd "$malicious_root/data/unsafe-link"
malicious_link_archive="$BACKUP_PATH/vnstat-malicious-link.tar.gz"
(cd "$malicious_root" && tar -czf "$malicious_link_archive" data metadata.txt vnstat.json checksums.sha256)
if validate_archive_members "$malicious_link_archive" >/dev/null 2>&1; then
    echo "包含符号链接的归档不应通过拓扑校验" >&2
    exit 1
fi

# 重复成员与父目录穿越成员也必须在解包前被拒绝。
rm -f -- "$malicious_root/data/unsafe-link"
malicious_duplicate_archive="$BACKUP_PATH/vnstat-malicious-duplicate.tar.gz"
(cd "$malicious_root" && tar -czf "$malicious_duplicate_archive" data metadata.txt vnstat.json checksums.sha256 data)
if validate_archive_members "$malicious_duplicate_archive" >/dev/null 2>&1; then
    echo "包含重复成员的归档不应通过拓扑校验" >&2
    exit 1
fi
printf 'escape\n' >"$malicious_root/payload"
malicious_traversal_archive="$BACKUP_PATH/vnstat-malicious-traversal.tar.gz"
(cd "$malicious_root" && tar -czf "$malicious_traversal_archive" \
    --transform='s|^payload$|../escape|' payload) >/dev/null 2>&1
if validate_archive_members "$malicious_traversal_archive" >/dev/null 2>&1; then
    echo "包含父目录穿越成员的归档不应通过拓扑校验" >&2
    exit 1
fi

# 小体积压缩包也可能声明超大稀疏文件，必须在解包前按展开大小拒绝。
resource_root="$TEST_ROOT/malicious-resource"
mkdir -p "$resource_root/data"
truncate -s $((ARCHIVE_MAX_EXPANDED_BYTES + 1)) "$resource_root/data/huge.db"
printf 'metadata\n' >"$resource_root/metadata.txt"
printf '{}\n' >"$resource_root/vnstat.json"
printf 'placeholder\n' >"$resource_root/checksums.sha256"
malicious_resource_archive="$BACKUP_PATH/vnstat-malicious-resource.tar.gz"
(cd "$resource_root" && tar --sparse -czf "$malicious_resource_archive" data metadata.txt vnstat.json checksums.sha256)
if validate_archive_members "$malicious_resource_archive" >/dev/null 2>&1; then
    echo "展开体积超过上限的归档不应通过资源校验" >&2
    exit 1
fi

# sidecar 必须恰好绑定所选文件名，不能借用其他归档的摘要。
sidecar_backup="$(<"${archive}.sha256")"
printf '%s  %s\n' "$(sha256sum "$archive" | awk '{print $1}')" 'another.tar.gz' >"${archive}.sha256"
if validate_archive_sidecar "$archive"; then
    echo "指向其他文件名的 sidecar 不应通过" >&2
    exit 1
fi
printf '%s\n' "$sidecar_backup" >"${archive}.sha256"
validate_archive_sidecar "$archive"
mv -- "${archive}.sha256" "${archive}.sha256.missing"
if validate_archive_sidecar "$archive" >/dev/null 2>&1; then
    echo "缺少 sidecar 的归档不应通过完整性校验" >&2
    exit 1
fi
mv -- "${archive}.sha256.missing" "${archive}.sha256"

# 危险路径、未授权自定义路径、符号链接与数据/备份嵌套必须被拒绝。
if FLOWMASTER_BACKUP_DIR="$TEST_ROOT/path-backups" \
   VNSTAT_DATA_DIR=/etc/systemd \
   FLOWMASTER_BACKUP_LOG="$TEST_ROOT/path.log" \
   FLOWMASTER_MAINTENANCE_LOCK_FILE="$TEST_ROOT/path.lock" \
   FLOWMASTER_ALLOW_CUSTOM_VNSTAT_DATA_DIR=1 \
   bash -c 'source "$1"; validate_paths' _ "$ROOT_DIR/backup_vnstat.sh" >/dev/null 2>&1; then
    echo "危险系统目录不应通过路径验证" >&2
    exit 1
fi
if FLOWMASTER_BACKUP_DIR=/etc/systemd \
   VNSTAT_DATA_DIR="$TEST_ROOT/real-vnstat" \
   FLOWMASTER_BACKUP_LOG="$TEST_ROOT/path.log" \
   FLOWMASTER_MAINTENANCE_LOCK_FILE="$TEST_ROOT/path.lock" \
   FLOWMASTER_ALLOW_CUSTOM_VNSTAT_DATA_DIR=1 \
   bash -c 'source "$1"; validate_paths' _ "$ROOT_DIR/backup_vnstat.sh" >/dev/null 2>&1; then
    echo "系统配置子目录不应被接受为备份目录" >&2
    exit 1
fi
if FLOWMASTER_BACKUP_DIR="$TEST_ROOT/path-backups" \
   VNSTAT_DATA_DIR="$TEST_ROOT/unapproved-vnstat" \
   FLOWMASTER_BACKUP_LOG="$TEST_ROOT/path.log" \
   FLOWMASTER_MAINTENANCE_LOCK_FILE="$TEST_ROOT/path.lock" \
   FLOWMASTER_ALLOW_CUSTOM_VNSTAT_DATA_DIR=0 \
   bash -c 'source "$1"; validate_paths' _ "$ROOT_DIR/backup_vnstat.sh" >/dev/null 2>&1; then
    echo "未显式授权的自定义数据目录不应通过" >&2
    exit 1
fi
mkdir -p "$TEST_ROOT/real-vnstat"
ln -s "$TEST_ROOT/real-vnstat" "$TEST_ROOT/linked-vnstat"
if FLOWMASTER_BACKUP_DIR="$TEST_ROOT/path-backups" \
   VNSTAT_DATA_DIR="$TEST_ROOT/linked-vnstat" \
   FLOWMASTER_BACKUP_LOG="$TEST_ROOT/path.log" \
   FLOWMASTER_MAINTENANCE_LOCK_FILE="$TEST_ROOT/path.lock" \
   FLOWMASTER_ALLOW_CUSTOM_VNSTAT_DATA_DIR=1 \
   bash -c 'source "$1"; validate_paths' _ "$ROOT_DIR/backup_vnstat.sh" >/dev/null 2>&1; then
    echo "符号链接数据目录不应通过" >&2
    exit 1
fi
mkdir -p "$TEST_ROOT/nested-vnstat/backups"
if FLOWMASTER_BACKUP_DIR="$TEST_ROOT/nested-vnstat/backups" \
   VNSTAT_DATA_DIR="$TEST_ROOT/nested-vnstat" \
   FLOWMASTER_BACKUP_LOG="$TEST_ROOT/path.log" \
   FLOWMASTER_MAINTENANCE_LOCK_FILE="$TEST_ROOT/path.lock" \
   FLOWMASTER_ALLOW_CUSTOM_VNSTAT_DATA_DIR=1 \
   bash -c 'source "$1"; validate_paths' _ "$ROOT_DIR/backup_vnstat.sh" >/dev/null 2>&1; then
    echo "位于数据目录内的备份目录不应通过" >&2
    exit 1
fi
if FLOWMASTER_BACKUP_DIR="$TEST_ROOT/path-backups" \
   VNSTAT_DATA_DIR="$TEST_ROOT/nested-vnstat" \
   FLOWMASTER_BACKUP_LOG="$TEST_ROOT/path.log" \
   FLOWMASTER_MAINTENANCE_LOCK_FILE="$TEST_ROOT/nested-vnstat/maintenance.lock" \
   FLOWMASTER_ALLOW_CUSTOM_VNSTAT_DATA_DIR=1 \
   bash -c 'source "$1"; validate_paths' _ "$ROOT_DIR/backup_vnstat.sh" >/dev/null 2>&1; then
    echo "位于数据目录内的维护锁不应通过路径验证" >&2
    exit 1
fi

# 硬链接锁不能作为互斥原语；root 运行时还必须拒绝非 root 可替换的祖先目录。
printf 'lock\n' >"$TEST_ROOT/hardlink-source"
ln "$TEST_ROOT/hardlink-source" "$TEST_ROOT/hardlink.lock"
if FLOWMASTER_BACKUP_DIR="$TEST_ROOT/path-backups" \
   VNSTAT_DATA_DIR="$TEST_ROOT/real-vnstat" \
   FLOWMASTER_BACKUP_LOG="$TEST_ROOT/path.log" \
   FLOWMASTER_MAINTENANCE_LOCK_FILE="$TEST_ROOT/hardlink.lock" \
   FLOWMASTER_ALLOW_CUSTOM_VNSTAT_DATA_DIR=1 \
   bash -c 'source "$1"; validate_paths' _ "$ROOT_DIR/backup_vnstat.sh" >/dev/null 2>&1; then
    echo "硬链接维护锁不应通过路径验证" >&2
    exit 1
fi
if (( ${EUID:-$(id -u)} == 0 )); then
    untrusted_parent="$TEST_ROOT/untrusted-parent"
    mkdir -p "$untrusted_parent"
    chown 65534:65534 "$untrusted_parent"
    chmod 0700 "$untrusted_parent"
    if FLOWMASTER_BACKUP_DIR="$TEST_ROOT/path-backups" \
       VNSTAT_DATA_DIR="$untrusted_parent/vnstat" \
       FLOWMASTER_BACKUP_LOG="$TEST_ROOT/path.log" \
       FLOWMASTER_MAINTENANCE_LOCK_FILE="$TEST_ROOT/path.lock" \
       FLOWMASTER_ALLOW_CUSTOM_VNSTAT_DATA_DIR=1 \
       bash -c 'source "$1"; validate_paths' _ "$ROOT_DIR/backup_vnstat.sh" >/dev/null 2>&1; then
        echo "非 root 所有的可替换祖先目录不应通过路径验证" >&2
        exit 1
    fi
fi

# TERM 必须经过 EXIT 事务回滚，不能把原库遗留在 rollback 路径。
signal_data="$TEST_ROOT/signal-vnstat"
mkdir -p "$signal_data"
printf 'VALID:signal-original\n' >"$signal_data/vnstat.db"
set +e
FLOWMASTER_BACKUP_DIR="$TEST_ROOT/signal-backups" \
VNSTAT_DATA_DIR="$signal_data" \
FLOWMASTER_BACKUP_LOG="$TEST_ROOT/signal.log" \
FLOWMASTER_MAINTENANCE_LOCK_FILE="$TEST_ROOT/signal.lock" \
FLOWMASTER_ALLOW_CUSTOM_VNSTAT_DATA_DIR=1 \
FLOWMASTER_SERVICE_VERIFY_ATTEMPTS=1 \
FLOWMASTER_SERVICE_VERIFY_INTERVAL_SECONDS=0 \
bash -c '
    source "$1"
    systemctl() {
        if [[ "${1:-}" == "show" ]]; then
            if [[ "${3:-}" == "--property=ActiveState" && "${4:-}" == "--value" ]]; then
                printf "inactive\n"
            else
                printf "ActiveState=inactive\nMainPID=0\nControlPID=0\nControlGroup=\n"
            fi
            return 0
        fi
        return 1
    }
    run_systemctl_bounded() { systemctl "$@"; }
    validate_paths
    stop_services
    create_unique_rollback_path
    RESTORE_ROLLBACK_PATH="$UNIQUE_ROLLBACK_PATH"
    RESTORE_TRANSACTION_ACTIVE=true
    RESTORE_ORIGINAL_PRESENT=true
    mv -- "$VNSTAT_DATA_PATH" "$RESTORE_ROLLBACK_PATH"
    # 模拟原子 mv 已完成、Shell 尚未来得及继续更新事务状态的窗口。
    kill -TERM "$$"
' _ "$ROOT_DIR/backup_vnstat.sh" >/dev/null 2>&1
signal_status=$?
set -e
(( signal_status == 130 ))
grep -qx 'VALID:signal-original' "$signal_data/vnstat.db"
[[ -z "$(find "$TEST_ROOT" -maxdepth 1 -type d -name 'signal-vnstat.rollback.*' -print -quit)" ]]

# 失败回滚把旧库移回后立即再次收到 TERM，也必须幂等完成，不能误删刚恢复的旧库。
rollback_signal_data="$TEST_ROOT/rollback-signal-vnstat"
rollback_signal_dir="${rollback_signal_data}.rollback.injected"
mkdir -p "$rollback_signal_data" "$rollback_signal_dir"
printf 'VALID:new-target\n' >"$rollback_signal_data/vnstat.db"
printf 'VALID:rollback-original\n' >"$rollback_signal_dir/vnstat.db"
set +e
FLOWMASTER_BACKUP_DIR="$TEST_ROOT/rollback-signal-backups" \
VNSTAT_DATA_DIR="$rollback_signal_data" \
FLOWMASTER_BACKUP_LOG="$TEST_ROOT/rollback-signal.log" \
FLOWMASTER_MAINTENANCE_LOCK_FILE="$TEST_ROOT/rollback-signal.lock" \
FLOWMASTER_ALLOW_CUSTOM_VNSTAT_DATA_DIR=1 \
FLOWMASTER_SERVICE_VERIFY_ATTEMPTS=1 \
FLOWMASTER_SERVICE_VERIFY_INTERVAL_SECONDS=0 \
bash -c '
    source "$1"
    systemctl() {
        if [[ "${1:-}" == "show" ]]; then
            if [[ "${3:-}" == "--property=ActiveState" && "${4:-}" == "--value" ]]; then
                printf "inactive\n"
            else
                printf "ActiveState=inactive\nMainPID=0\nControlPID=0\nControlGroup=\n"
            fi
            return 0
        fi
        return 1
    }
    run_systemctl_bounded() { systemctl "$@"; }
    mv() {
        command mv "$@" || return 1
        if [[ "${1:-}" == "--" && "${2:-}" == "$RESTORE_ROLLBACK_PATH" && "${3:-}" == "$VNSTAT_DATA_PATH" ]]; then
            kill -TERM "$$"
        fi
    }
    validate_paths
    SERVICES_STOPPED=true
    RESTORE_TRANSACTION_ACTIVE=true
    RESTORE_ORIGINAL_PRESENT=true
    RESTORE_TARGET_CREATED=true
    RESTORE_ROLLBACK_PATH="${VNSTAT_DATA_PATH}.rollback.injected"
    rollback_restore_transaction
' _ "$ROOT_DIR/backup_vnstat.sh" >/dev/null 2>&1
rollback_signal_status=$?
set -e
(( rollback_signal_status == 130 ))
grep -qx 'VALID:rollback-original' "$rollback_signal_data/vnstat.db"
[[ ! -e "$rollback_signal_dir" ]]

# mktemp 已预留回滚名但事务尚未开始时收到信号，也不能遗留空目录。
reservation_signal_data="$TEST_ROOT/reservation-signal-vnstat"
mkdir -p "$reservation_signal_data"
set +e
FLOWMASTER_BACKUP_DIR="$TEST_ROOT/reservation-signal-backups" \
VNSTAT_DATA_DIR="$reservation_signal_data" \
FLOWMASTER_BACKUP_LOG="$TEST_ROOT/reservation-signal.log" \
FLOWMASTER_MAINTENANCE_LOCK_FILE="$TEST_ROOT/reservation-signal.lock" \
FLOWMASTER_ALLOW_CUSTOM_VNSTAT_DATA_DIR=1 \
bash -c '
    source "$1"
    validate_paths
    create_unique_rollback_path
    kill -TERM "$$"
' _ "$ROOT_DIR/backup_vnstat.sh" >/dev/null 2>&1
reservation_signal_status=$?
set -e
(( reservation_signal_status == 130 ))
[[ -z "$(find "$TEST_ROOT" -maxdepth 1 -type d -name 'reservation-signal-vnstat.rollback.*' -print -quit)" ]]

# 备份在归档/sidecar 提交前收到信号时，临时目录和半成品必须全部清理。
set +e
FLOWMASTER_BACKUP_DIR="$TEST_ROOT/signal-backups" \
VNSTAT_DATA_DIR="$signal_data" \
FLOWMASTER_BACKUP_LOG="$TEST_ROOT/signal.log" \
FLOWMASTER_MAINTENANCE_LOCK_FILE="$TEST_ROOT/signal.lock" \
FLOWMASTER_ALLOW_CUSTOM_VNSTAT_DATA_DIR=1 \
bash -c '
    source "$1"
    validate_paths
    prepare_backup_directory
    ARCHIVE_SNAPSHOT_DIR="$(mktemp -d "$BACKUP_PATH/.snapshot.XXXXXX")"
    ARCHIVE_TMP_FILE="$BACKUP_PATH/vnstat-interrupted.tar.gz.tmp"
    ARCHIVE_SIDECAR_TMP_FILE="$BACKUP_PATH/vnstat-interrupted.tar.gz.sha256.tmp"
    ARCHIVE_PENDING_FILE="$BACKUP_PATH/vnstat-interrupted.tar.gz"
    : >"$ARCHIVE_TMP_FILE"
    : >"$ARCHIVE_SIDECAR_TMP_FILE"
    : >"$ARCHIVE_PENDING_FILE"
    : >"${ARCHIVE_PENDING_FILE}.sha256"
    kill -TERM "$$"
' _ "$ROOT_DIR/backup_vnstat.sh" >/dev/null 2>&1
backup_signal_status=$?
set -e
(( backup_signal_status == 130 ))
[[ -z "$(find "$TEST_ROOT/signal-backups" -mindepth 1 -maxdepth 1 -print -quit)" ]]

# Linux 上使用真实 flock 证明第二个维护进程会被共享锁拒绝。
if [[ "$HAS_REAL_FLOCK" == true ]]; then
    acquire_maintenance_lock
    if FLOWMASTER_BACKUP_DIR="$BACKUP_DIR" \
       VNSTAT_DATA_DIR="$DATA_DIR" \
       FLOWMASTER_BACKUP_LOG="$LOG_FILE" \
       FLOWMASTER_MAINTENANCE_LOCK_FILE="$LOCK_FILE" \
       FLOWMASTER_ALLOW_CUSTOM_VNSTAT_DATA_DIR=1 \
       bash -c 'source "$1"; validate_paths; acquire_maintenance_lock' _ "$ROOT_DIR/backup_vnstat.sh" >/dev/null 2>&1; then
        echo "并发维护进程不应同时获得共享锁" >&2
        exit 1
    fi
    release_maintenance_lock
else
    printf 'BACKUP_VNSTAT_CONCURRENCY_TEST=SKIP(no-flock)\n'
fi

printf 'BACKUP_VNSTAT_SAFETY_TESTS=PASS\n'
