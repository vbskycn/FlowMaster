#!/usr/bin/env bash

set -Eeuo pipefail

TEST_ROOT="$(mktemp -d /tmp/flowmaster-install-test.XXXXXX)"
readonly TEST_ROOT
export FLOWMASTER_BACKUP_ROOT="$TEST_ROOT/backups"
STALL_PID=""
IMPOSTOR_PID=""
FAKE_PM2_PID=""

test_cleanup() {
    if [[ -n "$STALL_PID" ]]; then
        kill -TERM -- "-$STALL_PID" >/dev/null 2>&1 || true
        wait "$STALL_PID" 2>/dev/null || true
    fi
    if [[ -n "$IMPOSTOR_PID" ]]; then
        kill -TERM "$IMPOSTOR_PID" >/dev/null 2>&1 || true
        wait "$IMPOSTOR_PID" 2>/dev/null || true
    fi
    if [[ -n "$FAKE_PM2_PID" ]]; then
        kill "$FAKE_PM2_PID" >/dev/null 2>&1 || true
        wait "$FAKE_PM2_PID" 2>/dev/null || true
    fi
    case "$TEST_ROOT" in
        /tmp/flowmaster-install-test.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap test_cleanup EXIT

# 运行时从仓库根目录动态定位，shellcheck 无法静态跟随。
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/install.sh"
# install.sh 注册的退出清理在测试中没有部署目录；这里恢复测试自己的清理器。
trap test_cleanup EXIT

# 安全路径应显式返回成功；否则 set -e 会让直接执行的安装器在菜单前静默退出。
validate_configured_paths

free_port() {
    node -e "const s=require('net').createServer(); s.listen(0,'127.0.0.1',()=>{console.log(s.address().port);s.close();});"
}

emit_effective_unit_properties() {
    local expected_supplementary_groups=""
    getent group vnstat >/dev/null 2>&1 && expected_supplementary_groups="vnstat"
    printf '%s\n' \
        'Type=simple' \
        "User=${FLOWMASTER_TEST_UNIT_USER:-flowmaster}" \
        'Group=flowmaster' \
        "SupplementaryGroups=${FLOWMASTER_TEST_UNIT_SUPPLEMENTARY_GROUPS:-$expected_supplementary_groups}" \
        'WorkingDirectory=/opt/flowmaster' \
        'Restart=on-failure' \
        'RestartUSec=3s' \
        'NoNewPrivileges=yes' \
        'PrivateTmp=yes' \
        'PrivateDevices=yes' \
        'ProtectSystem=strict' \
        'ProtectHome=yes' \
        'ProtectHostname=yes' \
        'ProtectClock=yes' \
        'ProtectKernelTunables=yes' \
        'ProtectKernelModules=yes' \
        'ProtectKernelLogs=yes' \
        'ProtectControlGroups=yes' \
        'ProtectProc=invisible' \
        'ProcSubset=pid' \
        'RestrictSUIDSGID=yes' \
        'RestrictRealtime=yes' \
        'RestrictNamespaces=yes' \
        'LockPersonality=yes' \
        'CapabilityBoundingSet=' \
        'AmbientCapabilities=' \
        'RestrictAddressFamilies=AF_INET6 AF_UNIX AF_INET' \
        'SystemCallArchitectures=native'
}

# 主 unit 可能被既有 drop-in 覆盖；部署只能接受最终生效的专用账号和沙箱配置。
(
    systemctl_bounded() { emit_effective_unit_properties; }
    validate_effective_systemd_unit
)
if (
    export FLOWMASTER_TEST_UNIT_USER=root
    systemctl_bounded() { emit_effective_unit_properties; }
    validate_effective_systemd_unit
) >/dev/null 2>&1; then
    echo "被 drop-in 覆盖为 root 的 systemd unit 不应通过安全校验" >&2
    exit 1
fi

if (
    export FLOWMASTER_TEST_UNIT_SUPPLEMENTARY_GROUPS="vnstat root"
    systemctl_bounded() { emit_effective_unit_properties; }
    validate_effective_systemd_unit
) >/dev/null 2>&1; then
    echo "被 drop-in 增加特权附属组的 systemd unit 不应通过安全校验" >&2
    exit 1
fi

# ProtectProc/ProcSubset 从 systemd 247 起才可依赖；版本过旧或输出异常应在改动系统前拒绝。
(
    systemctl() { printf 'systemd 247 (247.3-test)\n'; }
    validate_systemd_version
)
for unsafe_systemd_version in 246 unknown; do
    if (
        systemctl() { printf 'systemd %s\n' "$unsafe_systemd_version"; }
        validate_systemd_version
    ) >/dev/null 2>&1; then
        echo "不受支持的 systemd 版本不应通过校验: $unsafe_systemd_version" >&2
        exit 1
    fi
done

# 健康响应之外还要核对主进程的全部 UID/GID/Groups，不能接受 root 或额外特权组。
current_uid="$(id -u)"
current_gid="$(id -g)"
current_groups="$(id -G)"
(
    id() {
        case "${1:-}" in
            -u) printf '%s\n' "$current_uid" ;;
            -g) printf '%s\n' "$current_gid" ;;
            -G) printf '%s\n' "$current_groups" ;;
            *) return 1 ;;
        esac
    }
    process_has_service_identity "$BASHPID"
)
if (
    id() {
        case "${1:-}" in
            -u) printf '%s\n' "$((current_uid + 1))" ;;
            -g) printf '%s\n' "$current_gid" ;;
            -G) printf '%s\n' "$current_groups" ;;
            *) return 1 ;;
        esac
    }
    process_has_service_identity "$BASHPID"
) >/dev/null 2>&1; then
    echo "UID 不匹配的 systemd 主进程不应通过身份校验" >&2
    exit 1
fi
if (
    id() {
        case "${1:-}" in
            -u) printf '%s\n' "$current_uid" ;;
            -g) printf '%s\n' "$current_gid" ;;
            -G) printf '%s 65534\n' "$current_groups" ;;
            *) return 1 ;;
        esac
    }
    process_has_service_identity "$BASHPID"
) >/dev/null 2>&1; then
    echo "附属组集合不匹配的 systemd 主进程不应通过身份校验" >&2
    exit 1
fi

version_response_matches_instance '{"version":"9.9.9","instanceTokenMatched":true}' '9.9.9'
version_response_matches_instance '{"version":"9.9.9"}' '9.9.9' 1
for unsafe_version_response in \
    '{"version":"9.9.9"}' \
    '{"version":"9.9.9","instanceTokenMatched":true,"extra":true}' \
    '{"version":"9.9.8","instanceTokenMatched":true}'; do
    if version_response_matches_instance "$unsafe_version_response" '9.9.9'; then
        echo "未绑定本次实例的版本响应不应通过校验: $unsafe_version_response" >&2
        exit 1
    fi
done
if version_response_matches_instance '{"version":"9.9.9","extra":true}' '9.9.9' 1; then
    echo "旧版 PM2 回滚兼容也只应接受精确 version 响应" >&2
    exit 1
fi

# start_systemd_service 在条件调用上下文中也必须显式传播 enable/restart 失败。
enable_failure_log="$TEST_ROOT/enable-failure.log"
if (
    SERVICE_INSTANCE_TOKEN="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    cd() { return 0; }
    node() { printf 'http://127.0.0.1:10089/api/version\n'; }
    systemctl_bounded() {
        printf '%s\n' "$*" >>"$enable_failure_log"
        [[ "${1:-}" != "enable" ]]
    }
    start_systemd_service '9.9.9'
) >/dev/null 2>&1; then
    echo "systemctl enable 失败不应被误报为部署成功" >&2
    exit 1
fi

# groupadd 成功而 useradd 失败时，必须立即删除且验证本次新建的孤立组。
(
    group_present=0
    call_log="$TEST_ROOT/service-user-create.log"
    resolve_nologin_shell() {
        printf 'resolve-nologin\n' >>"$call_log"
        printf '/usr/sbin/nologin\n'
    }
    getent() {
        case "${1:-}:${2:-}" in
            group:flowmaster)
                (( group_present == 1 )) && printf 'flowmaster:x:995:\n'
                ;;
            passwd:flowmaster|group:vnstat)
                return 2
                ;;
            passwd:)
                return 0
                ;;
            *)
                return 2
                ;;
        esac
    }
    groupadd() {
        printf 'groupadd\n' >>"$call_log"
        group_present=1
    }
    useradd() {
        printf 'useradd\n' >>"$call_log"
        return 1
    }
    groupdel() {
        [[ "$group_present" == "1" && "${1:-}" == "flowmaster" ]] || return 1
        printf 'groupdel\n' >>"$call_log"
        group_present=0
    }
    if create_service_user; then
        echo "注入的 useradd 失败不应被视为成功" >&2
        exit 1
    fi
    [[ "$group_present" == "0" && "$DEPLOY_SERVICE_GROUP_CREATED" == "0" ]]
    [[ "$(paste -sd, "$call_log")" == "resolve-nologin,groupadd,useradd,groupdel" ]]
)
grep -qx 'enable flowmaster.service' "$enable_failure_log"
[[ "$(wc -l <"$enable_failure_log")" -eq 1 ]]

restart_failure_log="$TEST_ROOT/restart-failure.log"
if (
    SERVICE_INSTANCE_TOKEN="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    cd() { return 0; }
    node() { printf 'http://127.0.0.1:10089/api/version\n'; }
    systemctl_bounded() {
        printf '%s\n' "$*" >>"$restart_failure_log"
        case "${1:-}" in
            enable|reset-failed) return 0 ;;
            is-enabled) printf 'enabled\n' ;;
            show) emit_effective_unit_properties ;;
            --no-block) return 1 ;;
            *) return 1 ;;
        esac
    }
    start_systemd_service '9.9.9'
) >/dev/null 2>&1; then
    echo "systemctl restart 失败不应被误报为部署成功" >&2
    exit 1
fi
grep -qx -- '--no-block restart flowmaster.service' "$restart_failure_log"

# 成功启动必须使用实例令牌，并在同一 PID/NRestarts 上完成 9 次（4 秒）稳定观察。
stable_snapshot_log="$TEST_ROOT/stable-snapshots.log"
stable_curl_log="$TEST_ROOT/stable-curl.log"
(
    # 变量由动态 source 的 start_systemd_service 读取。
    # shellcheck disable=SC2034
    SERVICE_INSTANCE_TOKEN="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    cd() { return 0; }
    node() { printf 'http://127.0.0.1:10089/api/version\n'; }
    sleep() { return 0; }
    systemctl_bounded() {
        case "${1:-}" in
            enable|reset-failed|--no-block) return 0 ;;
            is-enabled) printf 'enabled\n' ;;
            *) return 1 ;;
        esac
    }
    validate_effective_systemd_unit() { return 0; }
    query_deployed_service_snapshot() {
        printf 'snapshot\n' >>"$stable_snapshot_log"
        printf '4242|7\n'
    }
    process_matches_service_command() { [[ "${1:-}" == "4242" ]]; }
    process_has_service_identity() { [[ "${1:-}" == "4242" ]]; }
    curl() {
        printf '%s\n' "$*" >>"$stable_curl_log"
        printf '{"version":"9.9.9","instanceTokenMatched":true}\n'
    }
    version_response_matches_instance() {
        [[ "${1:-}" == '{"version":"9.9.9","instanceTokenMatched":true}' && "${2:-}" == "9.9.9" ]]
    }
    start_systemd_service '9.9.9'
)
[[ "$(wc -l <"$stable_snapshot_log")" -eq 11 ]]
grep -q -- '--header X-FlowMaster-Instance-Token: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$stable_curl_log"

# 第 9 次稳定观察后的最终 snapshot 若换了 PID/NRestarts，必须重新完成整段稳定窗口。
changing_snapshot_log="$TEST_ROOT/changing-snapshots.log"
(
    # 变量由动态 source 的 start_systemd_service 读取。
    # shellcheck disable=SC2034
    SERVICE_INSTANCE_TOKEN="cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    cd() { return 0; }
    node() { printf 'http://127.0.0.1:10089/api/version\n'; }
    sleep() { return 0; }
    systemctl_bounded() {
        case "${1:-}" in
            enable|reset-failed|--no-block) return 0 ;;
            is-enabled) printf 'enabled\n' ;;
            *) return 1 ;;
        esac
    }
    validate_effective_systemd_unit() { return 0; }
    query_deployed_service_snapshot() {
        local count
        printf 'snapshot\n' >>"$changing_snapshot_log"
        count="$(wc -l <"$changing_snapshot_log")"
        if [[ "$count" == "11" ]]; then
            printf '4343|8\n'
        else
            printf '4242|7\n'
        fi
    }
    process_matches_service_command() { [[ "${1:-}" == "4242" ]]; }
    process_has_service_identity() { [[ "${1:-}" == "4242" ]]; }
    curl() { printf '{"version":"9.9.9","instanceTokenMatched":true}\n'; }
    version_response_matches_instance() {
        [[ "${1:-}" == '{"version":"9.9.9","instanceTokenMatched":true}' && "${2:-}" == "9.9.9" ]]
    }
    start_systemd_service '9.9.9'
)
[[ "$(wc -l <"$changing_snapshot_log")" -eq 22 ]]

create_fixture() {
    local target="$1"
    mkdir -p "$target"
    cat >"$target/package.json" <<'EOF'
{"version":"9.9.9"}
EOF
    cat >"$target/server.js" <<'EOF'
'use strict';
const http = require('node:http');
const port = Number(process.env.PORT);
const host = process.env.HOST;
const server = http.createServer((req, res) => {
    if (req.url === '/api/version') {
        res.setHeader('Content-Type', 'application/json');
        const result = { version: '9.9.9' };
        if (process.env.FLOWMASTER_INSTANCE_TOKEN &&
            req.headers['x-flowmaster-instance-token'] === process.env.FLOWMASTER_INSTANCE_TOKEN) {
            result.instanceTokenMatched = true;
        }
        res.end(JSON.stringify(result));
        return;
    }
    res.statusCode = 404;
    res.end();
});
server.listen(port, host);
process.on('SIGTERM', () => server.close(() => process.exit(0)));
EOF
}

success_dir="$TEST_ROOT/success"
create_fixture "$success_dir"
success_port="$(free_port)"
FLOWMASTER_SMOKE_PORT="$success_port" \
FLOWMASTER_SMOKE_TIMEOUT_SECONDS=5 \
FLOWMASTER_SMOKE_CURL_TIMEOUT_SECONDS=1 \
    smoke_test "$success_dir"
[[ -z "$SMOKE_PID" && -z "$SMOKE_OUTPUT_FILE" ]]

# 即使占用端口的旧服务返回完全相同的版本，也不能被误认为本次临时实例。
impostor_port="$(free_port)"
node -e "require('node:http').createServer((q,s)=>{s.setHeader('content-type','application/json');s.end(JSON.stringify({version:'9.9.9'}));}).listen(${impostor_port},'127.0.0.1')" &
IMPOSTOR_PID=$!
sleep 0.2
started_at=$SECONDS
if FLOWMASTER_SMOKE_PORT="$impostor_port" \
    FLOWMASTER_SMOKE_TIMEOUT_SECONDS=3 \
    FLOWMASTER_SMOKE_CURL_TIMEOUT_SECONDS=1 \
    smoke_test "$success_dir" >/dev/null 2>&1; then
    echo "冒烟测试不应接受同版本的占用端口服务" >&2
    exit 1
fi
(( SECONDS - started_at <= 5 )) || { echo "同版本占用端口测试超时未受控" >&2; exit 1; }
kill -TERM "$IMPOSTOR_PID" >/dev/null 2>&1 || true
wait "$IMPOSTOR_PID" 2>/dev/null || true
IMPOSTOR_PID=""

# 默认路由字段顺序并不固定，必须按 dev 关键字取接口，并使用数据库接口清单。
interface_log="$TEST_ROOT/interface.log"
(
    ip() {
        if [[ "$*" == "route show default" ]]; then
            printf 'default dev test0 scope link metric 100\n'
        else
            return 1
        fi
    }
    vnstat() {
        printf '%s\n' "$*" >>"$interface_log"
        [[ "$*" == "--dbiflist 1" ]] && printf 'test0\n'
    }
    systemctl() { return 0; }
    service() { return 0; }
    detect_network_interface >"$TEST_ROOT/interface-output.log"
)
grep -q '检测到网络接口: test0' "$TEST_ROOT/interface-output.log"
grep -qx -- '--dbiflist 1' "$interface_log"

# 即使用户目录里的 Node 对普通账号可执行，ProtectHome 仍会在最终 unit 中隐藏它。
if (
    readlink() {
        [[ "${1:-}" == "-f" ]] || return 1
        printf '/home/test/.nvm/bin/node\n'
    }
    validate_service_runtime_as_user "$success_dir"
) >/dev/null 2>&1; then
    echo "ProtectHome 隔离范围内的 Node.js 不应通过服务预检" >&2
    exit 1
fi

# 旧版配置必须在任何 PM2 迁移前可复制为普通文件；指向受 systemd
# ProtectHome/PrivateTmp 隔离路径的链接不能沿用到新服务。
environment_fixture="$TEST_ROOT/environment-file"
mkdir -p "$environment_fixture"
printf 'ADMIN_TOKEN=test-only\n' >"$environment_fixture/real.env"
ln -s "$environment_fixture/real.env" "$environment_fixture/.env"
if validate_environment_file "$environment_fixture" >/dev/null 2>&1; then
    echo "符号链接 .env 不应通过迁移预检" >&2
    exit 1
fi
rm -f -- "$environment_fixture/.env"
printf 'ADMIN_TOKEN=test-only\n' >"$environment_fixture/.env"
validate_environment_file "$environment_fixture"
rm -f -- "$environment_fixture/.env"
ln -s "$environment_fixture/missing.env" "$environment_fixture/.env"
if validate_environment_file "$environment_fixture" >/dev/null 2>&1; then
    echo "断裂的 .env 符号链接不应通过迁移预检" >&2
    exit 1
fi
deploy_before_pm2="$(declare -f deploy)"
deploy_before_pm2="${deploy_before_pm2%%recover_pm2_before_health_check*}"
[[ "$deploy_before_pm2" == *validate_existing_environment_file* ]] || {
    echo "部署必须在 PM2 预恢复前校验旧版 .env" >&2
    exit 1
}

# 已存在的同名系统身份只有完全符合安装器创建的专用账号约束时才能复用。
run_service_identity_case() (
    local fixture_members="${1:-}" fixture_shell="${2:-/usr/sbin/nologin}"
    local fixture_password="${3:-!}" fixture_gids="${4:-995 996}" fixture_vnstat_gid="${5:-996}"
    local fixture_primary_peer="${6:-}" fixture_gid_alias="${7:-}"
    resolve_nologin_shell() { printf '/usr/sbin/nologin\n'; }
    readlink() {
        [[ "${1:-}" == "-f" ]] || return 1
        printf '%s\n' "${3:-${2:-}}"
    }
    getent() {
        case "${1:-}:${2:-}" in
            group:flowmaster) printf 'flowmaster:x:995:%s\n' "$fixture_members" ;;
            group:vnstat) printf 'vnstat:x:%s:\n' "$fixture_vnstat_gid" ;;
            group:)
                printf 'flowmaster:x:995:%s\n' "$fixture_members"
                printf 'vnstat:x:%s:\n' "$fixture_vnstat_gid"
                [[ -z "$fixture_gid_alias" ]] || printf '%s:x:995:\n' "$fixture_gid_alias"
                ;;
            passwd:flowmaster) printf 'flowmaster:x:995:995::/opt/flowmaster:%s\n' "$fixture_shell" ;;
            passwd:)
                printf 'flowmaster:x:995:995::/opt/flowmaster:%s\n' "$fixture_shell"
                [[ -z "$fixture_primary_peer" ]] || printf '%s:x:997:995::/nonexistent:/usr/sbin/nologin\n' "$fixture_primary_peer"
                ;;
            shadow:flowmaster) printf 'flowmaster:%s:20000:0:99999:7:::\n' "$fixture_password" ;;
            *) return 2 ;;
        esac
    }
    id() {
        [[ "${1:-}" == "-G" && "${2:-}" == "flowmaster" ]] || return 2
        printf '%s\n' "$fixture_gids"
    }
    validate_existing_service_identity
)

run_service_identity_case
for unsafe_case in \
    'other-user|/usr/sbin/nologin|!|995 996' \
    '|/bin/bash|!|995 996' \
    '|/usr/sbin/nologin|password-hash|995 996' \
    '|/usr/sbin/nologin|!|995 996 997' \
    '|/usr/sbin/nologin|!|995 0|0' \
    '|/usr/sbin/nologin|!|995 996|996|peer-user|' \
    '|/usr/sbin/nologin|!|995 996|996||flowmaster-alias'; do
    IFS='|' read -r unsafe_members unsafe_shell unsafe_password unsafe_gids unsafe_vnstat_gid unsafe_peer unsafe_alias <<<"$unsafe_case"
    if run_service_identity_case "$unsafe_members" "$unsafe_shell" "$unsafe_password" "$unsafe_gids" \
        "$unsafe_vnstat_gid" "$unsafe_peer" "$unsafe_alias" >/dev/null 2>&1; then
        echo "不安全的同名 flowmaster 系统身份不应被复用: $unsafe_case" >&2
        exit 1
    fi
done

if (
    getent() {
        [[ "${1:-}:${2:-}" == "group:flowmaster" ]]
    }
    validate_service_identity_preflight
) >/dev/null 2>&1; then
    echo "仅存在同名用户或组时不应通过服务身份预检" >&2
    exit 1
fi

archive_fixture="$TEST_ROOT/archive-fixture"
mkdir -p "$archive_fixture/flowmaster-safe"
printf '{}\n' >"$archive_fixture/flowmaster-safe/package.json"
tar -czf "$TEST_ROOT/safe-source.tar.gz" -C "$archive_fixture" flowmaster-safe
validate_source_archive "$TEST_ROOT/safe-source.tar.gz"
ln -s /etc/passwd "$archive_fixture/flowmaster-safe/unsafe-link"
tar -czf "$TEST_ROOT/unsafe-source.tar.gz" -C "$archive_fixture" flowmaster-safe
if validate_source_archive "$TEST_ROOT/unsafe-source.tar.gz" >/dev/null 2>&1; then
    echo "包含符号链接的源码归档不应通过校验" >&2
    exit 1
fi

stalled_port="$(free_port)"
setsid node -e "require('net').createServer(() => {}).listen(${stalled_port}, '127.0.0.1')" &
STALL_PID=$!
sleep 0.3
failure_dir="$TEST_ROOT/failure"
create_fixture "$failure_dir"
started_at=$SECONDS
if FLOWMASTER_SMOKE_PORT="$stalled_port" \
    FLOWMASTER_SMOKE_TIMEOUT_SECONDS=4 \
    FLOWMASTER_SMOKE_CURL_TIMEOUT_SECONDS=1 \
    smoke_test "$failure_dir"; then
    echo "冒烟测试不应接受占用端口的无响应服务" >&2
    exit 1
fi
elapsed=$((SECONDS - started_at))
(( elapsed <= 6 )) || { echo "冒烟测试超时未受控: ${elapsed}s" >&2; exit 1; }
[[ -z "$SMOKE_PID" && -z "$SMOKE_OUTPUT_FILE" ]]

# 该函数通过 check_process_health 动态调用。
# shellcheck disable=SC2317
ps() {
    printf 'Z\nZ\n'
}
if (FLOWMASTER_MAX_ZOMBIES=2 check_process_health >/dev/null 2>&1); then
    echo "僵尸进程阈值保护未生效" >&2
    exit 1
fi
unset -f ps

# 高僵尸预检一旦进入 PM2 恢复流程，任何恢复或后置验证失败都必须阻断部署，
# 不能因为 daemon 重启后僵尸数量下降而把失败吞成成功。
precheck_pm2_home="$TEST_ROOT/precheck-pm2-home"
mkdir -p "$precheck_pm2_home"
printf '%s' "$$" >"$precheck_pm2_home/pm2.pid"
if (
    ps() {
        case "$*" in
            '-eo stat=') printf 'Z\nZ\n' ;;
            '-eo ppid=,stat=') printf '%s Z\n%s Z\n' "$$" "$$" ;;
            *) return 1 ;;
        esac
    }
    is_root_pm2_daemon() { return 0; }
    recover_unresponsive_pm2() { return 1; }
    PM2_HOME="$precheck_pm2_home" FLOWMASTER_MAX_ZOMBIES=2 recover_pm2_before_health_check
) >"$TEST_ROOT/precheck-recovery.log" 2>&1; then
    echo "高僵尸预检不应吞掉 PM2 恢复失败" >&2
    exit 1
fi
grep -q 'PM2 原地恢复未完整通过验证' "$TEST_ROOT/precheck-recovery.log"

if (( EUID == 0 )); then
    dump_home="$TEST_ROOT/dump-home"
    dump_backup="$TEST_ROOT/dump-backup"
    mkdir -m 0700 "$dump_home" "$dump_backup"
    for dump_name in dump.pm2 dump.pm2.bak; do
        cat >"$dump_home/$dump_name" <<'EOF'
[
  {"name":"flowmaster","status":"online"},
  {"name":"flowmaster-worker","status":"online"},
  {"name":"keeper-app","status":"online"}
]
EOF
        chmod 0600 "$dump_home/$dump_name"
    done
    sanitize_saved_pm2_dumps "$dump_home" "$dump_backup"
    for dump_name in dump.pm2 dump.pm2.bak; do
        if pm2_dump_contains_app "$dump_home/$dump_name"; then
            echo "PM2 主/备清单仍包含精确 FlowMaster" >&2
            exit 1
        fi
        node -e "const fs=require('node:fs');const a=JSON.parse(fs.readFileSync(process.argv[1]));const n=a.map(x=>x.name).sort();if(JSON.stringify(n)!=='[\"flowmaster-worker\",\"keeper-app\"]')process.exit(1);" "$dump_home/$dump_name"
        pm2_dump_contains_app "$dump_backup/$dump_name.before-flowmaster-removal"
    done

    unsafe_dump_home="$TEST_ROOT/unsafe-dump-home"
    mkdir -m 0700 "$unsafe_dump_home"
    cp -- "$dump_backup/dump.pm2.before-flowmaster-removal" "$unsafe_dump_home/dump.pm2"
    ln -s "$unsafe_dump_home/dump.pm2" "$unsafe_dump_home/dump.pm2.bak"
    if sanitize_saved_pm2_dumps "$unsafe_dump_home" "$TEST_ROOT/unsafe-dump-backup" >/dev/null 2>&1; then
        echo "PM2 符号链接清单不应通过校验" >&2
        exit 1
    fi
    pm2_dump_contains_app "$unsafe_dump_home/dump.pm2"

    known_dropin="$TEST_ROOT/known-flowmaster-pm2-dropin.conf"
    cat >"$known_dropin" <<'EOF'
[Service]
Environment=PIDUSAGE_USE_PS=false
TimeoutStopSec=15s
TimeoutStopFailureMode=kill
KillMode=control-group
SendSIGKILL=yes
EOF
    chmod 0600 "$known_dropin"
    is_known_flowmaster_pm2_dropin "$known_dropin"
    printf '\nRestart=always\n' >>"$known_dropin"
    if is_known_flowmaster_pm2_dropin "$known_dropin"; then
        echo "被修改的旧版 FlowMaster PM2 drop-in 不应通过精确识别" >&2
        exit 1
    fi
fi

fake_bin="$TEST_ROOT/fake-bin"
fake_pm2_home="$TEST_ROOT/pm2-home"
mkdir -p "$fake_bin" "$fake_pm2_home"
bash -c 'exec -a "PM2 v5.4.3: God Daemon (test)" sleep 60' &
FAKE_PM2_PID=$!
printf '%s' "$FAKE_PM2_PID" >"$fake_pm2_home/pm2.pid"
cat >"$fake_bin/pm2" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${PM2_TEST_MODE:-healthy}" == "hang" && "${1:-}" == "jlist" ]]; then
    sleep 30
fi
printf '%s\n' "${1:-}" >>"${PM2_TEST_LOG:?}"
if [[ "${1:-}" == "jlist" ]]; then
    printf '[{"name":"flowmaster","pid":123,"pm2_env":{"name":"flowmaster","status":"online"}}]\n'
fi
EOF
chmod +x "$fake_bin/pm2"
original_path="$PATH"
export PATH="$fake_bin:$PATH"
export PM2_HOME="$fake_pm2_home"
export PM2_TEST_LOG="$TEST_ROOT/pm2.log"
if retire_legacy_pm2_app >/dev/null 2>&1; then
    echo "未受独立 systemd unit 管理的健康 PM2 不应被自动停止" >&2
    exit 1
fi
grep -qx 'jlist' "$PM2_TEST_LOG"
if grep -Eq '^(delete|save|kill|stop)$' "$PM2_TEST_LOG"; then
    echo "离线迁移不应调用 PM2 的删除、保存或停止 RPC" >&2
    exit 1
fi

export PM2_TEST_MODE=hang
started_at=$SECONDS
if retire_legacy_pm2_app >/dev/null 2>&1; then
    echo "无响应 PM2 不应被视为迁移成功" >&2
    exit 1
fi
elapsed=$((SECONDS - started_at))
(( elapsed >= 5 && elapsed <= 7 )) || { echo "PM2 超时未受控: ${elapsed}s" >&2; exit 1; }

# jlist 在删除前超时时，恢复必须要求保存清单包含 FlowMaster，不能把尚未
# 保存的旧服务静默丢失。函数覆盖仅存在于子 Shell，不影响其他测试。
recovery_argument_log="$TEST_ROOT/recovery-argument.log"
(
    get_pm2_app_presence() { return 124; }
    recover_unresponsive_pm2() {
        printf '%s %s\n' "${1:-}" "${2:-}" >"$recovery_argument_log"
        return 1
    }
    if retire_legacy_pm2_app >/dev/null 2>&1; then
        echo "删除前 jlist 超时不应被视为迁移成功" >&2
        exit 1
    fi
)
grep -qx '1 0' "$recovery_argument_log"

# 健康 PM2 中发现旧 FlowMaster 时，也必须走同一条离线迁移路径；第二个参数
# 只授权健康探测成功，不能退回在线 pm2 delete。
(
    get_pm2_app_presence() { printf 'present\n'; }
    recover_unresponsive_pm2() {
        printf '%s %s\n' "${1:-}" "${2:-}" >"$recovery_argument_log"
        return 1
    }
    if retire_legacy_pm2_app >/dev/null 2>&1; then
        echo "模拟的离线迁移失败不应被视为成功" >&2
        exit 1
    fi
)
grep -qx '1 1' "$recovery_argument_log"

export PATH="$original_path"
unset PM2_HOME PM2_TEST_LOG PM2_TEST_MODE

printf 'INSTALL_LINUX_TESTS=PASS\n'
