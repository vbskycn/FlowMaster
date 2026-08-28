#!/usr/bin/env bash

set -Eeuo pipefail

(( EUID == 0 )) || { echo "该测试需要 root，以创建隔离的临时 systemd unit" >&2; exit 1; }
[[ -d /run/systemd/system ]] || { echo "该测试需要以 systemd 作为 PID 1" >&2; exit 1; }
for command_name in node npm curl systemctl; do
    command -v "$command_name" >/dev/null 2>&1 || { echo "缺少测试命令: $command_name" >&2; exit 1; }
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly INSTALLER="$REPO_ROOT/install.sh"
TEST_ROOT="$(mktemp -d /tmp/flowmaster-pm2-recovery.XXXXXX)"
readonly TEST_ROOT
readonly TEST_UNIT="pm2-flowmaster-recovery-test-${$}.service"
readonly UNIT_FILE="/etc/systemd/system/${TEST_UNIT}"
readonly DROPIN_DIR="/etc/systemd/system/${TEST_UNIT}.d"
readonly PM2_TEST_HOME="${TEST_ROOT}/pm2-home"
readonly PM2_BIN="${TEST_ROOT}/node_modules/.bin/pm2"
readonly TEST_BACKUP_ROOT="${TEST_ROOT}/backups"
FROZEN_PM2_PID=""
RECOVERY_OLD_PID=""
RECOVERY_NEW_PID=""
RECOVERY_ELAPSED=""

report_pm2_test_error() {
    local status="$?"
    echo "PM2 恢复集成测试失败：状态 ${status}，调用行 ${BASH_LINENO[0]:-未知}" >&2
    return "$status"
}
trap report_pm2_test_error ERR

cleanup_pm2_recovery_test() {
    if [[ -n "$FROZEN_PM2_PID" ]]; then
        kill -CONT "$FROZEN_PM2_PID" >/dev/null 2>&1 || true
    fi
    systemctl --no-block stop "$TEST_UNIT" >/dev/null 2>&1 || true
    for _ in {1..50}; do
        [[ "$(systemctl show "$TEST_UNIT" --property=ActiveState --value 2>/dev/null || true)" == "inactive" ]] && break
        sleep 0.1
    done
    systemctl kill --kill-whom=all --signal=KILL "$TEST_UNIT" >/dev/null 2>&1 || true
    rm -f -- "$UNIT_FILE" \
        "$DROPIN_DIR/zzzz-flowmaster-pm2-recovery.conf" \
        "$DROPIN_DIR/zzzzz-flowmaster-conflict-test.conf"
    rmdir -- "$DROPIN_DIR" >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
    case "$TEST_ROOT" in
        /tmp/flowmaster-pm2-recovery.*) rm -rf -- "$TEST_ROOT" ;;
        *) echo "拒绝清理非预期测试目录: $TEST_ROOT" >&2 ;;
    esac
}
trap cleanup_pm2_recovery_test EXIT

free_port() {
    node -e "const s=require('node:net').createServer();s.listen(0,'127.0.0.1',()=>{console.log(s.address().port);s.close();});"
}

wait_for_app() {
    local port="$1"
    local expected_name="$2"
    curl --retry 10 --retry-delay 1 --retry-connrefused --fail --silent --max-time 3 \
        "http://127.0.0.1:${port}" | grep -q "^${expected_name}:"
}

assert_app_status() {
    local expected_name="$1"
    local expected_status="$2"
    PM2_HOME="$PM2_TEST_HOME" "$PM2_BIN" jlist | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{const a=JSON.parse(s);const app=a.find(x=>x.name===process.argv[1]);if(!app||app.pm2_env?.status!==process.argv[2])process.exit(1);})" "$expected_name" "$expected_status"
}

run_recovery() {
    FLOWMASTER_RECOVER_UNRESPONSIVE_PM2=1 \
    FLOWMASTER_BACKUP_ROOT="$TEST_BACKUP_ROOT" \
    PM2_HOME="$PM2_TEST_HOME" \
    PATH="$(dirname "$PM2_BIN"):$PATH" \
        bash -c 'source "$1"; recover_unresponsive_pm2' _ "$INSTALLER"
}

freeze_and_recover() {
    local started_at
    RECOVERY_OLD_PID="$(<"$PM2_TEST_HOME/pm2.pid")"
    [[ "$RECOVERY_OLD_PID" =~ ^[1-9][0-9]*$ ]]
    FROZEN_PM2_PID="$RECOVERY_OLD_PID"
    kill -STOP "$RECOVERY_OLD_PID"
    sleep 0.5
    started_at=$SECONDS
    run_recovery
    RECOVERY_ELAPSED=$((SECONDS - started_at))
    (( RECOVERY_ELAPSED >= 15 && RECOVERY_ELAPSED <= 35 ))
    RECOVERY_NEW_PID="$(<"$PM2_TEST_HOME/pm2.pid")"
    [[ "$RECOVERY_NEW_PID" =~ ^[1-9][0-9]*$ && "$RECOVERY_NEW_PID" != "$RECOVERY_OLD_PID" ]]
    if kill -0 "$RECOVERY_OLD_PID" >/dev/null 2>&1; then
        echo "旧 PM2 daemon 仍然存活: $RECOVERY_OLD_PID" >&2
        return 1
    fi
    grep -zqx 'PIDUSAGE_USE_PS=false' "/proc/${RECOVERY_NEW_PID}/environ"
    FROZEN_PM2_PID=""
}

mkdir -m 0700 "$PM2_TEST_HOME"
npm install --prefix "$TEST_ROOT" --no-save --no-audit --no-fund pm2@5.4.3 >/dev/null

keeper_port="$(free_port)"
flowmaster_port="$(free_port)"
stopped_port="$(free_port)"
[[ "$keeper_port" != "$flowmaster_port" && "$keeper_port" != "$stopped_port" && "$flowmaster_port" != "$stopped_port" ]]
zombies_before="$(ps -eo stat= | awk '$1 ~ /^Z/ { count++ } END { print count + 0 }')"

cat >"$TEST_ROOT/app.js" <<'NODE'
'use strict';
const http = require('node:http');
const port = Number(process.env.APP_PORT);
http.createServer((req, res) => {
    res.end(`${process.env.APP_NAME}:${process.pid}`);
}).listen(port, '127.0.0.1');
process.on('SIGINT', () => process.exit(0));
process.on('SIGTERM', () => process.exit(0));
NODE

cat >"$TEST_ROOT/ecosystem.config.cjs" <<NODE
module.exports = {
  apps: [
    { name: 'flowmaster', script: '$TEST_ROOT/app.js', env: { APP_PORT: '$flowmaster_port', APP_NAME: 'flowmaster' } },
    { name: 'keeper-app', script: '$TEST_ROOT/app.js', env: { APP_PORT: '$keeper_port', APP_NAME: 'keeper-app' } },
    { name: 'stopped-app', script: '$TEST_ROOT/app.js', env: { APP_PORT: '$stopped_port', APP_NAME: 'stopped-app' } }
  ]
};
NODE

PM2_HOME="$PM2_TEST_HOME" "$PM2_BIN" start "$TEST_ROOT/ecosystem.config.cjs" >/dev/null
PM2_HOME="$PM2_TEST_HOME" "$PM2_BIN" stop stopped-app >/dev/null
PM2_HOME="$PM2_TEST_HOME" "$PM2_BIN" save >/dev/null
wait_for_app "$keeper_port" keeper-app
wait_for_app "$flowmaster_port" flowmaster
assert_app_status stopped-app stopped

# 旧安装器可能留下未被独立 systemd unit 管理的 PM2。该场景必须安全拒绝，不能直接杀 daemon。
manual_pm2_pid="$(<"$PM2_TEST_HOME/pm2.pid")"
FROZEN_PM2_PID="$manual_pm2_pid"
kill -STOP "$manual_pm2_pid"
manual_refusal_started=$SECONDS
if run_recovery; then
    echo "未受独立 systemd unit 管理的 PM2 不应被自动重启" >&2
    exit 1
fi
(( SECONDS - manual_refusal_started <= 10 ))
kill -CONT "$manual_pm2_pid"
FROZEN_PM2_PID=""
[[ "$(<"$PM2_TEST_HOME/pm2.pid")" == "$manual_pm2_pid" ]]
[[ ! -e "$TEST_BACKUP_ROOT" ]]
wait_for_app "$keeper_port" keeper-app
wait_for_app "$flowmaster_port" flowmaster
assert_app_status stopped-app stopped
PM2_HOME="$PM2_TEST_HOME" "$PM2_BIN" kill >/dev/null

cat >"$UNIT_FILE" <<EOF
[Unit]
Description=PM2 FlowMaster recovery integration test
After=network.target

[Service]
Type=forking
User=root
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=PM2_HOME=$PM2_TEST_HOME
PIDFile=$PM2_TEST_HOME/pm2.pid
Restart=on-failure
KillMode=control-group
ExecStart=$PM2_BIN resurrect
ExecReload=$PM2_BIN reload all
ExecStop=$PM2_BIN kill

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl start "$TEST_UNIT"
wait_for_app "$keeper_port" keeper-app
wait_for_app "$flowmaster_port" flowmaster
assert_app_status stopped-app stopped

# 后置 drop-in 覆盖停止边界时，恢复必须在重启前拒绝并保持原 daemon 不变。
install -d -o root -g root -m 0755 "$DROPIN_DIR"
cat >"$DROPIN_DIR/zzzzz-flowmaster-conflict-test.conf" <<'EOF'
[Service]
TimeoutStopSec=infinity
EOF
systemctl daemon-reload
conflict_pm2_pid="$(<"$PM2_TEST_HOME/pm2.pid")"
FROZEN_PM2_PID="$conflict_pm2_pid"
kill -STOP "$conflict_pm2_pid"
conflict_started=$SECONDS
if run_recovery; then
    echo "停止边界被覆盖时不应启动 PM2 重启任务" >&2
    exit 1
fi
(( SECONDS - conflict_started <= 12 ))
[[ "$(systemctl show "$TEST_UNIT" --property=MainPID --value)" == "$conflict_pm2_pid" ]]
kill -CONT "$conflict_pm2_pid"
FROZEN_PM2_PID=""
rm -f -- "$DROPIN_DIR/zzzzz-flowmaster-conflict-test.conf"
systemctl daemon-reload
wait_for_app "$keeper_port" keeper-app
wait_for_app "$flowmaster_port" flowmaster
assert_app_status stopped-app stopped

freeze_and_recover
first_old_pid="$RECOVERY_OLD_PID"
first_new_pid="$RECOVERY_NEW_PID"
first_elapsed="$RECOVERY_ELAPSED"
wait_for_app "$keeper_port" keeper-app
wait_for_app "$flowmaster_port" flowmaster
assert_app_status stopped-app stopped

# 第二次恢复验证锁已释放、drop-in 幂等且不会因重复执行覆盖其他配置。
freeze_and_recover
second_old_pid="$RECOVERY_OLD_PID"
second_new_pid="$RECOVERY_NEW_PID"
second_elapsed="$RECOVERY_ELAPSED"
[[ "$second_old_pid" == "$first_new_pid" ]]
wait_for_app "$keeper_port" keeper-app
wait_for_app "$flowmaster_port" flowmaster
assert_app_status stopped-app stopped

FLOWMASTER_BACKUP_ROOT="$TEST_BACKUP_ROOT" PM2_HOME="$PM2_TEST_HOME" \
PATH="$(dirname "$PM2_BIN"):$PATH" \
    bash -c 'source "$1"; retire_legacy_pm2_app' _ "$INSTALLER"

wait_for_app "$keeper_port" keeper-app
if curl --silent --max-time 2 "http://127.0.0.1:${flowmaster_port}" >/dev/null; then
    echo "FlowMaster 测试进程未从 PM2 移除" >&2
    exit 1
fi
PM2_HOME="$PM2_TEST_HOME" "$PM2_BIN" jlist | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{const a=JSON.parse(s);const names=a.filter(x=>!x.pm2_env?.pmx_module).map(x=>x.name).sort();if(JSON.stringify(names)!=='[\"keeper-app\",\"stopped-app\"]')process.exit(1);})"
assert_app_status stopped-app stopped
for dump_file in "$PM2_TEST_HOME/dump.pm2" "$PM2_TEST_HOME/dump.pm2.bak"; do
    [[ ! -e "$dump_file" ]] || ! FLOWMASTER_BACKUP_ROOT="$TEST_BACKUP_ROOT" PM2_HOME="$PM2_TEST_HOME" \
        bash -c 'source "$1"; pm2_dump_contains_app "$2"' _ "$INSTALLER" "$dump_file"
done

for _ in {1..5}; do
    PM2_HOME="$PM2_TEST_HOME" "$PM2_BIN" jlist >/dev/null
done
zombies_after=""
for _ in {1..25}; do
    zombies_after="$(ps -eo stat= | awk '$1 ~ /^Z/ { count++ } END { print count + 0 }')"
    if (( zombies_after <= zombies_before + 1 )); then
        break
    fi
    sleep 0.2
done
if (( zombies_after > zombies_before + 1 )); then
    echo "PM2 CLI 调用后僵尸进程未在 5 秒内收敛: ${zombies_before}->${zombies_after}" >&2
    ps -eo pid=,ppid=,stat=,comm= | awk '$3 ~ /^Z/ { print }' >&2
    exit 1
fi

printf 'REAL_PM2_RECOVERY_TEST=PASS first=%ss second=%ss zombies=%s->%s pids=%s,%s,%s\n' \
    "$first_elapsed" "$second_elapsed" "$zombies_before" "$zombies_after" \
    "$first_old_pid" "$first_new_pid" "$second_new_pid"
