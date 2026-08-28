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
    assert.match(source, /timeout 5s env PIDUSAGE_USE_PS=false pm2 describe/);
    assert.match(source, /FLOWMASTER_MAX_ZOMBIES/);
    assert.match(source, /--connect-timeout/);
    assert.match(source, /--max-time/);
    assert.match(source, /stop_smoke_process/);
    assert.match(source, /exec setsid env/);
    assert.match(source, /host === '0\.0\.0\.0' \|\| host === '::'/);
    assert.match(source, /--noproxy '\*'/);
    assert.match(source, /\$health_url/);
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
