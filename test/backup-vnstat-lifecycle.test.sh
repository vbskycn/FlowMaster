#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/backup_vnstat.sh"

flowmaster_active=true
vnstat_active=true
calls=""
fail_stop=""
fail_start=""

systemctl() {
    local action="${1:-}"
    case "$action" in
        is-active)
            [[ "${2:-}" == "--quiet" ]] || return 1
            case "${3:-}" in
                flowmaster.service) [[ "$flowmaster_active" == true ]] ;;
                vnstat) [[ "$vnstat_active" == true ]] ;;
                *) return 1 ;;
            esac
            ;;
        stop)
            calls+="stop:${2:-} "
            [[ "$fail_stop" != "${2:-}" ]] || return 1
            case "${2:-}" in
                flowmaster.service) flowmaster_active=false ;;
                vnstat) vnstat_active=false ;;
                *) return 1 ;;
            esac
            ;;
        start)
            calls+="start:${2:-} "
            [[ "$fail_start" != "${2:-}" ]] || return 1
            case "${2:-}" in
                flowmaster.service) flowmaster_active=true ;;
                vnstat) vnstat_active=true ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
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

printf 'BACKUP_VNSTAT_LIFECYCLE_TESTS=PASS\n'
