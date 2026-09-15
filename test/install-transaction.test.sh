#!/usr/bin/env bash

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly SOURCE_INSTALLER="$REPO_ROOT/install.sh"

# 本文件会递归启动隔离子进程。子进程直接 source 一份只替换了系统路径的
# 安装器副本，从而覆盖真实事务控制流，但绝不会接触主机上的 FlowMaster。
if [[ -n "${FLOWMASTER_TRANSACTION_TEST_CASE:-}" ]]; then
    readonly CASE_ROOT="${FLOWMASTER_TRANSACTION_TEST_ROOT:?}"
    readonly CASE_INSTALLER="${FLOWMASTER_TRANSACTION_TEST_INSTALLER:?}"
    readonly MOCK_STATE="$CASE_ROOT/systemd-state"
    readonly MOCK_LOG="$CASE_ROOT/systemctl.log"
    readonly MOCK_RELOAD_COUNT="$CASE_ROOT/daemon-reload-count"

    export FLOWMASTER_BACKUP_ROOT="$CASE_ROOT/backups"
    export FLOWMASTER_MAINTENANCE_LOCK_FILE="$CASE_ROOT/maintenance.lock"

    # 运行时从测试生成的安装器副本加载，shellcheck 无法静态跟随。
    # shellcheck disable=SC1090
    source "$CASE_INSTALLER"

    mock_state_get() {
        local key="$1" value
        IFS= read -r value <"$MOCK_STATE/$key"
        printf '%s\n' "$value"
    }

    mock_state_set() {
        local key="$1" value="$2"
        printf '%s\n' "$value" >"$MOCK_STATE/$key"
    }

    mock_daemon_reload() {
        local count
        count="$(<"$MOCK_RELOAD_COUNT")"
        count=$((count + 1))
        printf '%s\n' "$count" >"$MOCK_RELOAD_COUNT"

        case "${FLOWMASTER_TRANSACTION_TEST_RELOAD_MODE:-ok}" in
            fail-once)
                if (( count == 1 )); then
                    return 1
                fi
                ;;
            signal-twice)
                # 第一次信号触发全局清理；回滚中的第二次信号必须被 cleanup
                # 忽略，保证文件与服务状态恢复完整。
                if (( count <= 2 )); then
                    kill -TERM "$BASHPID"
                fi
                ;;
        esac

        if [[ -f "$SERVICE_FILE" && ! -L "$SERVICE_FILE" ]]; then
            mock_state_set load loaded
        else
            mock_state_set load not-found
            mock_state_set active inactive
            mock_state_set enabled not-found
            mock_state_set main_pid 0
            mock_state_set control_pid 0
        fi
    }

    mock_systemctl() {
        printf '%s\n' "$*" >>"$MOCK_LOG"
        case "${1:-}" in
            --version)
                printf 'systemd 257 (257.1-test)\n'
                ;;
            show)
                if [[ "${FLOWMASTER_TRANSACTION_TEST_QUERY_FAIL:-0}" == "1" ]]; then
                    return 1
                fi
                printf 'LoadState=%s\n' "$(mock_state_get load)"
                printf 'ActiveState=%s\n' "$(mock_state_get active)"
                printf 'UnitFileState=%s\n' "$(mock_state_get enabled)"
                printf 'MainPID=%s\n' "$(mock_state_get main_pid)"
                printf 'ControlPID=%s\n' "$(mock_state_get control_pid)"
                ;;
            is-enabled)
                printf '%s\n' "$(mock_state_get enabled)"
                [[ "$(mock_state_get enabled)" == "enabled" || "$(mock_state_get enabled)" == "enabled-runtime" ]]
                ;;
            --no-block)
                shift
                case "${1:-}" in
                    stop)
                        mock_state_set active inactive
                        mock_state_set main_pid 0
                        mock_state_set control_pid 0
                        ;;
                    start)
                        mock_state_set active active
                        mock_state_set main_pid 4242
                        mock_state_set control_pid 0
                        ;;
                    *) return 1 ;;
                esac
                ;;
            stop)
                mock_state_set active inactive
                mock_state_set main_pid 0
                mock_state_set control_pid 0
                ;;
            start)
                mock_state_set active active
                mock_state_set main_pid 4242
                mock_state_set control_pid 0
                ;;
            enable)
                if [[ "${2:-}" == "--runtime" ]]; then
                    mock_state_set enabled enabled-runtime
                else
                    mock_state_set enabled enabled
                fi
                ;;
            disable)
                case "${FLOWMASTER_TRANSACTION_TEST_DISABLE_MODE:-ok}" in
                    fail) return 1 ;;
                    lie) return 0 ;;
                    ok) mock_state_set enabled disabled ;;
                    *) return 1 ;;
                esac
                ;;
            daemon-reload)
                mock_daemon_reload
                ;;
            *) return 1 ;;
        esac
    }

    systemctl_bounded() { mock_systemctl "$@"; }
    systemctl() { mock_systemctl "$@"; }
    sync() { return 0; }
    validate_root_backup_directory() { [[ -d "$1" && ! -L "$1" ]]; }
    install_recovery_dependencies() { return 0; }
    retire_legacy_pm2_app() { return 0; }
    atomic_install_file() {
        local source_file="$1" target_file="$2" mode="$3"
        cp -- "$source_file" "$target_file" && chmod "$mode" "$target_file"
    }

    case "$FLOWMASTER_TRANSACTION_TEST_CASE" in
        preflight-failure)
            begin_deploy_transaction
            # 模拟下载、依赖或健康预检失败。退出 trap 应只丢弃事务快照，
            # 不得停止、启动、禁用或重载原本健康的服务。
            exit 77
            ;;
        stop-query-failure)
            export FLOWMASTER_TRANSACTION_TEST_QUERY_FAIL=1
            if stop_systemd_service; then
                echo "systemctl 查询失败不应被当作 unit 不存在" >&2
                exit 1
            fi
            ;;
        stop-not-found)
            mock_state_set load not-found
            mock_state_set active inactive
            mock_state_set enabled not-found
            mock_state_set main_pid 0
            mock_state_set control_pid 0
            stop_systemd_service
            ;;
        rollback-disabled-disable-failure|rollback-disabled-state-mismatch)
            mock_state_set active inactive
            mock_state_set enabled disabled
            begin_deploy_transaction
            DEPLOY_SYSTEMD_TOUCHED=1
            mock_state_set enabled enabled
            if rollback_deploy_transaction; then
                echo "disable 失败或伪成功时回滚不应报告成功" >&2
                exit 1
            fi
            ;;
        rollback-not-found-disable-failure)
            rm -f -- "$SERVICE_FILE"
            mock_state_set load not-found
            mock_state_set active inactive
            mock_state_set enabled not-found
            mock_state_set main_pid 0
            begin_deploy_transaction
            printf 'new-unit\n' >"$SERVICE_FILE"
            mock_state_set load loaded
            mock_state_set enabled enabled
            # 变量由动态 source 的安装器回滚函数读取。
            # shellcheck disable=SC2034
            DEPLOY_SYSTEMD_TOUCHED=1
            if rollback_deploy_transaction; then
                echo "not-found 回滚的 disable 失败不应被吞掉" >&2
                exit 1
            fi
            ;;
        identity-only-rollback)
            begin_deploy_transaction
            DEPLOY_SERVICE_GROUP_CREATED=1
            cleanup_created_service_identity() {
                printf 'identity-cleanup\n' >>"$MOCK_LOG"
                # 变量由动态 source 的安装器回滚函数读取。
                # shellcheck disable=SC2034
                DEPLOY_SERVICE_GROUP_CREATED=0
            }
            rollback_deploy_transaction
            ;;
        uninstall-failure|uninstall-signal)
            uninstall <<<"y"
            ;;
        *)
            echo "未知事务测试场景: $FLOWMASTER_TRANSACTION_TEST_CASE" >&2
            exit 1
            ;;
    esac
    exit 0
fi

TEST_ROOT="$(mktemp -d /tmp/flowmaster-install-transaction.XXXXXX)"
readonly TEST_ROOT
LAST_STATUS=0

test_cleanup() {
    case "$TEST_ROOT" in
        /tmp/flowmaster-install-transaction.*) rm -rf -- "$TEST_ROOT" ;;
        *) echo "拒绝清理非预期测试目录: $TEST_ROOT" >&2 ;;
    esac
}
trap test_cleanup EXIT

prepare_case() {
    local case_name="$1" case_root="$TEST_ROOT/$1" rootfs="$TEST_ROOT/$1/rootfs"
    mkdir -p \
        "$rootfs/opt/flowmaster" \
        "$rootfs/etc/systemd/system" \
        "$rootfs/usr/local/bin" \
        "$rootfs/var/lib/vnstat" \
        "$rootfs/run/lock" \
        "$case_root/backups" \
        "$case_root/systemd-state"
    chmod 0700 "$case_root/backups"

    printf 'old-app\n' >"$rootfs/opt/flowmaster/content.txt"
    printf '{"version":"1.0.0"}\n' >"$rootfs/opt/flowmaster/package.json"
    printf "'use strict';\n" >"$rootfs/opt/flowmaster/server.js"
    printf 'old-unit\n' >"$rootfs/etc/systemd/system/flowmaster.service"
    printf '#!/usr/bin/env bash\nold-control\n' >"$rootfs/usr/local/bin/flowmaster"
    chmod 0755 "$rootfs/usr/local/bin/flowmaster"

    printf 'loaded\n' >"$case_root/systemd-state/load"
    printf 'active\n' >"$case_root/systemd-state/active"
    printf 'enabled\n' >"$case_root/systemd-state/enabled"
    printf '4242\n' >"$case_root/systemd-state/main_pid"
    printf '0\n' >"$case_root/systemd-state/control_pid"
    printf '0\n' >"$case_root/daemon-reload-count"
    : >"$case_root/systemctl.log"

    # 只在测试副本中把固定系统目录映射到隔离 rootfs；产品脚本保持原样。
    sed \
        -e "s#/opt#$rootfs/opt#g" \
        -e "s#/etc/systemd/system#$rootfs/etc/systemd/system#g" \
        -e "s#/usr/local/bin#$rootfs/usr/local/bin#g" \
        -e "s#/var/lib/vnstat#$rootfs/var/lib/vnstat#g" \
        -e "s#/run/lock#$rootfs/run/lock#g" \
        -e "s#/var/backups/flowmaster#$rootfs/var/backups/flowmaster#g" \
        "$SOURCE_INSTALLER" >"$case_root/install.test.sh"
}

run_case() {
    local case_name="$1" reload_mode="${2:-ok}" disable_mode="${3:-ok}" case_root="$TEST_ROOT/$1"
    set +e
    FLOWMASTER_TRANSACTION_TEST_CASE="$case_name" \
    FLOWMASTER_TRANSACTION_TEST_ROOT="$case_root" \
    FLOWMASTER_TRANSACTION_TEST_INSTALLER="$case_root/install.test.sh" \
    FLOWMASTER_TRANSACTION_TEST_RELOAD_MODE="$reload_mode" \
    FLOWMASTER_TRANSACTION_TEST_DISABLE_MODE="$disable_mode" \
        bash "${BASH_SOURCE[0]}"
    LAST_STATUS=$?
    set -e
}

assert_original_installation() {
    local case_name="$1" case_root="$TEST_ROOT/$1" rootfs="$TEST_ROOT/$1/rootfs"
    grep -qx 'old-app' "$rootfs/opt/flowmaster/content.txt"
    grep -qx 'old-unit' "$rootfs/etc/systemd/system/flowmaster.service"
    grep -qx 'old-control' "$rootfs/usr/local/bin/flowmaster"
    grep -qx 'active' "$case_root/systemd-state/active"
    grep -qx 'enabled' "$case_root/systemd-state/enabled"
    [[ -z "$(find "$case_root/backups" -maxdepth 1 -name '.flowmaster-uninstalled-*' -print -quit)" ]]
}

assert_no_systemd_mutation() {
    local log_file="$1"
    if grep -Eq '(^| )(stop|start|enable|disable|daemon-reload)( |$)' "$log_file"; then
        echo "预检阶段意外修改了 systemd：" >&2
        cat "$log_file" >&2
        exit 1
    fi
}

prepare_case preflight-failure
run_case preflight-failure
[[ "$LAST_STATUS" == "77" ]]
assert_original_installation preflight-failure
assert_no_systemd_mutation "$TEST_ROOT/preflight-failure/systemctl.log"
[[ -z "$(find "$TEST_ROOT/preflight-failure/backups" -mindepth 1 -print -quit)" ]]

prepare_case stop-query-failure
run_case stop-query-failure
[[ "$LAST_STATUS" == "0" ]]
assert_no_systemd_mutation "$TEST_ROOT/stop-query-failure/systemctl.log"

prepare_case stop-not-found
run_case stop-not-found
[[ "$LAST_STATUS" == "0" ]]
assert_no_systemd_mutation "$TEST_ROOT/stop-not-found/systemctl.log"

prepare_case rollback-disabled-disable-failure
run_case rollback-disabled-disable-failure ok fail
[[ "$LAST_STATUS" == "0" ]]
grep -Eq '(^| )disable( |$)' "$TEST_ROOT/rollback-disabled-disable-failure/systemctl.log"

prepare_case rollback-disabled-state-mismatch
run_case rollback-disabled-state-mismatch ok lie
[[ "$LAST_STATUS" == "0" ]]
grep -qx 'enabled' "$TEST_ROOT/rollback-disabled-state-mismatch/systemd-state/enabled"

prepare_case rollback-not-found-disable-failure
run_case rollback-not-found-disable-failure ok fail
[[ "$LAST_STATUS" == "0" ]]
grep -qx 'not-found' "$TEST_ROOT/rollback-not-found-disable-failure/systemd-state/enabled"

prepare_case identity-only-rollback
run_case identity-only-rollback
[[ "$LAST_STATUS" == "0" ]]
grep -qx 'identity-cleanup' "$TEST_ROOT/identity-only-rollback/systemctl.log"
assert_no_systemd_mutation "$TEST_ROOT/identity-only-rollback/systemctl.log"

prepare_case uninstall-failure
run_case uninstall-failure fail-once
[[ "$LAST_STATUS" == "1" ]]
assert_original_installation uninstall-failure
grep -Eq '(^| )stop( |$)' "$TEST_ROOT/uninstall-failure/systemctl.log"
grep -Eq '(^| )disable( |$)' "$TEST_ROOT/uninstall-failure/systemctl.log"
grep -Eq '(^| )start( |$)' "$TEST_ROOT/uninstall-failure/systemctl.log"

prepare_case uninstall-signal
run_case uninstall-signal signal-twice
[[ "$LAST_STATUS" == "130" ]]
assert_original_installation uninstall-signal
[[ "$(<"$TEST_ROOT/uninstall-signal/daemon-reload-count")" == "2" ]]

printf 'INSTALL_TRANSACTION_TESTS=PASS\n'
