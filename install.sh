#!/usr/bin/env bash
# ==============================================================================
# FlowMaster 一键安装、更新与维护脚本（支持 Docker 部署 & 二进制 systemd 部署）
# - 自动识别中国大陆网络环境并启用多节点 GitHub 加速代理回退，防止下载超时出错
# - 支持全新部署最新版、平滑更新已有版本（失败自动回滚）与安全卸载
# - 安全红线：任何操作均绝不修改或删除宿主机 /var/lib/vnstat 历史数据
# ==============================================================================

set -Eeuo pipefail

readonly REPO_SLUG="${FLOWMASTER_REPO:-vbskycn/FlowMaster}"
readonly DOCKERHUB_IMAGE="${FLOWMASTER_DOCKER_IMAGE:-zhoujie218/flowmaster}"
readonly GHCR_IMAGE="${FLOWMASTER_GHCR_IMAGE:-ghcr.io/vbskycn/flowmaster}"
readonly CONTAINER_NAME="${FLOWMASTER_CONTAINER_NAME:-flowmaster}"
readonly DOCKER_DATA_DIR="${FLOWMASTER_DOCKER_DATA_DIR:-/opt/flowmaster/data}"

readonly BIN_PATH="/usr/local/bin/flowmaster"
readonly CTL_PATH="/usr/local/bin/flowmaster-ctl"
readonly CONFIG_DIR="/etc/flowmaster"
readonly ENV_FILE="${CONFIG_DIR}/flowmaster.env"
readonly BIN_DATA_DIR="/var/lib/flowmaster"
readonly LEGACY_APP_DIR="/opt/flowmaster"
readonly BACKUP_ROOT="${FLOWMASTER_BACKUP_ROOT:-/var/backups/flowmaster}"
readonly LOCK_FILE="${FLOWMASTER_MAINTENANCE_LOCK_FILE:-/run/lock/flowmaster-maintenance.lock}"
readonly SERVICE_NAME="flowmaster.service"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
readonly SERVICE_USER="flowmaster"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TMP_DIR=""
LOCK_FD=""
IS_CN_ENV=0
ACTIVE_GH_PROXY=""

# 内置 GitHub 代理候选池（国内环境自动按连通性择优并逐级回退，直连兜底）
readonly DEFAULT_GH_PROXIES=(
    "https://gh-proxy.com/"
    "https://ghfast.top/"
    "https://ghproxy.net/"
)

# 内置 Docker 镜像加速前缀候选（当 Docker Hub 官方与 GHCR 直连均受阻时自动回退）
readonly DEFAULT_DOCKER_MIRRORS=(
    "docker.1ms.run"
    "docker.xuanyuan.me"
)

log()  { printf '%b\n' "${GREEN}[FlowMaster] $*${NC}"; }
info() { printf '%b\n' "${BLUE}[FlowMaster] $*${NC}"; }
warn() { printf '%b\n' "${YELLOW}[FlowMaster] $*${NC}"; }
fail() { printf '%b\n' "${RED}[FlowMaster] 错误: $*${NC}" >&2; exit 1; }

cleanup() {
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        case "$TMP_DIR" in
            /tmp/flowmaster-install.*) rm -rf -- "$TMP_DIR" ;;
        esac
    fi
}
trap cleanup EXIT

require_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || fail "请使用 root 权限执行此脚本（例如: sudo ./install.sh）"
}

ensure_base_tools() {
    local missing=()
    for cmd in curl tar sha256sum flock; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    [[ ${#missing[@]} -eq 0 ]] && return 0

    info "正在补齐基础工具 (${missing[*]})..."
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update -y
        DEBIAN_FRONTEND=noninteractive apt-get install -y curl tar coreutils util-linux ca-certificates
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl tar coreutils util-linux ca-certificates
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl tar coreutils util-linux ca-certificates
    else
        fail "缺少基础命令 (${missing[*]})，请先手动安装"
    fi
}

acquire_lock() {
    mkdir -p -- "$(dirname "$LOCK_FILE")"
    exec {LOCK_FD}>"$LOCK_FILE"
    chmod 0600 "$LOCK_FILE" 2>/dev/null || true
    flock -n "$LOCK_FD" || fail "另一个 FlowMaster 安装、更新或维护任务正在进行中"
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) fail "不支持的 CPU 架构: $(uname -m)（目前支持 x86_64/amd64 与 aarch64/arm64）" ;;
    esac
}

normalize_proxy_prefix() {
    local p="$1"
    [[ -z "$p" ]] && { echo ""; return 0; }
    [[ "$p" == */ ]] || p="${p}/"
    echo "$p"
}

build_proxied_url() {
    local prefix="$1"
    local raw_url="$2"
    if [[ -z "$prefix" ]]; then
        echo "$raw_url"
    else
        echo "${prefix}${raw_url}"
    fi
}

# 自动识别国内网络环境并挑选真正返回有效内容的 GitHub 代理节点
detect_network_and_proxy() {
    if [[ -n "${FLOWMASTER_GH_PROXY:-}" ]]; then
        IS_CN_ENV=1
        ACTIVE_GH_PROXY="$(normalize_proxy_prefix "$FLOWMASTER_GH_PROXY")"
        info "已使用环境变量指定的 GitHub 代理: ${ACTIVE_GH_PROXY}"
        return 0
    fi

    if [[ "${FLOWMASTER_CN:-}" == "0" ]]; then
        IS_CN_ENV=0
        ACTIVE_GH_PROXY=""
        info "已显式指定直连模式 (FLOWMASTER_CN=0)"
        return 0
    fi

    local probe_raw="https://raw.githubusercontent.com/${REPO_SLUG}/main/VERSION"
    if [[ "${FLOWMASTER_CN:-}" == "1" ]]; then
        IS_CN_ENV=1
    else
        # 1) 通过 Cloudflare 边缘节点快速识别国家代码；2) 实测 GitHub Raw 直连延迟与可达性
        local cf_trace=""
        cf_trace="$(curl -fsSL --connect-timeout 2 --max-time 3 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
        if printf '%s\n' "$cf_trace" | grep -q '^loc=CN$'; then
            IS_CN_ENV=1
        else
            local direct_ver=""
            direct_ver="$(curl -fsSL --connect-timeout 3 --max-time 5 "$probe_raw" 2>/dev/null || true)"
            if ! printf '%s\n' "$direct_ver" | grep -q '^APP_NAME=FlowMaster'; then
                IS_CN_ENV=1
            fi
        fi
    fi

    if (( IS_CN_ENV == 0 )); then
        info "网络检测：GitHub 官方直连畅通"
        return 0
    fi

    warn "检测到中国大陆或 GitHub 直连受限网络环境，正在自动测速选择可用 GitHub 代理..."
    local candidate proxied_probe body
    for candidate in "${DEFAULT_GH_PROXIES[@]}"; do
        proxied_probe="$(build_proxied_url "$candidate" "$probe_raw")"
        body="$(curl -fsSL --connect-timeout 3 --max-time 6 "$proxied_probe" 2>/dev/null || true)"
        if printf '%s\n' "$body" | grep -q '^APP_NAME=FlowMaster'; then
            ACTIVE_GH_PROXY="$candidate"
            log "已自动启用可用 GitHub 代理: ${ACTIVE_GH_PROXY}"
            return 0
        fi
    done

    warn "内置代理节点探测未命中，将依次尝试所有候选节点与官方直连兜底"
}

# 多节点容错下载 GitHub URL（当前代理失败自动切换其余代理与直连，防止单点故障）
download_github_file() {
    local raw_url="$1"
    local dest_file="$2"
    local candidates=()
    local p

    if [[ -n "$ACTIVE_GH_PROXY" ]]; then
        candidates+=("$ACTIVE_GH_PROXY")
    fi
    if (( IS_CN_ENV == 1 )); then
        for p in "${DEFAULT_GH_PROXIES[@]}"; do
            [[ "$p" == "$ACTIVE_GH_PROXY" ]] || candidates+=("$p")
        done
        candidates+=("")
    else
        candidates+=("")
        for p in "${DEFAULT_GH_PROXIES[@]}"; do
            candidates+=("$p")
        done
    fi

    local prefix target_url
    for prefix in "${candidates[@]}"; do
        target_url="$(build_proxied_url "$prefix" "$raw_url")"
        if curl -fL --retry 2 --connect-timeout 6 --max-time 180 -o "$dest_file" "$target_url" 2>/dev/null && [[ -s "$dest_file" ]]; then
            # 拒绝部分失效代理返回的 HTML 错误页面伪装成正常文件
            if ! head -c 64 "$dest_file" | grep -qi '<!doctype html\|<html'; then
                return 0
            fi
        fi
    done

    fail "无法下载文件: ${raw_url}（可通过 FLOWMASTER_GH_PROXY 指定可用代理或使用 FLOWMASTER_LOCAL_BIN 离线安装）"
}

# 三级容错获取远程最新正式版本号（不带前导 v，例如 2.0.0）
resolve_target_version() {
    if [[ -n "${FLOWMASTER_VERSION:-}" && "${FLOWMASTER_VERSION}" != "latest" ]]; then
        echo "${FLOWMASTER_VERSION#v}"
        return 0
    fi

    local ver=""
    # 通道 1: GitHub Releases latest 302 跳转（不消耗 API 配额）
    if (( IS_CN_ENV == 0 )); then
        local final_url=""
        final_url="$(curl -fsSL -o /dev/null -w '%{url_effective}' --connect-timeout 4 --max-time 8 "https://github.com/${REPO_SLUG}/releases/latest" 2>/dev/null || true)"
        if [[ "$final_url" =~ /releases/tag/v?([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
            ver="${BASH_REMATCH[1]}"
        fi
    fi

    # 通道 2: GitHub API
    if [[ -z "$ver" && "$IS_CN_ENV" -eq 0 ]]; then
        local api_json=""
        api_json="$(curl -fsSL --connect-timeout 4 --max-time 8 "https://api.github.com/repos/${REPO_SLUG}/releases/latest" 2>/dev/null || true)"
        ver="$(printf '%s' "$api_json" | sed -n 's/.*"tag_name":[[:space:]]*"v\?\([0-9][0-9.]*\)".*/\1/p' | head -n1)"
    fi

    # 通道 3: 通过自动代理通道读取主分支 VERSION 唯一版本源（国内最稳妥通道）
    if [[ -z "$ver" ]]; then
        local ver_file="${TMP_DIR}/VERSION.remote"
        download_github_file "https://raw.githubusercontent.com/${REPO_SLUG}/main/VERSION" "$ver_file"
        ver="$(awk -F= '/^APP_VERSION=/ { gsub(/[[:space:]"'"'"'v]/, "", $2); print $2; exit }' "$ver_file")"
    fi

    [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "无法解析最新版本号: ${ver:-空}"
    echo "$ver"
}

get_installed_binary_version() {
    if [[ -x "$BIN_PATH" ]]; then
        local out ver
        out="$("$BIN_PATH" --version 2>/dev/null || true)"
        ver="$(printf '%s' "$out" | awk '{ gsub(/^v/, "", $NF); print $NF }')"
        if [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ver"
            return 0
        fi
    fi
    if [[ -f "${LEGACY_APP_DIR}/package.json" ]]; then
        local legacy_ver
        legacy_ver="$(sed -n 's/.*"version":[[:space:]]*"\([0-9][0-9.]*\)".*/\1/p' "${LEGACY_APP_DIR}/package.json" | head -n1)"
        if [[ -n "$legacy_ver" ]]; then
            echo "${legacy_ver} (旧版 Node.js)"
            return 0
        fi
    fi
}

get_running_docker_version() {
    if command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
        docker exec "$CONTAINER_NAME" /usr/local/bin/flowmaster --version 2>/dev/null | awk '{ gsub(/^v/, "", $NF); print $NF }' || true
    fi
}

detect_existing_mode() {
    if command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
        echo "docker"
        return 0
    fi
    if [[ -f "$SERVICE_FILE" || -x "$BIN_PATH" || -d "$LEGACY_APP_DIR" ]]; then
        echo "binary"
        return 0
    fi
    echo "none"
}

verify_http_health() {
    local port="$1"
    local expected_ver="${2:-}"
    local resp=""
    for _ in {1..20}; do
        resp="$(curl -fsS --max-time 3 "http://127.0.0.1:${port}/api/version" 2>/dev/null || true)"
        if [[ -n "$resp" ]]; then
            if [[ -z "$expected_ver" ]] || printf '%s' "$resp" | grep -q "\"version\":\"${expected_ver}\""; then
                return 0
            fi
        fi
        sleep 1
    done
    return 1
}

# ==============================================================================
# 模式一：Docker 部署与平滑更新（支持国内镜像加速回退 + 失败自动回滚）
# ==============================================================================
pull_flowmaster_image() {
    local version="$1"
    local target_tag="${DOCKERHUB_IMAGE}:${version}"
    local candidates=()

    if (( IS_CN_ENV == 1 )); then
        local m
        for m in "${DEFAULT_DOCKER_MIRRORS[@]}"; do
            candidates+=("${m}/${DOCKERHUB_IMAGE}:${version}")
        done
        candidates+=("${GHCR_IMAGE}:${version}")
        candidates+=("${DOCKERHUB_IMAGE}:${version}")
    else
        candidates+=("${DOCKERHUB_IMAGE}:${version}")
        candidates+=("${GHCR_IMAGE}:${version}")
    fi

    local candidate
    for candidate in "${candidates[@]}"; do
        info "尝试拉取容器镜像: ${candidate}"
        if docker pull "$candidate"; then
            if [[ "$candidate" != "$target_tag" ]]; then
                docker tag "$candidate" "$target_tag"
            fi
            docker tag "$target_tag" "${DOCKERHUB_IMAGE}:latest"
            return 0
        fi
        warn "从 ${candidate} 拉取未成功，自动切换下一个镜像源..."
    done

    fail "所有镜像源均拉取失败，请检查 Docker 网络或配置 daemon.json registry-mirrors 后重试"
}

deploy_or_update_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        fail "未检测到 Docker，请先安装 Docker 或改用二进制模式: sudo ./install.sh binary"
    fi
    docker info >/dev/null 2>&1 || fail "Docker 守护进程未启动，请先执行 systemctl start docker"

    TMP_DIR="$(mktemp -d /tmp/flowmaster-install.XXXXXX)"
    local target_ver current_ver
    target_ver="$(resolve_target_version)"
    current_ver="$(get_running_docker_version)"

    if [[ -n "$current_ver" ]]; then
        info "检测到已存在的 Docker 容器 (${CONTAINER_NAME})，当前版本: v${current_ver}，目标版本: v${target_ver}"
    else
        info "准备通过 Docker 全新部署 FlowMaster v${target_ver}"
    fi

    local port="${FLOWMASTER_PORT:-10089}"
    local data_dir="$DOCKER_DATA_DIR"
    local prev_image_id=""

    if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
        prev_image_id="$(docker inspect --format '{{.Image}}' "$CONTAINER_NAME" 2>/dev/null || true)"
        local existing_port
        existing_port="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER_NAME" 2>/dev/null | awk -F= '$1=="PORT"{print $2; exit}')"
        [[ -n "${FLOWMASTER_PORT:-}" ]] || port="${existing_port:-10089}"

        local existing_mount
        existing_mount="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)"
        [[ -n "${FLOWMASTER_DOCKER_DATA_DIR:-}" ]] || data_dir="${existing_mount:-$DOCKER_DATA_DIR}"
    fi

    pull_flowmaster_image "$target_ver"

    mkdir -p -- "$data_dir"
    chmod 0750 "$data_dir"

    local vnstat_args=()
    if [[ -d /var/lib/vnstat && ! -L /var/lib/vnstat ]]; then
        vnstat_args=(-v /var/lib/vnstat:/var/lib/vnstat:ro -e VNSTAT_DB_DIR=/var/lib/vnstat)
    fi

    # 若同一台机器上旧 systemd 服务正在占用端口，提示用户避免双实例冲突
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        warn "检测到宿主机 systemd 服务 ${SERVICE_NAME} 正在运行，已停止该服务以交由 Docker 容器接管端口"
        systemctl stop "$SERVICE_NAME" || true
        systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    fi

    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

    docker run -d \
        --name "$CONTAINER_NAME" \
        --restart unless-stopped \
        --network host \
        -e TZ="${TZ:-Asia/Shanghai}" \
        -e HOST="${FLOWMASTER_HOST:-0.0.0.0}" \
        -e PORT="$port" \
        -e DATA_DIR=/data \
        -v "${data_dir}:/data" \
        "${vnstat_args[@]}" \
        "${DOCKERHUB_IMAGE}:${target_ver}" >/dev/null

    if ! verify_http_health "$port" "$target_ver"; then
        warn "新容器健康检查未通过，正在尝试回滚..."
        docker logs "$CONTAINER_NAME" --tail 30 >&2 || true
        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
        if [[ -n "$prev_image_id" ]]; then
            docker run -d \
                --name "$CONTAINER_NAME" \
                --restart unless-stopped \
                --network host \
                -e TZ="${TZ:-Asia/Shanghai}" \
                -e PORT="$port" \
                -e DATA_DIR=/data \
                -v "${data_dir}:/data" \
                "${vnstat_args[@]}" \
                "$prev_image_id" >/dev/null || true
        fi
        fail "Docker 容器启动验证失败"
    fi

    log "✅ FlowMaster v${target_ver} (Docker 模式) 部署/更新完成！"
    log "访问地址: http://服务器IP:${port}"
    log "持久化目录: ${data_dir}（宿主机 /var/lib/vnstat 保持只读未修改）"
}

# ==============================================================================
# 模式二：二进制 + systemd 部署与平滑更新（支持自动代理 + SHA-256 校验 + 回滚）
# ==============================================================================
ensure_service_user() {
    if ! getent group "$SERVICE_USER" >/dev/null 2>&1; then
        groupadd --system "$SERVICE_USER"
    fi
    if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
        useradd --system --gid "$SERVICE_USER" --home-dir "$BIN_DATA_DIR" --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
    fi
    if getent group vnstat >/dev/null 2>&1; then
        usermod -aG vnstat "$SERVICE_USER"
    fi
}

resolve_binary_artifact() {
    local target_bin="$1"
    local target_ver="$2"

    if [[ -n "${FLOWMASTER_LOCAL_BIN:-}" ]]; then
        [[ -f "$FLOWMASTER_LOCAL_BIN" ]] || fail "指定的本地二进制不存在: $FLOWMASTER_LOCAL_BIN"
        install -m 0755 "$FLOWMASTER_LOCAL_BIN" "$target_bin"
        return 0
    fi

    local arch archive_name base_release_url archive_path sums_path expected_hash actual_hash
    arch="$(detect_arch)"
    archive_name="flowmaster-linux-${arch}.tar.gz"
    base_release_url="https://github.com/${REPO_SLUG}/releases/download/v${target_ver}"
    archive_path="${TMP_DIR}/${archive_name}"
    sums_path="${TMP_DIR}/SHA256SUMS"

    if [[ -n "${FLOWMASTER_DOWNLOAD_URL:-}" ]]; then
        download_github_file "$FLOWMASTER_DOWNLOAD_URL" "$archive_path"
    else
        info "正在下载预编译静态二进制归档 (v${target_ver}, linux/${arch})..."
        download_github_file "${base_release_url}/${archive_name}" "$archive_path"
    fi

    if [[ -n "${FLOWMASTER_SHA256:-}" ]]; then
        echo "${FLOWMASTER_SHA256}  ${archive_path}" | sha256sum -c - >/dev/null || fail "SHA-256 校验不匹配"
    elif [[ -z "${FLOWMASTER_DOWNLOAD_URL:-}" ]]; then
        download_github_file "${base_release_url}/SHA256SUMS" "$sums_path"
        expected_hash="$(awk -v fn="$archive_name" '$2 == fn || $2 == "*"fn { print $1; exit }' "$sums_path")"
        [[ "$expected_hash" =~ ^[0-9a-fA-F]{64}$ ]] || fail "无法从 SHA256SUMS 解析 ${archive_name} 的有效摘要"
        actual_hash="$(sha256sum "$archive_path" | awk '{print $1}')"
        [[ "${expected_hash,,}" == "${actual_hash,,}" ]] || fail "二进制包 SHA-256 校验未通过，已拒绝安装"
        log "SHA-256 完整性校验通过 (${actual_hash:0:12}...)"
    fi

    tar -xzf "$archive_path" -C "$TMP_DIR"
    [[ -f "${TMP_DIR}/flowmaster" ]] || fail "解压归档后未找到 flowmaster 可执行文件"
    install -m 0755 "${TMP_DIR}/flowmaster" "$target_bin"
}

prepare_binary_dirs_and_env() {
    mkdir -p -- "$CONFIG_DIR" "$BIN_DATA_DIR" "$BACKUP_ROOT"
    chmod 0750 "$CONFIG_DIR" "$BIN_DATA_DIR" "$BACKUP_ROOT"

    if [[ ! -f "$ENV_FILE" ]]; then
        if [[ -f "${LEGACY_APP_DIR}/.env" && ! -L "${LEGACY_APP_DIR}/.env" ]]; then
            log "检测到旧版配置 ${LEGACY_APP_DIR}/.env，已自动迁移至 ${ENV_FILE}"
            cp -- "${LEGACY_APP_DIR}/.env" "$ENV_FILE"
            if ! grep -q '^DATA_DIR=' "$ENV_FILE"; then
                printf '\nDATA_DIR=%s\n' "$BIN_DATA_DIR" >>"$ENV_FILE"
            fi
        else
            cat >"$ENV_FILE" <<EOF
HOST=0.0.0.0
PORT=${FLOWMASTER_PORT:-10089}
DATA_DIR=${BIN_DATA_DIR}
REALTIME_INTERVAL_MS=1000
ALLOW_ANONYMOUS_ADMIN=false
TRUST_PROXY=false
EOF
        fi
    fi

    chown root:"$SERVICE_USER" "$CONFIG_DIR" "$ENV_FILE"
    chmod 0750 "$CONFIG_DIR"
    chmod 0640 "$ENV_FILE"
    chown -R "$SERVICE_USER":"$SERVICE_USER" "$BIN_DATA_DIR"
    chmod 0750 "$BIN_DATA_DIR"

    # 若旧版 /opt/flowmaster 包含 server.js（v1.x Node 版），安全归档避免混淆，绝不误动 Docker /opt/flowmaster/data
    if [[ -f "${LEGACY_APP_DIR}/server.js" && ! -L "$LEGACY_APP_DIR" ]]; then
        local legacy_archive ts
        ts="$(date +%Y%m%d-%H%M%S)"
        legacy_archive="${BACKUP_ROOT}/legacy-node-flowmaster-${ts}"
        log "正在安全归档旧版 Node.js 目录 ${LEGACY_APP_DIR} -> ${legacy_archive}"
        mv -- "$LEGACY_APP_DIR" "$legacy_archive"
    fi
}

write_systemd_unit_and_ctl() {
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
WorkingDirectory=${BIN_DATA_DIR}
EnvironmentFile=-${ENV_FILE}
ExecStart=${BIN_PATH} -env-file ${ENV_FILE}
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=${BIN_DATA_DIR}

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

deploy_or_update_binary() {
    command -v systemctl >/dev/null 2>&1 || fail "当前环境未检测到 systemd，建议使用 Docker 部署模式"

    TMP_DIR="$(mktemp -d /tmp/flowmaster-install.XXXXXX)"
    local target_ver="local"
    if [[ -z "${FLOWMASTER_LOCAL_BIN:-}" ]]; then
        target_ver="$(resolve_target_version)"
    fi
    local current_ver
    current_ver="$(get_installed_binary_version)"

    if [[ -n "$current_ver" ]]; then
        info "检测到已安装的二进制版本: v${current_ver}，准备更新至: v${target_ver}"
    else
        info "准备全新部署二进制版 FlowMaster (${target_ver})"
    fi

    local staged_bin="${TMP_DIR}/flowmaster.bin"
    resolve_binary_artifact "$staged_bin" "$target_ver"
    local actual_bin_ver
    actual_bin_ver="$("$staged_bin" --version | awk '{ gsub(/^v/, "", $NF); print $NF }')"

    ensure_service_user

    local prev_bin_backup=""
    if [[ -f "$BIN_PATH" ]]; then
        prev_bin_backup="${TMP_DIR}/flowmaster.prev"
        cp -p -- "$BIN_PATH" "$prev_bin_backup"
    fi

    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    prepare_binary_dirs_and_env
    install -m 0755 "$staged_bin" "$BIN_PATH"
    write_systemd_unit_and_ctl
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null
    systemctl restart "$SERVICE_NAME"

    local port="10089"
    if [[ -f "$ENV_FILE" ]]; then
        local parsed_port
        parsed_port="$(awk -F= '/^[[:space:]]*PORT=[0-9]+/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' "$ENV_FILE")"
        [[ -n "$parsed_port" ]] && port="$parsed_port"
    fi

    if ! verify_http_health "$port" "$actual_bin_ver"; then
        warn "新版本服务健康检查未通过，正在自动回滚至上一版本..."
        if [[ -n "$prev_bin_backup" && -f "$prev_bin_backup" ]]; then
            install -m 0755 "$prev_bin_backup" "$BIN_PATH"
            systemctl restart "$SERVICE_NAME" || true
        fi
        fail "systemd 服务启动验证失败，请执行 journalctl -u flowmaster.service -n 50 查看原因"
    fi

    log "✅ FlowMaster v${actual_bin_ver} (systemd 二进制模式) 部署/更新完成！"
    log "访问地址: http://服务器IP:${port}"
    log "配置文件: ${ENV_FILE} | 数据目录: ${BIN_DATA_DIR}"
}

do_smart_update() {
    local mode
    mode="$(detect_existing_mode)"
    case "$mode" in
        docker)
            info "自动识别当前部署方式为：Docker 容器模式"
            deploy_or_update_docker
            ;;
        binary)
            info "自动识别当前部署方式为：宿主机二进制 (systemd) 模式"
            deploy_or_update_binary
            ;;
        *)
            warn "未检测到已安装的 FlowMaster 实例，默认为您执行推荐部署..."
            if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
                deploy_or_update_docker
            else
                deploy_or_update_binary
            fi
            ;;
    esac
}

show_status() {
    local d_ver b_ver
    d_ver="$(get_running_docker_version)"
    b_ver="$(get_installed_binary_version)"

    echo "-------------------------------------------------"
    echo " FlowMaster 当前状态概览"
    echo "-------------------------------------------------"
    if [[ -n "$d_ver" ]]; then
        echo " Docker 容器 (${CONTAINER_NAME}): 已安装 (v${d_ver})"
        docker ps -a --filter "name=^/${CONTAINER_NAME}$" --format " 状态: {{.Status}} | 镜像: {{.Image}}"
    else
        echo " Docker 容器 (${CONTAINER_NAME}): 未部署"
    fi
    if [[ -n "$b_ver" ]]; then
        local svc_state="inactive"
        svc_state="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)"
        echo " 二进制服务 (${SERVICE_NAME}): v${b_ver} (${svc_state})"
    else
        echo " 二进制服务 (${SERVICE_NAME}): 未部署"
    fi
    echo "-------------------------------------------------"
}

do_uninstall() {
    if command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
        info "正在停止并移除 Docker 容器 ${CONTAINER_NAME}..."
        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi
    if [[ -f "$SERVICE_FILE" || -x "$BIN_PATH" ]]; then
        info "正在停止并移除 systemd 服务 ${SERVICE_NAME}..."
        systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
        systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
        rm -f -- "$SERVICE_FILE" "$BIN_PATH" "$CTL_PATH"
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    log "✅ FlowMaster 运行实例已卸载。"
    log "数据安全保护：持久化数据目录 (${DOCKER_DATA_DIR}、${BIN_DATA_DIR}) 与系统 /var/lib/vnstat 均完整保留未删除。"
}

show_menu() {
    local existing_mode
    existing_mode="$(detect_existing_mode)"
    echo "========================================================="
    echo "  FlowMaster 轻量流量监控 一键部署与更新脚本"
    if (( IS_CN_ENV == 1 )); then
        echo "  网络环境: 中国大陆加速模式 (代理: ${ACTIVE_GH_PROXY:-自动轮询})"
    else
        echo "  网络环境: 官方直连模式"
    fi
    echo "  当前检测: ${existing_mode}"
    echo "========================================================="
    echo "  1) Docker 部署 / 更新至最新版（推荐，单容器隔离运行）"
    echo "  2) 二进制部署 / 更新至最新版（systemd 守护，极致省内存）"
    echo "  3) 智能一键更新已安装的实例"
    echo "  4) 查看运行状态与当前版本"
    echo "  5) 卸载 FlowMaster（保留历史流量数据库）"
    echo "  0) 退出"
    echo "========================================================="
    read -r -p "请输入数字选择操作 [1]: " choice
    case "${choice:-1}" in
        1) deploy_or_update_docker ;;
        2) deploy_or_update_binary ;;
        3) do_smart_update ;;
        4) show_status ;;
        5) do_uninstall ;;
        0) exit 0 ;;
        *) fail "无效的选项: ${choice}" ;;
    esac
}

main() {
    local action="${1:-}"
    if [[ "$action" == "-h" || "$action" == "--help" || "$action" == "help" ]]; then
        cat <<'EOF'
用法: sudo ./install.sh [命令]

可用命令:
  (无参数)    启动交互式部署与维护菜单
  docker      使用 Docker 部署或平滑更新至最新版本
  binary      使用静态二进制 + systemd 部署或平滑更新至最新版本
  update      自动识别当前部署方式（Docker 或二进制）并更新至最新版本
  status      查看当前安装模式、版本号与运行状态
  uninstall   卸载容器或二进制服务（保留全部流量数据与 /var/lib/vnstat）

可选环境变量:
  FLOWMASTER_VERSION=v2.0.0           指定安装固定版本（默认 latest）
  FLOWMASTER_PORT=10089               指定监听端口（默认 10089）
  FLOWMASTER_CN=1                     1=强制国内加速模式, 0=强制官方直连
  FLOWMASTER_GH_PROXY=https://...     自定义 GitHub 代理加速前缀
  FLOWMASTER_DOCKER_DATA_DIR=/path    自定义 Docker 持久化宿主机目录
EOF
        exit 0
    fi

    require_root
    ensure_base_tools
    acquire_lock

    if [[ "$action" != "status" && "$action" != "uninstall" && "$action" != "--uninstall" ]]; then
        detect_network_and_proxy
    fi

    case "$action" in
        "") show_menu ;;
        docker|--docker) deploy_or_update_docker ;;
        binary|install|--binary|--install) deploy_or_update_binary ;;
        update|upgrade|--update) do_smart_update ;;
        status|--status) show_status ;;
        uninstall|--uninstall) do_uninstall ;;
        *) fail "未知命令: ${action}（执行 ./install.sh --help 查看帮助）" ;;
    esac
}

main "$@"
