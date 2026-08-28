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
});

test('备份脚本包含一致性、校验与恢复前回滚措施', () => {
    const source = fs.readFileSync(path.join(root, 'backup_vnstat.sh'), 'utf8');
    assert.match(source, /stop_services/);
    assert.match(source, /checksums\.sha256/);
    assert.match(source, /rollback/);
    assert.match(source, /trap restore_services EXIT/);
});
