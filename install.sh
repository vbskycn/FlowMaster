#!/usr/bin/env bash
# ==============================================================================
# FlowMaster 一键安装、更新、自动放行防火墙与多机集群接入脚本
# - 支持 Docker 部署、静态二进制 (systemd) 部署、join 一键接入主控中心及智能更新
# - 自动识别中国大陆网络环境并测速启用多节点 GitHub 加速代理，防止下载超时出错
# - 默认启用 IPv4 + IPv6 双栈监听，并自动放行 UFW / Firewalld / iptables(含甲骨文规则) 端口
# - 安全红线：任何操作均绝不修改或删除宿主机 /var/lib/vnstat 历史数据
# ==============================================================================

set -Eeuo pipefail

readonly REPO_SLUG="${FLOWMASTER_REPO:-vbskycn/FlowMaster}"
readonly DOCKERHUB_IMAGE="${FLOWMASTER_DOCKER_IMAGE:-zhoujie218/flowmaster}"
readonly GHCR_IMAGE="${FLOWMASTER_GHCR_IMAGE:-ghcr.io/vbskycn/flowmaster}"
readonly CONTAINER_NAME="${FLOWMASTER_CONTAINER_NAME:-flowmaster}"
readonly DOCKER_DATA_DIR="${FLOWMASTER_DOCKER_DATA_DIR:-/opt/flowmaster/data}"

readonly BIN_LINK="/usr/local/bin/flowmaster"
readonly CTL_PATH="/usr/local/bin/flowmaster-ctl"
readonly CONFIG_DIR="/etc/flowmaster"
readonly ENV_FILE="${CONFIG_DIR}/flowmaster.env"
readonly BIN_DATA_DIR="/var/lib/flowmaster"
readonly MANAGED_BIN_DIR="${BIN_DATA_DIR}/bin"
readonly MANAGED_BIN_PATH="${MANAGED_BIN_DIR}/flowmaster"
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

# join 子命令解析参数
JOIN_HUB_URL=""
JOIN_HUB_TOKEN=""
JOIN_NODE_NAME=""
JOIN_NO_WEB="false"
JOIN_USE_DOCKER=0
JOIN_MIRROR_HUB="${FLOWMASTER_MIRROR_HUB:-0}"
NETWORK_PROBED=0

readonly DEFAULT_GH_PROXIES=(
    "https://gh-proxy.com/"
    "https://ghfast.top/"
    "https://ghproxy.net/"
)

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

ensure_network_probed() {
    (( NETWORK_PROBED == 1 )) && return 0
    NETWORK_PROBED=1
    detect_network_and_proxy
}

download_hub_dist_file() {
    local rel_path="$1"
    local dest_file="$2"
    local hub_base="${JOIN_HUB_URL%/}"
    local target_url="${hub_base}/api/v1/cluster/dist/${rel_path}"

    if curl -fL --retry 2 --connect-timeout 6 --max-time 180 \
        -H "Authorization: Bearer ${JOIN_HUB_TOKEN}" \
        -o "$dest_file" "$target_url" 2>/dev/null && [[ -s "$dest_file" ]]; then
        if ! head -c 64 "$dest_file" | grep -qi '<!doctype html\|<html'; then
            return 0
        fi
    fi
    return 1
}

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
            if ! head -c 64 "$dest_file" | grep -qi '<!doctype html\|<html'; then
                return 0
            fi
        fi
    done

    fail "无法下载文件: ${raw_url}（可通过 FLOWMASTER_GH_PROXY 指定可用代理或使用 FLOWMASTER_LOCAL_BIN 离线安装）"
}

resolve_target_version() {
    if [[ -n "${FLOWMASTER_VERSION:-}" && "${FLOWMASTER_VERSION}" != "latest" ]]; then
        echo "${FLOWMASTER_VERSION#v}"
        return 0
    fi

    local ver=""
    if (( JOIN_MIRROR_HUB == 1 )) && [[ -n "$JOIN_HUB_URL" && -n "$JOIN_HUB_TOKEN" ]]; then
        local hub_ver_json=""
        hub_ver_json="$(curl -fsSL --connect-timeout 5 --max-time 10 \
            -H "Authorization: Bearer ${JOIN_HUB_TOKEN}" \
            "${JOIN_HUB_URL%/}/api/v1/cluster/dist/version" 2>/dev/null || true)"
        ver="$(printf '%s' "$hub_ver_json" | sed -n 's/.*"version":[[:space:]]*"v\?\([0-9][0-9.]*\)".*/\1/p' | head -n1)"
        if [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ver"
            return 0
        fi
        warn "从主控机查询分发版本未命中，自动回退 GitHub / 加速源解析..."
    fi

    ensure_network_probed
    if (( IS_CN_ENV == 0 )); then
        local final_url=""
        final_url="$(curl -fsSL -o /dev/null -w '%{url_effective}' --connect-timeout 4 --max-time 8 "https://github.com/${REPO_SLUG}/releases/latest" 2>/dev/null || true)"
        if [[ "$final_url" =~ /releases/tag/v?([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
            ver="${BASH_REMATCH[1]}"
        fi
    fi

    if [[ -z "$ver" && "$IS_CN_ENV" -eq 0 ]]; then
        local api_json=""
        api_json="$(curl -fsSL --connect-timeout 4 --max-time 8 "https://api.github.com/repos/${REPO_SLUG}/releases/latest" 2>/dev/null || true)"
        ver="$(printf '%s' "$api_json" | sed -n 's/.*"tag_name":[[:space:]]*"v\?\([0-9][0-9.]*\)".*/\1/p' | head -n1)"
    fi

    if [[ -z "$ver" ]]; then
        local ver_file="${TMP_DIR}/VERSION.remote"
        download_github_file "https://raw.githubusercontent.com/${REPO_SLUG}/main/VERSION" "$ver_file"
        ver="$(awk -F= '/^APP_VERSION=/ { gsub(/[[:space:]"'"'"'v]/, "", $2); print $2; exit }' "$ver_file")"
    fi

    [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "无法解析最新版本号: ${ver:-空}"
    echo "$ver"
}

# 自动放行本机已启用的防火墙端口（同时覆盖 IPv4 与 IPv6：UFW / Firewalld / Oracle Cloud iptables+ip6tables）
open_firewall_port() {
    local port="$1"
    [[ "${FLOWMASTER_SKIP_FIREWALL:-0}" == "1" ]] && return 0
    [[ "$port" =~ ^[0-9]+$ ]] || return 0

    local opened_any=0

    # 1. UFW（若处于 active 状态，自动同时放行 v4 和 v6）
    if command -v ufw >/dev/null 2>&1; then
        if LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active'; then
            if ufw allow "${port}/tcp" >/dev/null 2>&1; then
                log "已在 UFW 防火墙放行 TCP 端口 ${port} (IPv4/IPv6)"
                opened_any=1
            fi
        fi
    fi

    # 2. Firewalld
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        if firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1; then
            log "已在 Firewalld 防火墙放行 TCP 端口 ${port} (IPv4/IPv6)"
            opened_any=1
        fi
    fi

    # 3. iptables / ip6tables（兼容甲骨文云等默认存在 INPUT REJECT/DROP 拦截规则的系统）
    if (( opened_any == 0 )); then
        local ipt_changed=0
        if command -v iptables >/dev/null 2>&1; then
            local v4_rules=""
            v4_rules="$(iptables -S INPUT 2>/dev/null || true)"
            if printf '%s\n' "$v4_rules" | grep -qE '^-P INPUT DROP|-j (REJECT|DROP)'; then
                if ! printf '%s\n' "$v4_rules" | grep -qE -- "--dport ${port}([[:space:]]|$).*-j ACCEPT"; then
                    if iptables -I INPUT 1 -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
                        log "已在 iptables (IPv4) INPUT 链放行 TCP 端口 ${port}"
                        ipt_changed=1
                    fi
                fi
            fi
        fi

        if command -v ip6tables >/dev/null 2>&1; then
            local v6_rules=""
            v6_rules="$(ip6tables -S INPUT 2>/dev/null || true)"
            if printf '%s\n' "$v6_rules" | grep -qE '^-P INPUT DROP|-j (REJECT|DROP)'; then
                if ! printf '%s\n' "$v6_rules" | grep -qE -- "--dport ${port}([[:space:]]|$).*-j ACCEPT"; then
                    if ip6tables -I INPUT 1 -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
                        log "已在 ip6tables (IPv6) INPUT 链放行 TCP 端口 ${port}"
                        ipt_changed=1
                    fi
                fi
            fi
        fi

        if (( ipt_changed == 1 )) && command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save >/dev/null 2>&1 || true
        fi
    fi
}

print_access_urls() {
    local port="$1"
    local v4="" v6=""
    v4="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' || true)"
    v6="$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' || true)"
    if [[ -n "$v4" ]]; then
        log "IPv4 访问地址: http://${v4}:${port}"
    else
        log "IPv4 访问地址: http://服务器IPv4:${port}"
    fi
    if [[ -n "$v6" && "$v6" != fe80* && "$v6" != "::1" ]]; then
        log "IPv6 访问地址: http://[${v6}]:${port}"
    fi
}

get_installed_binary_version() {
    local bin_candidate=""
    for bin_candidate in "$MANAGED_BIN_PATH" "$BIN_LINK"; do
        if [[ -x "$bin_candidate" ]]; then
            local out ver
            out="$("$bin_candidate" --version 2>/dev/null || true)"
            ver="$(printf '%s' "$out" | awk '{ gsub(/^v/, "", $NF); print $NF }')"
            if [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo "$ver"
                return 0
            fi
        fi
    done
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
    if [[ -f "$SERVICE_FILE" || -x "$MANAGED_BIN_PATH" || -x "$BIN_LINK" || -d "$LEGACY_APP_DIR" || -f /root/.pm2/dump.pm2 ]]; then
        echo "binary"
        return 0
    fi
    echo "none"
}

filter_pm2_dump_offline() {
    local dump_file="$1"
    [[ -f "$dump_file" && ! -L "$dump_file" ]] || { echo "0 0"; return 0; }

    if command -v python3 >/dev/null 2>&1; then
        python3 - "$dump_file" <<'PY'
import json, os, sys
p = sys.argv[1]
try:
    with open(p, "r", encoding="utf-8") as f:
        arr = json.load(f)
    if not isinstance(arr, list):
        print("0 0")
        sys.exit(0)
except Exception:
    print("0 0")
    sys.exit(0)

kept = []
removed = 0
for item in arr:
    name = str(item.get("name", ""))
    exec_path = str(item.get("pm_exec_path", ""))
    if name == "flowmaster" or exec_path.endswith("/flowmaster/server.js"):
        removed += 1
    else:
        kept.append(item)

if removed > 0:
    tmp = p + ".flowmaster.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(kept, f)
    os.replace(tmp, p)
print(f"{removed} {len(kept)}")
PY
        return 0
    fi

    if command -v node >/dev/null 2>&1; then
        node - "$dump_file" <<'JS'
const fs = require('fs');
const p = process.argv[2];
try {
  const arr = JSON.parse(fs.readFileSync(p, 'utf8'));
  if (!Array.isArray(arr)) { console.log('0 0'); process.exit(0); }
  const kept = [];
  let removed = 0;
  for (const item of arr) {
    const name = String((item && item.name) || '');
    const execPath = String((item && item.pm_exec_path) || '');
    if (name === 'flowmaster' || execPath.endsWith('/flowmaster/server.js')) removed++;
    else kept.push(item);
  }
  if (removed > 0) {
    const tmp = p + '.flowmaster.tmp';
    fs.writeFileSync(tmp, JSON.stringify(kept));
    fs.renameSync(tmp, p);
  }
  console.log(`${removed} ${kept.length}`);
} catch (_) {
  console.log('0 0');
}
JS
        return 0
    fi

    echo "0 0"
}

retire_legacy_node_and_pm2() {
    local pm2_home="/root/.pm2"
    local dump_file="${pm2_home}/dump.pm2"
    local bak_file="${pm2_home}/dump.pm2.bak"
    local has_legacy_node=0
    local pid cmdline

    for proc_dir in /proc/[0-9]*; do
        [[ -r "${proc_dir}/cmdline" ]] || continue
        pid="${proc_dir#/proc/}"
        [[ "$pid" == "$$" ]] && continue
        cmdline="$(tr '\0' ' ' <"${proc_dir}/cmdline" 2>/dev/null || true)"
        if [[ "$cmdline" == *"node"* && "$cmdline" == *"/flowmaster/server.js"* ]]; then
            has_legacy_node=1
            break
        fi
    done

    if [[ -f "$dump_file" ]] && grep -q '"flowmaster"\|/flowmaster/server\.js' "$dump_file" 2>/dev/null; then
        has_legacy_node=1
    fi

    (( has_legacy_node == 1 )) || return 0

    info "检测到旧版 Node.js/PM2 FlowMaster 实例，正在安全迁移并释放端口..."
    mkdir -p -- "$BACKUP_ROOT"
    chmod 0750 "$BACKUP_ROOT"

    local pm2_units=()
    if command -v systemctl >/dev/null 2>&1; then
        while IFS= read -r u; do
            [[ -n "$u" ]] && pm2_units+=("$u")
        done < <(systemctl list-units --type=service --state=active --no-legend 'pm2-*.service' 2>/dev/null | awk '{print $1}')
    fi

    local removed_cnt=0 remaining_cnt=0
    if [[ -f "$dump_file" ]]; then
        local pm2_bak_dir
        pm2_bak_dir="${BACKUP_ROOT}/pm2-migration-$(date +%Y%m%d-%H%M%S)"
        mkdir -p -- "$pm2_bak_dir"
        chmod 0700 "$pm2_bak_dir"
        cp -p -- "$dump_file" "${pm2_bak_dir}/dump.pm2" 2>/dev/null || true
        [[ -f "$bak_file" ]] && cp -p -- "$bak_file" "${pm2_bak_dir}/dump.pm2.bak" 2>/dev/null || true

        read -r removed_cnt remaining_cnt < <(filter_pm2_dump_offline "$dump_file")
        [[ -f "$bak_file" ]] && filter_pm2_dump_offline "$bak_file" >/dev/null || true
    fi

    local unit dropin_dir
    if (( removed_cnt > 0 )); then
        for unit in "${pm2_units[@]}"; do
            dropin_dir="/run/systemd/system/${unit}.d"
            mkdir -p -- "$dropin_dir"
            printf '[Service]\nExecStop=\n' >"${dropin_dir}/99-flowmaster-stop.conf"
            systemctl daemon-reload >/dev/null 2>&1 || true
            if command -v timeout >/dev/null 2>&1; then
                timeout 15 systemctl stop "$unit" >/dev/null 2>&1 || true
            else
                systemctl stop "$unit" >/dev/null 2>&1 || true
            fi
            rm -rf -- "$dropin_dir"
            systemctl daemon-reload >/dev/null 2>&1 || true

            if (( remaining_cnt > 0 )); then
                info "正在恢复 PM2 中的其余 ${remaining_cnt} 个应用 (${unit})..."
                systemctl start "$unit" >/dev/null 2>&1 || true
            else
                info "PM2 清单中已无其他应用，已停用空载的 ${unit}"
                systemctl disable "$unit" >/dev/null 2>&1 || true
            fi
        done
    fi

    for proc_dir in /proc/[0-9]*; do
        [[ -r "${proc_dir}/cmdline" ]] || continue
        pid="${proc_dir#/proc/}"
        [[ "$pid" == "$$" ]] && continue
        cmdline="$(tr '\0' ' ' <"${proc_dir}/cmdline" 2>/dev/null || true)"
        if [[ "$cmdline" == *"node"* && "$cmdline" == *"/flowmaster/server.js"* ]]; then
            kill -TERM "$pid" 2>/dev/null || true
        fi
    done

    for _ in {1..15}; do
        local still_alive=0
        for proc_dir in /proc/[0-9]*; do
            [[ -r "${proc_dir}/cmdline" ]] || continue
            cmdline="$(tr '\0' ' ' <"${proc_dir}/cmdline" 2>/dev/null || true)"
            if [[ "$cmdline" == *"node"* && "$cmdline" == *"/flowmaster/server.js"* ]]; then
                still_alive=1
                pid="${proc_dir#/proc/}"
                kill -KILL "$pid" 2>/dev/null || true
            fi
        done
        (( still_alive == 0 )) && break
        sleep 0.2
    done

    log "旧版 Node.js/PM2 FlowMaster 实例已安全下线"
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

upsert_env_key() {
    local file="$1"
    local key="$2"
    local val="$3"
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        local tmp_env="${file}.tmp.$$"
        awk -v k="$key" -v v="$val" 'BEGIN{FS=OFS="="} $1==k {print k"="v; next} {print}' "$file" >"$tmp_env"
        mv -- "$tmp_env" "$file"
    else
        printf '%s=%s\n' "$key" "$val" >>"$file"
    fi
}

# ==============================================================================
# 模式一：Docker 部署与平滑更新
# ==============================================================================
pull_flowmaster_image() {
    local version="$1"
    local target_tag="${DOCKERHUB_IMAGE}:${version}"
    local candidates=()

    if (( IS_CN_ENV == 1 )); then
        candidates+=("${GHCR_IMAGE}:${version}")
        candidates+=("${DOCKERHUB_IMAGE}:${version}")
        local m
        for m in "${DEFAULT_DOCKER_MIRRORS[@]}"; do
            candidates+=("${m}/${DOCKERHUB_IMAGE}:${version}")
        done
    else
        candidates+=("${DOCKERHUB_IMAGE}:${version}")
        candidates+=("${GHCR_IMAGE}:${version}")
    fi

    local candidate pull_ok
    for candidate in "${candidates[@]}"; do
        info "尝试拉取容器镜像 (单源超时上限 60s): ${candidate}"
        pull_ok=0
        if command -v timeout >/dev/null 2>&1; then
            timeout 60 docker pull "$candidate" && pull_ok=1 || pull_ok=0
        else
            docker pull "$candidate" && pull_ok=1 || pull_ok=0
        fi
        if (( pull_ok == 1 )); then
            if [[ "$candidate" != "$target_tag" ]]; then
                docker tag "$candidate" "$target_tag"
            fi
            docker tag "$target_tag" "${DOCKERHUB_IMAGE}:latest"
            return 0
        fi
        warn "从 ${candidate} 拉取超时或未成功，自动切换下一个镜像源..."
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
        info "准备通过 Docker 部署 FlowMaster v${target_ver}"
    fi

    local port="${FLOWMASTER_PORT:-10089}"
    local data_dir="$DOCKER_DATA_DIR"
    local prev_image_id=""
    local hub_url="${JOIN_HUB_URL:-}"
    local hub_tok="${JOIN_HUB_TOKEN:-}"
    local node_nm="${JOIN_NODE_NAME:-}"
    local dis_web="${JOIN_NO_WEB:-false}"

    if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
        prev_image_id="$(docker inspect --format '{{.Image}}' "$CONTAINER_NAME" 2>/dev/null || true)"
        local existing_envs
        existing_envs="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)"
        if [[ -z "${FLOWMASTER_PORT:-}" ]]; then
            local ep
            ep="$(printf '%s\n' "$existing_envs" | awk -F= '$1=="PORT"{print $2; exit}')"
            port="${ep:-10089}"
        fi
        [[ -n "$hub_url" ]] || hub_url="$(printf '%s\n' "$existing_envs" | awk -F= '$1=="HUB_URL"{sub(/^[^=]*=/, ""); print; exit}')"
        [[ -n "$hub_tok" ]] || hub_tok="$(printf '%s\n' "$existing_envs" | awk -F= '$1=="HUB_TOKEN"{sub(/^[^=]*=/, ""); print; exit}')"
        [[ -n "$node_nm" ]] || node_nm="$(printf '%s\n' "$existing_envs" | awk -F= '$1=="NODE_NAME"{sub(/^[^=]*=/, ""); print; exit}')"

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

    local cluster_args=()
    [[ -n "$hub_url" ]] && cluster_args+=(-e "HUB_URL=${hub_url}")
    [[ -n "$hub_tok" ]] && cluster_args+=(-e "HUB_TOKEN=${hub_tok}")
    [[ -n "$node_nm" ]] && cluster_args+=(-e "NODE_NAME=${node_nm}")
    [[ "$dis_web" == "true" ]] && cluster_args+=(-e "DISABLE_WEB=true")

    if [[ "$CONTAINER_NAME" == "flowmaster" ]]; then
        retire_legacy_node_and_pm2
        if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null || systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
            warn "检测到宿主机 systemd 服务 ${SERVICE_NAME}，已停止该服务以交由 Docker 容器接管端口"
            systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
            systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
        fi
    fi

    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

    docker run -d \
        --name "$CONTAINER_NAME" \
        --restart unless-stopped \
        --network host \
        -e TZ="${TZ:-Asia/Shanghai}" \
        -e HOST="${FLOWMASTER_HOST:-::}" \
        -e PORT="$port" \
        -e DATA_DIR=/data \
        -v "${data_dir}:/data" \
        "${vnstat_args[@]}" \
        "${cluster_args[@]}" \
        "${DOCKERHUB_IMAGE}:${target_ver}" >/dev/null

    if [[ "$dis_web" != "true" ]]; then
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
                    -e HOST="${FLOWMASTER_HOST:-::}" \
                    -e PORT="$port" \
                    -e DATA_DIR=/data \
                    -v "${data_dir}:/data" \
                    "${vnstat_args[@]}" \
                    "${cluster_args[@]}" \
                    "$prev_image_id" >/dev/null || true
            fi
            fail "Docker 容器启动验证失败"
        fi
        open_firewall_port "$port"
        print_access_urls "$port"
    fi

    log "✅ FlowMaster v${target_ver} (Docker 模式) 部署/更新完成！"
    [[ -n "$hub_url" ]] && log "已连接上报主控中心: ${hub_url}"
    log "持久化目录: ${data_dir}（宿主机 /var/lib/vnstat 保持只读未修改）"
}

# ==============================================================================
# 模式二：二进制 + systemd 部署与平滑更新（支持远程一键自升级）
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
        ensure_network_probed
        download_github_file "$FLOWMASTER_DOWNLOAD_URL" "$archive_path"
    elif (( JOIN_MIRROR_HUB == 1 )) && [[ -n "$JOIN_HUB_URL" && -n "$JOIN_HUB_TOKEN" ]]; then
        info "正在从主控机 (${JOIN_HUB_URL%/}) 直接拉取预编译静态二进制包 (v${target_ver}, linux/${arch})..."
        if download_hub_dist_file "v${target_ver}/SHA256SUMS" "$sums_path" && \
           download_hub_dist_file "v${target_ver}/${archive_name}" "$archive_path"; then
            expected_hash="$(awk -v fn="$archive_name" '$2 == fn || $2 == "*"fn { print $1; exit }' "$sums_path")"
            actual_hash="$(sha256sum "$archive_path" | awk '{print $1}')"
            if [[ "$expected_hash" =~ ^[0-9a-fA-F]{64}$ && "${expected_hash,,}" == "${actual_hash,,}" ]]; then
                log "主控分发包 SHA-256 完整性校验通过 (${actual_hash:0:12}...)"
                tar -xzf "$archive_path" -C "$TMP_DIR"
                [[ -f "${TMP_DIR}/flowmaster" ]] || fail "解压归档后未找到 flowmaster 可执行文件"
                install -m 0755 "${TMP_DIR}/flowmaster" "$target_bin"
                return 0
            fi
        fi
        warn "从主控机拉取安装包未成功，自动回退 GitHub / 加速代理源..."
        ensure_network_probed
        info "正在下载预编译静态二进制归档 (v${target_ver}, linux/${arch})..."
        download_github_file "${base_release_url}/${archive_name}" "$archive_path"
    else
        ensure_network_probed
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
    mkdir -p -- "$CONFIG_DIR" "$BIN_DATA_DIR" "$MANAGED_BIN_DIR" "$BACKUP_ROOT"
    chmod 0750 "$CONFIG_DIR" "$BIN_DATA_DIR" "$MANAGED_BIN_DIR" "$BACKUP_ROOT"

    if [[ ! -f "$ENV_FILE" ]]; then
        if [[ -f "${LEGACY_APP_DIR}/.env" && ! -L "${LEGACY_APP_DIR}/.env" ]]; then
            log "检测到旧版配置 ${LEGACY_APP_DIR}/.env，已自动迁移至 ${ENV_FILE}"
            cp -- "${LEGACY_APP_DIR}/.env" "$ENV_FILE"
            upsert_env_key "$ENV_FILE" "DATA_DIR" "$BIN_DATA_DIR"
        else
            cat >"$ENV_FILE" <<EOF
HOST=::
PORT=${FLOWMASTER_PORT:-10089}
DATA_DIR=${BIN_DATA_DIR}
REALTIME_INTERVAL_MS=1000
ALLOW_ANONYMOUS_ADMIN=false
TRUST_PROXY=false
EOF
        fi
    fi

    # 兼容之前写为 HOST=0.0.0.0 的默认配置平滑升级至双栈 HOST=::
    if grep -q '^HOST=0\.0\.0\.0$' "$ENV_FILE" 2>/dev/null && [[ -z "${FLOWMASTER_HOST:-}" ]]; then
        upsert_env_key "$ENV_FILE" "HOST" "::"
    fi
    [[ -n "${FLOWMASTER_PORT:-}" ]] && upsert_env_key "$ENV_FILE" "PORT" "$FLOWMASTER_PORT"

    if [[ -n "$JOIN_HUB_URL" ]]; then
        upsert_env_key "$ENV_FILE" "HUB_URL" "$JOIN_HUB_URL"
        upsert_env_key "$ENV_FILE" "HUB_TOKEN" "$JOIN_HUB_TOKEN"
        [[ -n "$JOIN_NODE_NAME" ]] && upsert_env_key "$ENV_FILE" "NODE_NAME" "$JOIN_NODE_NAME"
        upsert_env_key "$ENV_FILE" "DISABLE_WEB" "$JOIN_NO_WEB"
    fi

    chown root:"$SERVICE_USER" "$CONFIG_DIR" "$ENV_FILE"
    chmod 0750 "$CONFIG_DIR"
    chmod 0640 "$ENV_FILE"
    chown -R "$SERVICE_USER":"$SERVICE_USER" "$BIN_DATA_DIR"
    chmod 0750 "$BIN_DATA_DIR" "$MANAGED_BIN_DIR"

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

    # Restart=always 确保通过主控网页触发远程原子自升级 (exit 0) 后，systemd 自动拉起新版进程
    cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=FlowMaster Lightweight Network Traffic Monitor & Agent
After=network-online.target vnstat.service
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
${supp_line}
WorkingDirectory=${BIN_DATA_DIR}
EnvironmentFile=-${ENV_FILE}
ExecStart=${MANAGED_BIN_PATH} -env-file ${ENV_FILE}
Restart=always
RestartSec=2
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=${BIN_DATA_DIR}

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$SERVICE_FILE"

    ln -sfn "$MANAGED_BIN_PATH" "$BIN_LINK"

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
        info "检测到已安装版本: v${current_ver}，准备更新至: v${target_ver}"
    else
        info "准备部署二进制版 FlowMaster (${target_ver})"
    fi

    local staged_bin="${TMP_DIR}/flowmaster.bin"
    resolve_binary_artifact "$staged_bin" "$target_ver"
    local actual_bin_ver
    actual_bin_ver="$("$staged_bin" --version | awk '{ gsub(/^v/, "", $NF); print $NF }')"

    ensure_service_user

    local prev_bin_backup=""
    if [[ -x "$MANAGED_BIN_PATH" ]] && "$MANAGED_BIN_PATH" --version 2>/dev/null | grep -q '^FlowMaster v[0-9]'; then
        prev_bin_backup="${TMP_DIR}/flowmaster.prev"
        cp -p -- "$MANAGED_BIN_PATH" "$prev_bin_backup"
    elif [[ -f "$BIN_LINK" && ! -L "$BIN_LINK" ]] && "$BIN_LINK" --version 2>/dev/null | grep -q '^FlowMaster v[0-9]'; then
        prev_bin_backup="${TMP_DIR}/flowmaster.prev"
        cp -p -- "$BIN_LINK" "$prev_bin_backup"
    fi

    retire_legacy_node_and_pm2
    if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
        warn "检测到同名 Docker 容器 ${CONTAINER_NAME} 正在运行，已停止该容器以交由 systemd 二进制服务接管端口"
        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi

    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    prepare_binary_dirs_and_env
    install -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0755 "$staged_bin" "$MANAGED_BIN_PATH"
    write_systemd_unit_and_ctl
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null
    systemctl restart "$SERVICE_NAME"

    local port="10089"
    local disable_web="false"
    if [[ -f "$ENV_FILE" ]]; then
        local parsed_port parsed_dis
        parsed_port="$(awk -F= '/^[[:space:]]*PORT=[0-9]+/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' "$ENV_FILE")"
        parsed_dis="$(awk -F= '/^[[:space:]]*DISABLE_WEB=/ { gsub(/[[:space:]]/, "", $2); print tolower($2); exit }' "$ENV_FILE")"
        [[ -n "$parsed_port" ]] && port="$parsed_port"
        [[ -n "$parsed_dis" ]] && disable_web="$parsed_dis"
    fi

    if [[ "$disable_web" == "true" ]]; then
        sleep 2
        if ! systemctl is-active --quiet "$SERVICE_NAME"; then
            fail "纯探针模式服务启动失败，请执行 journalctl -u flowmaster.service -n 50 查看原因"
        fi
    else
        if ! verify_http_health "$port" "$actual_bin_ver"; then
            warn "新版本服务健康检查未通过，正在处理回滚..."
            if [[ -n "$prev_bin_backup" && -f "$prev_bin_backup" ]]; then
                install -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0755 "$prev_bin_backup" "$MANAGED_BIN_PATH"
                systemctl restart "$SERVICE_NAME" || true
            else
                systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
                systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
                rm -f -- "$SERVICE_FILE" "$BIN_LINK"
                systemctl daemon-reload >/dev/null 2>&1 || true
            fi
            fail "systemd 服务启动验证失败，请执行 journalctl -u flowmaster.service -n 50 查看原因"
        fi
        open_firewall_port "$port"
        print_access_urls "$port"
    fi

    log "✅ FlowMaster v${actual_bin_ver} (systemd 二进制模式，支持主控网页一键远程升级) 部署完成！"
    [[ -n "$JOIN_HUB_URL" ]] && log "已连接上报主控中心: ${JOIN_HUB_URL}"
    log "配置文件: ${ENV_FILE} | 数据目录: ${BIN_DATA_DIR}"
}

parse_and_run_join() {
    shift || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --hub|--server)
                JOIN_HUB_URL="${2:-}"
                shift 2
                ;;
            --token)
                JOIN_HUB_TOKEN="${2:-}"
                shift 2
                ;;
            --name)
                JOIN_NODE_NAME="${2:-}"
                shift 2
                ;;
            --port)
                export FLOWMASTER_PORT="${2:-10089}"
                shift 2
                ;;
            --no-web)
                JOIN_NO_WEB="true"
                shift
                ;;
            --mirror-hub)
                JOIN_MIRROR_HUB=1
                shift
                ;;
            --github|--no-mirror-hub)
                JOIN_MIRROR_HUB=0
                shift
                ;;
            --docker)
                JOIN_USE_DOCKER=1
                shift
                ;;
            *)
                fail "未知的 join 参数: $1"
                ;;
        esac
    done

    [[ -n "$JOIN_HUB_URL" && -n "$JOIN_HUB_TOKEN" ]] || fail "join 模式必须同时提供 --hub <主控地址> 与 --token <节点密钥>"
    if (( JOIN_USE_DOCKER == 1 )); then
        deploy_or_update_docker
    else
        deploy_or_update_binary
    fi
}

interactive_join_prompt() {
    read -r -p "请输入主控中心地址 (例如 http://1.2.3.4:10089 或 https://hub.example.com): " JOIN_HUB_URL
    read -r -p "请输入主控生成的节点 Token (fm_...): " JOIN_HUB_TOKEN
    read -r -p "请输入本机展示名称 (留空自动使用主机名): " JOIN_NODE_NAME
    local mirror_ans=""
    read -r -p "是否优先由主控机直接分发安装包（免连 GitHub）[Y/n]: " mirror_ans
    if [[ "${mirror_ans,,}" == "n" || "${mirror_ans,,}" == "no" ]]; then
        JOIN_MIRROR_HUB=0
    else
        JOIN_MIRROR_HUB=1
    fi
    [[ -n "$JOIN_HUB_URL" && -n "$JOIN_HUB_TOKEN" ]] || fail "主控地址与节点 Token 不能为空"
    deploy_or_update_binary
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
    if [[ -f "$SERVICE_FILE" || -L "$BIN_LINK" || -f "$BIN_LINK" || -x "$MANAGED_BIN_PATH" ]]; then
        info "正在停止并移除 systemd 服务 ${SERVICE_NAME}..."
        systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
        systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
        rm -f -- "$SERVICE_FILE" "$BIN_LINK" "$CTL_PATH" "$MANAGED_BIN_PATH"
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    log "✅ FlowMaster 运行实例已卸载。"
    log "数据安全保护：持久化数据目录 (${DOCKER_DATA_DIR}、${BIN_DATA_DIR}) 与系统 /var/lib/vnstat 均完整保留未删除。"
}

show_menu() {
    local existing_mode
    existing_mode="$(detect_existing_mode)"
    echo "========================================================="
    echo "  FlowMaster 轻量流量监控与多机中枢 一键部署脚本"
    if (( IS_CN_ENV == 1 )); then
        echo "  网络环境: 中国大陆加速模式 (代理: ${ACTIVE_GH_PROXY:-自动轮询})"
    else
        echo "  网络环境: 官方直连模式"
    fi
    echo "  当前检测: ${existing_mode}"
    echo "========================================================="
    echo "  1) Docker 部署 / 更新至最新版（适合单机或主控中枢）"
    echo "  2) 二进制部署 / 更新至最新版（systemd 守护，支持远程自升级）"
    echo "  3) 作为被控节点接入主控中心（同时开启本机 10089 面板并放行防火墙）"
    echo "  4) 智能一键更新已安装的实例"
    echo "  5) 查看运行状态与当前版本"
    echo "  6) 卸载 FlowMaster（保留历史流量数据库）"
    echo "  0) 退出"
    echo "========================================================="
    read -r -p "请输入数字选择操作 [1]: " choice
    case "${choice:-1}" in
        1) deploy_or_update_docker ;;
        2) deploy_or_update_binary ;;
        3) interactive_join_prompt ;;
        4) do_smart_update ;;
        5) show_status ;;
        6) do_uninstall ;;
        0) exit 0 ;;
        *) fail "无效的选项: ${choice}" ;;
    esac
}

main() {
    local action="${1:-}"
    if [[ "$action" == "-h" || "$action" == "--help" || "$action" == "help" ]]; then
        cat <<'EOF'
用法: sudo ./install.sh [命令] [选项]

可用命令:
  (无参数)    启动交互式部署与维护菜单
  docker      使用 Docker 部署或平滑更新至最新版本（自动放行防火墙端口）
  binary      使用静态二进制 + systemd 部署或平滑更新至最新版本（自动放行防火墙端口）
    join        作为被控节点一键安装并接入主控中心:
                sudo ./install.sh join --hub 'https://主控地址' --token 'fm_...' [--mirror-hub] [--name '节点名'] [--no-web]
    update      自动识别当前部署方式（Docker 或二进制）并更新至最新版本
    status      查看当前安装模式、版本号与运行状态
    uninstall   卸载容器或二进制服务（保留全部流量数据与 /var/lib/vnstat）

可选环境变量:
    FLOWMASTER_VERSION=v2.2.0           指定安装固定版本（默认 latest）
    FLOWMASTER_PORT=10089               指定监听端口（默认 10089，IPv4/IPv6 双栈）
    FLOWMASTER_MIRROR_HUB=1             join 时优先从主控机直接拉取安装包（免连 GitHub）
    FLOWMASTER_SKIP_FIREWALL=1          跳过自动放行系统防火墙端口
    FLOWMASTER_CN=1                     1=强制国内加速模式, 0=强制官方直连
    FLOWMASTER_GH_PROXY=https://...     自定义 GitHub 代理加速前缀
EOF
        exit 0
    fi

    require_root
    ensure_base_tools
    acquire_lock

    local skip_initial_probe=0
    if [[ "$action" == "status" || "$action" == "--status" || "$action" == "uninstall" || "$action" == "--uninstall" ]]; then
        skip_initial_probe=1
    elif [[ "$action" == "join" || "$action" == "--join" ]]; then
        local arg
        for arg in "$@"; do
            [[ "$arg" == "--mirror-hub" ]] && skip_initial_probe=1
            [[ "$arg" == "--docker" ]] && skip_initial_probe=0
        done
    fi

    if (( skip_initial_probe == 0 )); then
        ensure_network_probed
    fi

    case "$action" in
        "") show_menu ;;
        docker|--docker) deploy_or_update_docker ;;
        binary|install|--binary|--install) deploy_or_update_binary ;;
        join|--join) parse_and_run_join "$@" ;;
        update|upgrade|--update) do_smart_update ;;
        status|--status) show_status ;;
        uninstall|--uninstall) do_uninstall ;;
        *) fail "未知命令: ${action}（执行 ./install.sh --help 查看帮助）" ;;
    esac
}

main "$@"
