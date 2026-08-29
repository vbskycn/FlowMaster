#!/usr/bin/env bash

set -Eeuo pipefail

TEST_ROOT="$(mktemp -d /tmp/flowmaster-install-test.XXXXXX)"
readonly TEST_ROOT
export FLOWMASTER_BACKUP_ROOT="$TEST_ROOT/backups"
STALL_PID=""
FAKE_PM2_PID=""

test_cleanup() {
    if [[ -n "$STALL_PID" ]]; then
        kill -TERM -- "-$STALL_PID" >/dev/null 2>&1 || true
        wait "$STALL_PID" 2>/dev/null || true
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

free_port() {
    node -e "const s=require('net').createServer(); s.listen(0,'127.0.0.1',()=>{console.log(s.address().port);s.close();});"
}

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
        res.end(JSON.stringify({ version: '9.9.9' }));
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
