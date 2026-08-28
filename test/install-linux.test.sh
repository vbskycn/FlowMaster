#!/usr/bin/env bash

set -Eeuo pipefail

TEST_ROOT="$(mktemp -d /tmp/flowmaster-install-test.XXXXXX)"
readonly TEST_ROOT
STALL_PID=""

test_cleanup() {
    if [[ -n "$STALL_PID" ]]; then
        kill -TERM -- "-$STALL_PID" >/dev/null 2>&1 || true
        wait "$STALL_PID" 2>/dev/null || true
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

fake_bin="$TEST_ROOT/fake-bin"
fake_pm2_home="$TEST_ROOT/pm2-home"
mkdir -p "$fake_bin" "$fake_pm2_home"
printf '%s\n' "$$" >"$fake_pm2_home/pm2.pid"
cat >"$fake_bin/pm2" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${PM2_TEST_MODE:-healthy}" == "hang" && "${1:-}" == "describe" ]]; then
    sleep 30
fi
printf '%s\n' "${1:-}" >>"${PM2_TEST_LOG:?}"
EOF
chmod +x "$fake_bin/pm2"
original_path="$PATH"
export PATH="$fake_bin:$PATH"
export PM2_HOME="$fake_pm2_home"
export PM2_TEST_LOG="$TEST_ROOT/pm2.log"
retire_legacy_pm2_app
grep -qx 'describe' "$PM2_TEST_LOG"
grep -qx 'delete' "$PM2_TEST_LOG"
grep -qx 'save' "$PM2_TEST_LOG"

export PM2_TEST_MODE=hang
started_at=$SECONDS
if retire_legacy_pm2_app >/dev/null 2>&1; then
    echo "无响应 PM2 不应被视为迁移成功" >&2
    exit 1
fi
elapsed=$((SECONDS - started_at))
(( elapsed >= 5 && elapsed <= 7 )) || { echo "PM2 超时未受控: ${elapsed}s" >&2; exit 1; }
export PATH="$original_path"
unset PM2_HOME PM2_TEST_LOG PM2_TEST_MODE

printf 'INSTALL_LINUX_TESTS=PASS\n'
