#!/usr/bin/env bash

set -Eeuo pipefail

export FLOWMASTER_SERVICE_VERIFY_ATTEMPTS=1
export FLOWMASTER_SERVICE_VERIFY_INTERVAL_SECONDS=0
export FLOWMASTER_SERVICE_STABILITY_OBSERVATIONS=2
export FLOWMASTER_SERVICE_STABILITY_INTERVAL_SECONDS=0

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIFECYCLE_TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/flowmaster-backup-lifecycle.XXXXXX")"

# shellcheck disable=SC1091
source "$ROOT_DIR/backup_vnstat.sh"

_lifecycle_status=0
trap '_lifecycle_status=$?; trap - EXIT; handle_exit "$_lifecycle_status"; _lifecycle_status=$?; rm -rf -- "$LIFECYCLE_TEST_ROOT"; exit "$_lifecycle_status"' EXIT

flowmaster_active=true
vnstat_active=true
calls=""
fail_stop=""
fail_start=""
start_without_active=""
fail_show=""
flowmaster_state_override=""
vnstat_state_override=""
flowmaster_type="simple"
vnstat_type="simple"
flowmaster_main_pid_override=""
vnstat_main_pid_override=""
flowmaster_control_pid_override=""
vnstat_control_pid_override=""
flowmaster_control_group_override=""
vnstat_control_group_override=""
flowmaster_sub_state_override=""
vnstat_sub_state_override=""
flowmaster_result_override=""
vnstat_result_override=""
transient_failure_marker="$LIFECYCLE_TEST_ROOT/transient-failure"

emit_runtime_properties() {
    local service_name="$1"
    local is_active state service_type sub_state main_pid result
    case "$service_name" in
        flowmaster.service)
            is_active="$flowmaster_active"
            state="${flowmaster_state_override:-}"
            service_type="$flowmaster_type"
            sub_state="${flowmaster_sub_state_override:-}"
            main_pid="${flowmaster_main_pid_override:-}"
            result="${flowmaster_result_override:-}"
            ;;
        vnstat)
            is_active="$vnstat_active"
            state="${vnstat_state_override:-}"
            service_type="$vnstat_type"
            sub_state="${vnstat_sub_state_override:-}"
            main_pid="${vnstat_main_pid_override:-}"
            result="${vnstat_result_override:-}"
            ;;
        *) return 1 ;;
    esac

    [[ -n "$state" ]] || { if [[ "$is_active" == true ]]; then state=active; else state=inactive; fi; }
    if [[ -f "$transient_failure_marker" ]] && [[ "$(<"$transient_failure_marker")" == "$service_name" ]]; then
        if [[ ! -e "${transient_failure_marker}.seen" ]]; then
            : >"${transient_failure_marker}.seen"
        else
            state=failed
            sub_state=failed
            main_pid=0
            result=exit-code
            rm -f -- "$transient_failure_marker" "${transient_failure_marker}.seen"
        fi
    fi

    if [[ -z "$sub_state" ]]; then
        if [[ "$state" == active && "$service_type" == oneshot ]]; then
            sub_state=exited
        elif [[ "$state" == active ]]; then
            sub_state=running
        elif [[ "$state" == failed ]]; then
            sub_state=failed
        else
            sub_state=dead
        fi
    fi
    if [[ -z "$main_pid" ]]; then
        if [[ "$state" == active && "$service_type" != oneshot ]]; then main_pid=12345; else main_pid=0; fi
    fi
    [[ -n "$result" ]] || { if [[ "$state" == failed ]]; then result=exit-code; else result=success; fi; }

    printf 'Type=%s\nMainPID=%s\nResult=%s\nActiveState=%s\nSubState=%s\n' \
        "$service_type" "$main_pid" "$result" "$state" "$sub_state"
}

emit_inactive_properties() {
    local service_name="$1"
    local is_active state main_pid control_pid control_group
    case "$service_name" in
        flowmaster.service)
            is_active="$flowmaster_active"
            state="${flowmaster_state_override:-}"
            main_pid="${flowmaster_main_pid_override:-}"
            control_pid="${flowmaster_control_pid_override:-}"
            control_group="${flowmaster_control_group_override:-}"
            ;;
        vnstat)
            is_active="$vnstat_active"
            state="${vnstat_state_override:-}"
            main_pid="${vnstat_main_pid_override:-}"
            control_pid="${vnstat_control_pid_override:-}"
            control_group="${vnstat_control_group_override:-}"
            ;;
        *) return 1 ;;
    esac

    [[ -n "$state" ]] || { if [[ "$is_active" == true ]]; then state=active; else state=inactive; fi; }
    [[ -n "$main_pid" ]] || { if [[ "$is_active" == true ]]; then main_pid=12345; else main_pid=0; fi; }
    [[ -n "$control_pid" ]] || control_pid=0
    printf 'ActiveState=%s\nMainPID=%s\nControlPID=%s\nControlGroup=%s\n' \
        "$state" "$main_pid" "$control_pid" "$control_group"
}

nonempty_control_group=""
unit_cgroup_is_empty() {
    [[ -z "$1" || "$1" != "$nonempty_control_group" ]]
}

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
            [[ "$fail_show" != "$service_name" ]] || return 1
            if [[ "${3:-}" == "--property=ActiveState" && "${4:-}" == "--value" && $# -eq 4 ]]; then
                case "$service_name" in
                    flowmaster.service)
                        [[ -z "$flowmaster_state_override" ]] || { printf '%s\n' "$flowmaster_state_override"; return 0; }
                        if [[ "$flowmaster_active" == true ]]; then printf 'active\n'; else printf 'inactive\n'; fi
                        ;;
                    vnstat)
                        [[ -z "$vnstat_state_override" ]] || { printf '%s\n' "$vnstat_state_override"; return 0; }
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
            calls+="stop:$service_name "
            [[ "$fail_stop" != "$service_name" ]] || return 1
            case "$service_name" in
                flowmaster.service) flowmaster_active=false ;;
                vnstat) vnstat_active=false ;;
                *) return 1 ;;
            esac
            ;;
        start)
            calls+="start:$service_name "
            [[ "$fail_start" != "$service_name" ]] || return 1
            [[ "$start_without_active" != "$service_name" ]] || return 0
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

stop_services
[[ "$calls" == "stop:flowmaster.service stop:vnstat " ]]
[[ "$flowmaster_active" == false && "$vnstat_active" == false ]]

calls=""
restore_services
[[ "$calls" == "start:vnstat start:flowmaster.service " ]]
[[ "$flowmaster_active" == true && "$vnstat_active" == true ]]

# 同一交互进程再次执行时必须重新探测，不能沿用上一次的活动状态。
flowmaster_active=false
vnstat_active=false
calls=""
stop_services
[[ -z "$calls" ]]
restore_services
[[ -z "$calls" ]]
[[ "$flowmaster_active" == false && "$vnstat_active" == false ]]

# 第二个停止动作失败时，应恢复第一个已停止服务并报告失败。
flowmaster_active=true
vnstat_active=true
fail_stop=vnstat
calls=""
if stop_services; then
    echo "vnstat 停止失败不应被视为成功" >&2
    exit 1
fi
[[ "$calls" == "stop:flowmaster.service stop:vnstat start:vnstat start:flowmaster.service " ]]
[[ "$flowmaster_active" == true && "$vnstat_active" == true ]]
[[ "$SERVICES_STOPPED" == false ]]
fail_stop=""

# vnstat 启动失败时不得提前启动 FlowMaster，并保留可重试状态。
calls=""
stop_services
calls=""
fail_start=vnstat
if restore_services; then
    echo "vnstat 启动失败不应被视为成功" >&2
    exit 1
fi
[[ "$calls" == "start:vnstat " ]]
[[ "$flowmaster_active" == false && "$vnstat_active" == false ]]
[[ "$SERVICES_STOPPED" == true ]]
fail_start=""
calls=""
restore_services
[[ "$calls" == "start:vnstat start:flowmaster.service " ]]

# FlowMaster 启动失败同样必须报告失败，并允许随后重试。
calls=""
stop_services
calls=""
fail_start=flowmaster.service
if restore_services; then
    echo "FlowMaster 启动失败不应被视为成功" >&2
    exit 1
fi
[[ "$calls" == "start:vnstat start:flowmaster.service " ]]
[[ "$flowmaster_active" == false && "$vnstat_active" == true ]]
[[ "$SERVICES_STOPPED" == true ]]
fail_start=""
calls=""
restore_services
[[ "$calls" == "start:vnstat start:flowmaster.service " ]]
[[ "$flowmaster_active" == true && "$vnstat_active" == true ]]
[[ "$SERVICES_STOPPED" == false ]]

# 常驻服务需要 running、成功结果和非零 MainPID；oneshot 则允许 exited/0。
flowmaster_main_pid_override=0
if service_has_valid_active_runtime flowmaster.service; then
    echo "普通常驻服务的 MainPID=0 不应通过运行态校验" >&2
    exit 1
fi
flowmaster_main_pid_override=""
flowmaster_type=oneshot
service_has_valid_active_runtime flowmaster.service
flowmaster_type=simple

# 服务第一次呈现健康 active、下一次立即 failed 时，稳定观察必须报告失败。
calls=""
stop_services
calls=""
printf '%s\n' 'flowmaster.service' >"$transient_failure_marker"
if restore_services; then
    echo "短暂 active 后立即失败不应被视为恢复成功" >&2
    exit 1
fi
[[ "$calls" == "start:vnstat start:flowmaster.service " ]]
[[ "$SERVICES_STOPPED" == true ]]
[[ ! -e "$transient_failure_marker" && ! -e "${transient_failure_marker}.seen" ]]
calls=""
restore_services
[[ "$flowmaster_active" == true && "$vnstat_active" == true ]]
[[ "$SERVICES_STOPPED" == false ]]

# 查询失败或 systemd 过渡态不能被误判为“已停止”后继续移动数据库。
calls=""
fail_show=vnstat
if stop_services; then
    echo "systemd 状态查询失败不应允许进入停服阶段" >&2
    exit 1
fi
[[ -z "$calls" && "$SERVICES_STOPPED" == false ]]
fail_show=""
vnstat_state_override=activating
if stop_services; then
    echo "vnstat 过渡状态不应被视为稳定停服状态" >&2
    exit 1
fi
[[ -z "$calls" && "$SERVICES_STOPPED" == false ]]
vnstat_state_override=""

# inactive/failed 只有在主进程、控制进程和整个 unit cgroup 都为空时才算停稳。
flowmaster_main_pid_override=24680
if stop_services; then
    echo "inactive unit 仍有 MainPID 时不应进入数据操作" >&2
    exit 1
fi
[[ "$SERVICES_STOPPED" == false ]]
flowmaster_main_pid_override=""

vnstat_control_pid_override=13579
if stop_services; then
    echo "inactive unit 仍有 ControlPID 时不应进入数据操作" >&2
    exit 1
fi
[[ "$SERVICES_STOPPED" == false ]]
vnstat_control_pid_override=""

flowmaster_control_group_override=/system.slice/flowmaster.service
nonempty_control_group=/system.slice/flowmaster.service
if stop_services; then
    echo "inactive unit 的 cgroup 仍有进程时不应进入数据操作" >&2
    exit 1
fi
[[ "$SERVICES_STOPPED" == false ]]
flowmaster_control_group_override=""
nonempty_control_group=""

flowmaster_state_override=failed
flowmaster_main_pid_override=24680
if stop_services; then
    echo "failed unit 仍有 MainPID 时也不应被视为停稳" >&2
    exit 1
fi
[[ "$SERVICES_STOPPED" == false ]]
flowmaster_state_override=""
flowmaster_main_pid_override=""

# systemctl start 即使返回 0，也必须以 ActiveState 的结果为准。
calls=""
stop_services
calls=""
start_without_active=flowmaster.service
if restore_services; then
    echo "FlowMaster 未进入 active 时不应被视为恢复成功" >&2
    exit 1
fi
[[ "$calls" == "start:vnstat start:flowmaster.service " ]]
[[ "$flowmaster_active" == false && "$vnstat_active" == true ]]
[[ "$SERVICES_STOPPED" == true ]]
start_without_active=""
calls=""
restore_services
[[ "$flowmaster_active" == true && "$vnstat_active" == true ]]
[[ "$SERVICES_STOPPED" == false ]]

bash "$ROOT_DIR/test/backup-vnstat-safety.test.sh"

printf 'BACKUP_VNSTAT_LIFECYCLE_TESTS=PASS\n'
