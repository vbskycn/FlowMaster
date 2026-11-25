#!/usr/bin/env bash
# FlowMaster 轻量单二进制 Linux/systemd 一键安装、升级与卸载脚本
# 安全红线：安装、更新与卸载绝不修改或删除 /var/lib/vnstat

set -Eeuo pipefail

readonly BIN_PATH="/usr/local/bin/flowmaster"
readonly CTL_PATH="/usr/local/bin/flowmaster-ctl"
readonly CONFIG_DIR="/etc/flowmaster"
readonly ENV_FILE="${CONFIG_DIR}/flowmaster.env"
readonly DATA_DIR="/var/lib/flowmaster"
readonly LEGACY_APP_DIR="/opt/flowmaster"
readonly BACKUP_ROOT="${FLOWMASTER_BACKUP_ROOT:-/var/backups/flowmaster}"
readonly LOCK_FILE="${FLOWMASTER_MAINTENANCE_LOCK_FILE:-/run/lock/flowmaster-maintenance.lock}"
readonly SERVICE_NAME="flowmaster.service"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
readonly SERVICE_USER="flowmaster"
readonly REPO_SLUG="${FLOWMASTER_REPO:-vbskycn/FlowMaster}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TMP_DIR=""
LOCK_FD=""

log()  { printf '%b\n' "${GREEN}$*${NC}"; }
warn() { printf '%b\n' "${YELLOW}$*${NC}"; }
fail() { printf '%b\n' "${RED}$*${NC}" >&2; exit 1; }

cleanup() {
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        case "$TMP_DIR" in
            /tmp/flowmaster-install.*) rm -rf -- "$TMP_DIR" ;;
        esac
    fi
}
trap cleanup EXIT

require_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || fail "请使用 root 权限执行此脚本 (sudo ./install.sh)"
}

acquire_lock() {
    command -v flock >/dev/null 2>&1 || fail "缺少 flock (util-linux)，无法获取维护锁"
    mkdir -p -- "$(dirname "$LOCK_FILE")"
    exec {LOCK_FD}>"$LOCK_FILE"
    chmod 0600 "$LOCK_FILE" 2>/dev/null || true
    flock -n "$LOCK_FD" || fail "另一个 FlowMaster 安装或维护操作正在进行中"
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) fail "不支持的 CPU 架构: $(uname -m)（当前支持 x86_64 与 arm64）" ;;
    esac
}

ensure_service_user() {
    if ! getent group "$SERVICE_USER" >/dev/null 2>&1; then
        groupadd --system "$SERVICE_USER"
    fi
    if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
        useradd --system --gid "$SERVICE_USER" --home-dir "$DATA_DIR" --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
    fi
    if getent group vnstat >/dev/null 2>&1; then
        usermod -aG vnstat "$SERVICE_USER"
    fi
}

resolve_binary() {
    local target_bin="$1"
    # 支持离线/测试指定本地已编译二进制
    if [[ -n "${FLOWMASTER_LOCAL_BIN:-}" ]]; then
        [[ -f "$FLOWMASTER_LOCAL_BIN" ]] || fail "指定的 FLOWMASTER_LOCAL_BIN 不存在: $FLOWMASTER_LOCAL_BIN"
        install -m 0755 "$FLOWMASTER_LOCAL_BIN" "$target_bin"
        return 0
    fi

    local arch version url archive
    arch="$(detect_arch)"
    version="${FLOWMASTER_VERSION:-latest}"
    if [[ -n "${FLOWMASTER_DOWNLOAD_URL:-}" ]]; then
        url="$FLOWMASTER_DOWNLOAD_URL"
    elif [[ "$version" == "latest" ]]; then
        url="https://github.com/${REPO_SLUG}/releases/latest/download/flowmaster-linux-${arch}.tar.gz"
    else
        url="https://github.com/${REPO_SLUG}/releases/download/${version}/flowmaster-linux-${arch}.tar.gz"
    fi

    archive="${TMP_DIR}/flowmaster.tar.gz"
    log "正在下载预编译轻量二进制包 (${arch}): ${url}"
    curl -fL --retry 3 --connect-timeout 10 --max-time 180 -o "$archive" "$url"

    if [[ -n "${FLOWMASTER_SHA256:-}" ]]; then
        echo "${FLOWMASTER_SHA256}  ${archive}" | sha256sum -c - || fail "SHA-256 摘要校验失败"
    fi

    tar -xzf "$archive" -C "$TMP_DIR"
    [[ -f "${TMP_DIR}/flowmaster" ]] || fail "归档中未找到 flowmaster 可执行文件"
    install -m 0755 "${TMP_DIR}/flowmaster" "$target_bin"
}

migrate_legacy_if_present() {
    mkdir -p -- "$CONFIG_DIR" "$DATA_DIR" "$BACKUP_ROOT"
    chmod 0750 "$CONFIG_DIR" "$DATA_DIR" "$BACKUP_ROOT"
    if [[ ! -f "$ENV_FILE" ]]; then
        if [[ -f "${LEGACY_APP_DIR}/.env" && ! -L "${LEGACY_APP_DIR}/.env" ]]; then
            log "检测到旧版配置 ${LEGACY_APP_DIR}/.env，正在迁移至 ${ENV_FILE}..."
            cp -- "${LEGACY_APP_DIR}/.env" "$ENV_FILE"
            if ! grep -q '^DATA_DIR=' "$ENV_FILE"; then
                printf '\nDATA_DIR=%s\n' "$DATA_DIR" >>"$ENV_FILE"
            fi
        else
            cat >"$ENV_FILE" <<EOF
HOST=0.0.0.0
PORT=10089
DATA_DIR=${DATA_DIR}
REALTIME_INTERVAL_MS=1000
ALLOW_ANONYMOUS_ADMIN=false
TRUST_PROXY=false
EOF
        fi
    fi
    chown root:"$SERVICE_USER" "$CONFIG_DIR" "$ENV_FILE"
    chmod 0750 "$CONFIG_DIR"
    chmod 0640 "$ENV_FILE"
    chown -R "$SERVICE_USER":"$SERVICE_USER" "$DATA_DIR"
    chmod 0750 "$DATA_DIR"

    if [[ -d "$LEGACY_APP_DIR" && ! -L "$LEGACY_APP_DIR" ]]; then
        local legacy_archive ts
        ts="$(date +%Y%m%d-%H%M%S)"
        legacy_archive="${BACKUP_ROOT}/legacy-node-flowmaster-${ts}"
        log "正在安全归档旧版 Node.js 目录 ${LEGACY_APP_DIR} -> ${legacy_archive}（保留 /var/lib/vnstat 不变）..."
        mv -- "$LEGACY_APP_DIR" "$legacy_archive"
    fi
}

write_systemd_and_ctl() {
    local supp_line=""
    if getent group vnstat >/dev/null 2>&1; then
        supp_line="SupplementaryGroups=vnstat"
    fi

    cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=FlowMaster Lightweight Network Traffic Monitor
After=network-online.target vnstat.service
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
${supp_line}
WorkingDirectory=${DATA_DIR}
EnvironmentFile=-${ENV_FILE}
ExecStart=${BIN_PATH} -env-file ${ENV_FILE}
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=${DATA_DIR}

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$SERVICE_FILE"

    cat >"$CTL_PATH" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-status}" in
    start|stop|restart|status) systemctl "$1" flowmaster.service ;;
    logs) journalctl -u flowmaster.service -n 100 -f ;;
    version) /usr/local/bin/flowmaster --version ;;
    *) echo "用法: flowmaster-ctl {start|stop|restart|status|logs|version}" >&2; exit 1 ;;
esac
EOF
    chmod 0755 "$CTL_PATH"
}

verify_running_service() {
    local port="10089"
    if [[ -f "$ENV_FILE" ]]; then
        local parsed_port
        parsed_port="$(awk -F= '/^[[:space:]]*PORT=[0-9]+/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' "$ENV_FILE")"
        [[ -n "$parsed_port" ]] && port="$parsed_port"
    fi

    for _ in {1..15}; do
        if systemctl is-active --quiet "$SERVICE_NAME" && \
           curl -fsS --max-time 3 "http://127.0.0.1:${port}/api/version" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

do_install_or_update() {
    TMP_DIR="$(mktemp -d /tmp/flowmaster-install.XXXXXX)"
    local staged_bin="${TMP_DIR}/flowmaster.bin"
    resolve_binary "$staged_bin"
    "$staged_bin" --version >/dev/null

    ensure_service_user

    local prev_bin_backup=""
    if [[ -f "$BIN_PATH" ]]; then
        prev_bin_backup="${TMP_DIR}/flowmaster.prev"
        cp -p -- "$BIN_PATH" "$prev_bin_backup"
    fi

    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    migrate_legacy_if_present
    install -m 0755 "$staged_bin" "$BIN_PATH"
    write_systemd_and_ctl
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null
    systemctl restart "$SERVICE_NAME"

    if ! verify_running_service; then
        warn "新版本健康检查未通过，正在尝试回滚..."
        if [[ -n "$prev_bin_backup" && -f "$prev_bin_backup" ]]; then
            install -m 0755 "$prev_bin_backup" "$BIN_PATH"
            systemctl restart "$SERVICE_NAME" || true
        fi
        fail "部署启动验证失败，请执行 journalctl -u flowmaster.service -n 50 查看详情"
    fi

    log "✅ FlowMaster 部署成功！当前版本: $("$BIN_PATH" --version)"
    log "配置文件: ${ENV_FILE}"
    log "数据目录: ${DATA_DIR}（系统 /var/lib/vnstat 保持原样未修改）"
}

do_uninstall() {
    log "正在停止并禁用 ${SERVICE_NAME}..."
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f -- "$SERVICE_FILE" "$BIN_PATH" "$CTL_PATH"
    systemctl daemon-reload || true
    log "✅ FlowMaster 程序已卸载。"
    log "为保障数据安全，${DATA_DIR}、${ENV_FILE} 与 /var/lib/vnstat 均完整保留。"
}

main() {
    require_root
    acquire_lock

    local action="${1:-}"
    if [[ -z "$action" ]]; then
        echo "========================================="
        echo "  FlowMaster 轻量流量监控 安装与维护工具"
        echo "========================================="
        echo "  1) 安装 / 安全升级 FlowMaster"
        echo "  2) 卸载 FlowMaster（保留流量历史数据）"
        echo "  0) 退出"
        read -r -p "请选择操作 [1]: " choice
        case "${choice:-1}" in
            1) action="install" ;;
            2) action="uninstall" ;;
            0) exit 0 ;;
            *) fail "无效选项" ;;
        esac
    fi

    case "$action" in
        install|update|--install) do_install_or_update ;;
        uninstall|--uninstall) do_uninstall ;;
        *) fail "用法: sudo ./install.sh [install|uninstall]" ;;
    esac
}

main "$@"
