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
    assert.match(source, /systemctl_bounded --no-block restart/);
    assert.match(source, /TimeoutStopSec=15s/);
    assert.match(source, /sanitize_saved_pm2_dumps/);
    assert.match(source, /FLOWMASTER_RECOVER_UNRESPONSIVE_PM2/);
    assert.match(source, /RECOVER-PM2/);
    assert.doesNotMatch(source, /\bpm2\s+delete\s+["'$]/);
    assert.doesNotMatch(source, /\bpm2\s+kill\s+["'$]/);
    assert.match(source, /systemctl_bounded --no-block stop/);
    assert.match(source, /systemctl_bounded --no-block start/);
    assert.match(source, /ExecStop=\n/);
    assert.match(source, /KillSignal=SIGKILL/);
    assert.match(source, /systemctl_bounded kill --kill-whom=all --signal=KILL/);
    assert.doesNotMatch(source, /\n\s*systemctl (?:show|start|stop|restart|enable|disable|daemon-reload|kill|cat) /);
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
    assert.match(source, /trap\s+'[^']*handle_exit[^']*'\s+EXIT/);
    assert.match(source, /trap\s+'exit 130'\s+INT TERM HUP/);
    assert.match(source, /rollback_restore_transaction/);
    assert.match(source, /RESTORE_TRANSACTION_ACTIVE=true/);
    assert.match(source, /flowmaster-maintenance\.lock/);
    assert.match(source, /validate_trusted_ancestor_chain/);
    assert.match(source, /set -o noclobber/);
    assert.match(source, /\/proc\/self\/fd\/\$MAINTENANCE_LOCK_FD/);
    assert.match(source, /run_systemctl_bounded show "\$service_name" --property=ActiveState --value/);
    assert.match(source, /timeout --signal=TERM --kill-after=2s/);
    assert.match(source, /run_systemctl_bounded --no-block stop flowmaster\.service/);
    assert.match(source, /run_systemctl_bounded --no-block start flowmaster\.service/);
    assert.doesNotMatch(source, /\bpm2\b/);

    const stopFlowMaster = source.indexOf('run_systemctl_bounded --no-block stop flowmaster.service');
    const stopVnstat = source.indexOf('run_systemctl_bounded --no-block stop vnstat', stopFlowMaster);
    const startVnstat = source.indexOf('run_systemctl_bounded --no-block start vnstat', stopVnstat);
    const startFlowMaster = source.indexOf('run_systemctl_bounded --no-block start flowmaster.service', startVnstat);
    assert.ok(
        stopFlowMaster >= 0 &&
        stopVnstat > stopFlowMaster &&
        startVnstat > stopVnstat &&
        startFlowMaster > startVnstat,
        '备份恢复必须先停止读取服务和 vnstat，再按相反顺序恢复'
    );

    const restoreData = source.indexOf('restore_data()');
    const validateRestoredData = source.indexOf('if ! validate_vnstat_database "$VNSTAT_DATA_PATH"', restoreData);
    const resumeAfterValidation = source.indexOf('if ! restore_services', validateRestoredData);
    assert.ok(
        restoreData >= 0 &&
        validateRestoredData > restoreData &&
        resumeAfterValidation > validateRestoredData,
        '恢复数据必须在重新启动 FlowMaster 前验证 vnstat 数据'
    );
    assert.match(source, /vnstat --dbdir "\$data_dir" --dbiflist 2/);
    assert.match(source, /vnstat --dbdir "\$data_dir" --json/);
    assert.doesNotMatch(source, /vnstat\s+--iflist/);
});

test('前端网络速率使用十进制 SI 换算', () => {
    const corePath = path.join(root, 'public', 'js', 'flowmaster-core.js');
    const source = [
        fs.readFileSync(path.join(root, 'public', 'index.html'), 'utf8'),
        fs.readFileSync(corePath, 'utf8')
    ].join('\n');
    const { convertSpeedToMbps } = require(corePath);
    assert.equal(convertSpeedToMbps(1, 'Gb/秒'), 1000);
    assert.equal(convertSpeedToMbps(1, 'Mb/秒'), 1);
    assert.equal(convertSpeedToMbps(1, 'Kb/秒'), 0.001);
    assert.equal(convertSpeedToMbps(1, 'b/秒'), 0.000001);
    assert.doesNotMatch(source, /speedInBits \/ \(1024 \* 1024\)/);
});
