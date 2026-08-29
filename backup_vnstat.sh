#!/usr/bin/env bash

set -Eeuo pipefail

readonly BACKUP_DIR="${FLOWMASTER_BACKUP_DIR:-/var/backups/flowmaster/vnstat}"
readonly VNSTAT_DATA_DIR="${VNSTAT_DATA_DIR:-/var/lib/vnstat}"
readonly LOG_FILE="${FLOWMASTER_BACKUP_LOG:-/var/log/flowmaster-vnstat-backup.log}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

VNSTAT_WAS_ACTIVE=false
FLOWMASTER_WAS_ACTIVE=false
SERVICES_STOPPED=false

log() { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}$*${NC}"; }
fail() { echo -e "${RED}$*${NC}" >&2; return 1; }

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || { echo -e "${RED}请使用 root 权限运行此脚本${NC}" >&2; exit 1; }
}

validate_paths() {
    local resolved_data_dir
    resolved_data_dir="$(realpath -m -- "$VNSTAT_DATA_DIR")"
    [[ "$resolved_data_dir" == /* ]] || { fail "vnstat 数据目录必须是绝对路径"; return 1; }
    case "$resolved_data_dir" in
        /|/var|/var/lib|/tmp|/opt|/root|/home) fail "拒绝对过宽目录执行数据操作: $resolved_data_dir"; return 1 ;;
    esac
    (( ${#resolved_data_dir} >= 12 )) || { fail "vnstat 数据目录过短，拒绝执行: $resolved_data_dir"; return 1; }
}

record_log() {
    mkdir -p "$(dirname "$LOG_FILE")"
    printf '%s %s\n' "$(date --iso-8601=seconds)" "$*" >>"$LOG_FILE"
}

stop_services() {
    [[ "$SERVICES_STOPPED" == false ]] || return 0
    VNSTAT_WAS_ACTIVE=false
    FLOWMASTER_WAS_ACTIVE=false
    if systemctl is-active --quiet vnstat 2>/dev/null; then
        VNSTAT_WAS_ACTIVE=true
    fi
    if systemctl is-active --quiet flowmaster.service 2>/dev/null; then
        FLOWMASTER_WAS_ACTIVE=true
    fi

    # 先标记为已进入停服阶段，任何后续失败都由 EXIT trap 恢复原状态。
    SERVICES_STOPPED=true
    local stop_failed=false
    if [[ "$FLOWMASTER_WAS_ACTIVE" == true ]] && ! systemctl stop flowmaster.service; then
        warn "停止 flowmaster.service 失败"
        stop_failed=true
    fi
    if [[ "$stop_failed" == false && "$VNSTAT_WAS_ACTIVE" == true ]] && ! systemctl stop vnstat; then
        warn "停止 vnstat 失败"
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
    if [[ "$VNSTAT_WAS_ACTIVE" == true ]] && ! systemctl start vnstat; then
        warn "恢复 vnstat 失败"
        restore_failed=true
    fi
    if [[ "$FLOWMASTER_WAS_ACTIVE" == true ]]; then
        if [[ "$restore_failed" == true ]]; then
            warn "vnstat 未恢复，暂不启动 flowmaster.service"
        elif ! systemctl start flowmaster.service; then
            warn "恢复 flowmaster.service 失败"
            restore_failed=true
        fi
    fi
    [[ "$restore_failed" == false ]] || return 1
    SERVICES_STOPPED=false
    return 0
}
trap restore_services EXIT

create_archive() {
    local archive="$1"
    local temporary_dir
    temporary_dir="$(mktemp -d "$BACKUP_DIR/.snapshot.XXXXXX")"
    mkdir -p "$temporary_dir/data"

    cp -a "$VNSTAT_DATA_DIR/." "$temporary_dir/data/"
    vnstat --json >"$temporary_dir/vnstat.json" 2>/dev/null || true
    {
        printf 'created_at=%s\n' "$(date --iso-8601=seconds)"
        printf 'hostname=%s\n' "$(hostname)"
        printf 'vnstat_version=%s\n' "$(vnstat --version 2>/dev/null | head -n 1 || echo unknown)"
    } >"$temporary_dir/metadata.txt"
    (
        cd "$temporary_dir"
        find data -type f -print0 | sort -z | xargs -0 -r sha256sum >checksums.sha256
        tar -czf "${archive}.tmp" data metadata.txt vnstat.json checksums.sha256
    )
    mv "${archive}.tmp" "$archive"
    rm -rf -- "$temporary_dir"
    tar -tzf "$archive" >/dev/null
}

backup_data() {
    [[ -d "$VNSTAT_DATA_DIR" ]] || { fail "vnstat 数据目录不存在: $VNSTAT_DATA_DIR"; return 1; }
    mkdir -p "$BACKUP_DIR"
    local archive
    archive="$BACKUP_DIR/vnstat-$(date +%Y%m%d-%H%M%S).tar.gz"

    log "正在创建一致性备份..."
    stop_services
    create_archive "$archive"
    if ! restore_services; then
        fail "备份已生成，但未能完整恢复原服务状态"
        return 1
    fi

    local archive_hash
    archive_hash="$(sha256sum "$archive" | awk '{print $1}')"
    printf '%s  %s\n' "$archive_hash" "$(basename "$archive")" >"${archive}.sha256"
    record_log "backup_created archive=$archive sha256=$archive_hash"
    log "备份完成: $archive"
    echo -e "${BLUE}SHA-256: $archive_hash${NC}"
}

list_archive_paths() {
    find "$BACKUP_DIR" -maxdepth 1 -type f -name 'vnstat-*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-
}

list_backups() {
    mkdir -p "$BACKUP_DIR"
    local index=0
    while IFS= read -r archive; do
        [[ -n "$archive" ]] || continue
        index=$((index + 1))
        printf '%-4s %-38s %-10s %s\n' "$index" "$(basename "$archive")" "$(du -h "$archive" | cut -f1)" "$(stat -c '%y' "$archive" | cut -d'.' -f1)"
    done < <(list_archive_paths)
    (( index > 0 )) || warn "没有找到备份"
}

restore_data() {
    mkdir -p "$BACKUP_DIR"
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

    if [[ -f "${selected}.sha256" ]]; then
        (cd "$BACKUP_DIR" && sha256sum --check --status "$(basename "${selected}.sha256")") || { fail "备份归档校验失败"; return 1; }
    fi

    local extracted rollback_dir
    extracted="$(mktemp -d "$BACKUP_DIR/.restore.XXXXXX")"
    tar -xzf "$selected" -C "$extracted"
    (
        cd "$extracted"
        sha256sum --check --status checksums.sha256
    ) || { rm -rf -- "$extracted"; fail "备份内部文件校验失败"; return 1; }

    stop_services
    rollback_dir="${VNSTAT_DATA_DIR}.rollback.$(date +%Y%m%d-%H%M%S)"
    if [[ -d "$VNSTAT_DATA_DIR" ]]; then
        mv "$VNSTAT_DATA_DIR" "$rollback_dir"
    fi
    mkdir -p "$VNSTAT_DATA_DIR"

    if ! cp -a "$extracted/data/." "$VNSTAT_DATA_DIR/"; then
        rm -rf -- "$VNSTAT_DATA_DIR"
        [[ -d "$rollback_dir" ]] && mv "$rollback_dir" "$VNSTAT_DATA_DIR"
        rm -rf -- "$extracted"
        restore_services || warn "回滚数据后未能完整恢复原服务状态"
        fail "复制恢复数据失败，已回滚"
        return 1
    fi

    if ! vnstat --iflist >/dev/null 2>&1; then
        rm -rf -- "$VNSTAT_DATA_DIR"
        [[ -d "$rollback_dir" ]] && mv "$rollback_dir" "$VNSTAT_DATA_DIR"
        rm -rf -- "$extracted"
        restore_services || warn "回滚数据后未能完整恢复原服务状态"
        fail "恢复后 vnstat 验证失败，已回滚"
        return 1
    fi
    rm -rf -- "$extracted"
    if ! restore_services; then
        fail "数据已恢复并通过校验，但未能完整恢复原服务状态"
        return 1
    fi

    record_log "backup_restored archive=$selected rollback=$rollback_dir"
    log "恢复完成；恢复前数据保留在: $rollback_dir"
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
