#!/usr/bin/env bash

set -Eeuo pipefail

readonly APP_NAME="flowmaster"
readonly APP_DIR="/opt/flowmaster"
readonly CONTROL_SCRIPT="/usr/local/bin/flowmaster"
readonly BACKUP_ROOT="/var/backups/flowmaster"
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

log() { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}$*${NC}"; }
fail() { echo -e "${RED}$*${NC}" >&2; exit 1; }

cleanup() {
    if [[ -n "$STAGE_DIR" && -d "$STAGE_DIR" ]]; then
        rm -rf -- "$STAGE_DIR"
    fi
}
trap cleanup EXIT

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "请使用 root 权限运行此脚本"
}

check_installation() {
    [[ -d "$APP_DIR" ]] || command -v flowmaster >/dev/null 2>&1
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

install_dependencies() {
    log "检查系统依赖..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
    fi
    for command_package in "curl:curl" "tar:tar" "node:nodejs" "npm:npm" "vnstat:vnstat"; do
        local command_name="${command_package%%:*}"
        local package_name="${command_package##*:}"
        command -v "$command_name" >/dev/null 2>&1 || install_package "$package_name"
    done

    local node_major
    node_major="$(node -p 'Number(process.versions.node.split(".")[0])')"
    (( node_major >= 18 )) || fail "Node.js 版本过低，需要 18 或更高版本"

    if ! command -v pm2 >/dev/null 2>&1; then
        npm install --global pm2
    fi

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
    curl --fail --location --retry 3 --retry-delay 2 --output "$archive" "$DOWNLOAD_URL"

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
    local pid=""
    local output_file
    output_file="$(mktemp)"

    (
        cd "$target_dir"
        exec env HOST=127.0.0.1 PORT="$smoke_port" node server.js >"$output_file" 2>&1
    ) &
    pid=$!

    for _ in {1..20}; do
        if curl --fail --silent "http://127.0.0.1:${smoke_port}/api/version" >/dev/null; then
            kill "$pid" >/dev/null 2>&1 || true
            wait "$pid" 2>/dev/null || true
            rm -f -- "$output_file"
            return 0
        fi
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
    done

    warn "临时服务日志:"
    tail -n 30 "$output_file" >&2 || true
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" 2>/dev/null || true
    rm -f -- "$output_file"
    return 1
}

start_pm2() {
    cd "$APP_DIR"
    pm2 delete "$APP_NAME" >/dev/null 2>&1 || true
    pm2 start ecosystem.config.js --env production
    pm2 save
}

deploy() {
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

    if [[ -d "$APP_DIR" ]]; then
        ROLLBACK_DIR="$BACKUP_ROOT/rollback-$(date +%Y%m%d-%H%M%S)"
        pm2 stop "$APP_NAME" >/dev/null 2>&1 || true
        mv "$APP_DIR" "$ROLLBACK_DIR"
    fi

    mv "$STAGE_DIR" "$APP_DIR"
    STAGE_DIR=""

    if ! start_pm2; then
        warn "新版本启动失败，正在回滚..."
        rm -rf -- "$APP_DIR"
        if [[ -n "$ROLLBACK_DIR" && -d "$ROLLBACK_DIR" ]]; then
            mv "$ROLLBACK_DIR" "$APP_DIR"
            start_pm2 || true
        fi
        fail "部署失败，已尝试恢复旧版本"
    fi

    create_control_script
    local installed_version
    installed_version="$(node -p "require('${APP_DIR}/package.json').version")"
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
    start) pm2 start flowmaster ;;
    stop) pm2 stop flowmaster ;;
    restart) pm2 restart flowmaster ;;
    status) pm2 show flowmaster ;;
    logs) pm2 logs flowmaster ;;
    *) echo "用法: flowmaster {start|stop|restart|status|logs}"; exit 1 ;;
esac
EOF
    chmod 0755 "$CONTROL_SCRIPT"
}

uninstall() {
    local confirmation
    read -r -p "确认卸载 FlowMaster？vnstat 历史数据将被保留 [y/N]: " confirmation
    [[ "$confirmation" =~ ^[Yy]$ ]] || { warn "已取消"; return; }

    pm2 delete "$APP_NAME" >/dev/null 2>&1 || true
    pm2 save >/dev/null 2>&1 || true
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

main "$@"
