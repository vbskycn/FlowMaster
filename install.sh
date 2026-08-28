#!/usr/bin/env bash

set -Eeuo pipefail

readonly APP_NAME="flowmaster"
readonly APP_DIR="/opt/flowmaster"
readonly CONTROL_SCRIPT="/usr/local/bin/flowmaster"
readonly BACKUP_ROOT="/var/backups/flowmaster"
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

retire_legacy_pm2_app() {
    command -v pm2 >/dev/null 2>&1 || return 0

    local pm2_pid_file="${PM2_HOME:-/root/.pm2}/pm2.pid"
    [[ -r "$pm2_pid_file" ]] || return 0
    local pm2_pid
    pm2_pid="$(tr -dc '0-9' <"$pm2_pid_file")"
    [[ -n "$pm2_pid" ]] && kill -0 "$pm2_pid" >/dev/null 2>&1 || return 0

    log "检查旧版 PM2 中的 FlowMaster..."
    local describe_status=0
    timeout 5s env PIDUSAGE_USE_PS=false pm2 describe "$APP_NAME" >/dev/null 2>&1 || describe_status=$?
    if (( describe_status == 124 )); then
        warn "PM2 守护进程无响应（PID ${pm2_pid}），拒绝自动影响其管理的其他应用。请先修复 PM2 后重试。"
        return 1
    fi
    (( describe_status == 0 )) || return 0

    if ! timeout 15s env PIDUSAGE_USE_PS=false pm2 delete "$APP_NAME" >/dev/null 2>&1; then
        warn "无法在 15 秒内从 PM2 移除旧 FlowMaster，请先恢复 PM2 健康后重试。"
        return 1
    fi
    timeout 10s env PIDUSAGE_USE_PS=false pm2 save >/dev/null 2>&1 || \
        warn "旧 PM2 进程列表保存失败；FlowMaster 已停止，其他 PM2 应用未被修改。"
    log "旧 FlowMaster 已从 PM2 安全迁移；其他 PM2 应用保持不变"
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
