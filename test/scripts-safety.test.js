'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const root = path.join(__dirname, '..');

test('安装脚本不会删除 vnstat 数据库', () => {
    const source = fs.readFileSync(path.join(root, 'install.sh'), 'utf8');
    assert.doesNotMatch(source, /rm\s+-[^\n]*\/var\/lib\/vnstat/);
    assert.match(source, /vnstat 历史数据将被保留/);
    assert.match(source, /npm ci --omit=dev/);
    assert.match(source, /ROLLBACK_DIR/);
    assert.doesNotMatch(source, /npm install --global pm2/);
    assert.match(source, /flowmaster\.service/);
    assert.match(source, /systemctl restart/);
    assert.match(source, /timeout --signal=TERM --kill-after=2s 5s env PM2_HOME=.*PIDUSAGE_USE_PS=false/);
    assert.match(source, /FLOWMASTER_MAX_ZOMBIES/);
    assert.match(source, /--connect-timeout/);
    assert.match(source, /--max-time/);
    assert.match(source, /stop_smoke_process/);
    assert.match(source, /exec setsid env/);
    assert.match(source, /host === '0\.0\.0\.0' \|\| host === '::'/);
    assert.match(source, /--noproxy '\*'/);
    assert.match(source, /\$health_url/);
    assert.match(source, /systemctl --no-block restart/);
    assert.match(source, /TimeoutStopSec=15s/);
    assert.match(source, /sanitize_saved_pm2_dumps/);
    assert.match(source, /FLOWMASTER_RECOVER_UNRESPONSIVE_PM2/);
    assert.match(source, /RECOVER-PM2/);
    assert.doesNotMatch(source, /\bpm2\s+delete\s+["'$]/);
    assert.doesNotMatch(source, /\bpm2\s+kill\s+["'$]/);
    assert.match(source, /systemctl --no-block stop/);
    assert.match(source, /systemctl --no-block start/);
    assert.match(source, /ExecStop=\n/);
    assert.match(source, /KillSignal=SIGKILL/);
    assert.match(source, /systemctl kill --kill-whom=all --signal=KILL/);
    assert.match(source, /trap resume_frozen_pm2 EXIT/);
    assert.match(source, /TimeoutStopFailureMode=kill/);
    assert.match(source, /install_pm2_dropin_atomically/);

    const stopCall = source.indexOf('stop_pm2_systemd_unit "$pm2_unit"');
    const offlineFilter = source.indexOf('sanitize_saved_pm2_dumps "$pm2_home" "$recovery_dir"', stopCall);
    const startCall = source.indexOf('start_pm2_systemd_unit "$pm2_unit"', offlineFilter);
    assert.ok(stopCall >= 0 && offlineFilter > stopCall && startCall > offlineFilter,
        'PM2 迁移必须按停止、离线过滤、按需启动的顺序执行');
});

test('备份脚本包含一致性、校验与恢复前回滚措施', () => {
    const source = fs.readFileSync(path.join(root, 'backup_vnstat.sh'), 'utf8');
    assert.match(source, /stop_services/);
    assert.match(source, /checksums\.sha256/);
    assert.match(source, /rollback/);
    assert.match(source, /trap restore_services EXIT/);
});

test('前端网络速率使用十进制 SI 换算', () => {
    const source = fs.readFileSync(path.join(root, 'public', 'index.html'), 'utf8');
    assert.match(source, /speed \* 1000 \* 1000 \* 1000/);
    assert.match(source, /speedInBits \/ \(1000 \* 1000\)/);
    assert.doesNotMatch(source, /speedInBits \/ \(1024 \* 1024\)/);
});
