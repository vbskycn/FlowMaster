'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const core = require('../public/js/flowmaster-core');
const { checkInlineScripts } = require('../scripts/check-inline-js');
const root = path.join(__dirname, '..');

test('内联脚本检查器接受零个脚本并仍拒绝语法错误', () => {
    assert.equal(checkInlineScripts('<script src="/app.js"></script>'), 0);
    assert.equal(checkInlineScripts('<script>const one = 1;</script><script>let two = 2;</script>'), 2);
    assert.throws(
        () => checkInlineScripts('<script>const broken = ;</script>', 'fixture.html'),
        error => error instanceof SyntaxError && String(error.stack).includes('fixture.html:inline-script-1')
    );
});

test('前端脚本保持可解析且通过 defer 按依赖顺序加载', () => {
    const appSource = fs.readFileSync(path.join(root, 'public', 'js', 'app.js'), 'utf8');
    const coreSource = fs.readFileSync(path.join(root, 'public', 'js', 'flowmaster-core.js'), 'utf8');
    const html = fs.readFileSync(path.join(root, 'public', 'index.html'), 'utf8');

    new vm.Script(appSource, { filename: 'public/js/app.js' });
    new vm.Script(coreSource, { filename: 'public/js/flowmaster-core.js' });
    assert.match(html, /<script defer src="\/vendor\/vue\/vue\.global\.prod\.js"><\/script>/);
    assert.match(html, /<script defer src="\/js\/flowmaster-core\.js"><\/script>/);
    assert.match(html, /<script defer src="\/js\/app\.js"><\/script>/);
    assert.doesNotMatch(html, /<script(?![^>]*\bsrc=)[^>]*>/i);
});

test('单行错误数据不会进入表头解析且内容经过转义', () => {
    const html = core.renderTableHtml(['错误: <script>alert(1)</script>'], '小时统计');
    assert.match(html, /class="data-message/);
    assert.match(html, /&lt;script&gt;alert\(1\)&lt;\/script&gt;/);
    assert.doesNotMatch(html, /<table/);
    assert.doesNotMatch(html, /<script>alert/);
});

test('统计表格提供 caption、列头 scope 和语义化指标类', () => {
    const html = core.renderTableHtml([
        'eth0 / 每日',
        '日期  接收(GiB)  |  发送(GiB)  |  总计(GiB)',
        '----------------',
        '2026-09-15  1.00  |  2.00  |  3.00'
    ], '日统计');

    assert.match(html, /<caption class="visually-hidden">日统计<\/caption>/);
    assert.match(html, /<th scope="col">日期<\/th>/);
    assert.match(html, /class="metric-receive">1\.00<\/td>/);
    assert.match(html, /class="metric-send">2\.00<\/td>/);
    assert.match(html, /class="metric-total">3\.00<\/td>/);
});

test('表格单位格式化不会把极小非零流量重新舍入为零', () => {
    const rows = core.formatTableDataUnified([
        '日期 接收(GiB) | 发送(GiB) | 总计(GiB)',
        '----------------',
        '2026-09-15 0.00488 | 0.000977 | 0.00586'
    ], 'GiB');

    assert.match(rows[2], /0\.00488/);
    assert.match(rows[2], /0\.000977/);
    assert.doesNotMatch(rows[2], /0\.00(?:\s|$)/);
});

test('实时数据使用十进制 SI 单位并安全生成表格', () => {
    const sample = core.parseRealtimeData([
        '接收 1250 kb/秒 20 数据包/s',
        '发送 2.5 mb/秒 10 数据包/s'
    ], 1000);

    assert.equal(sample.receiveSpeed, 1.25);
    assert.equal(sample.sendSpeed, 2.5);
    assert.equal(sample.receivePackets, 20);
    assert.equal(sample.sendPackets, 10);

    const html = core.renderRealtimeTableHtml([{ ...sample, time: '<unsafe>' }], []);
    assert.match(html, /&lt;unsafe&gt;/);
    assert.doesNotMatch(html, /<unsafe>/);
    assert.match(html, /class="metric-send">2\.50 Mb\/秒<\/td>/);
});

test('实时解析兼容 vnstat 英文 bit/s，并区分 bit 与 Byte 倍率', () => {
    const bitSample = core.parseRealtimeData([
        '      rx         3.36 kbit/s             3 packets/s',
        '      tx          540 bit/s               0 packets/s'
    ], 2000);
    assert.equal(bitSample.receiveSpeed, 0.00336);
    assert.equal(bitSample.sendSpeed, 0.00054);
    assert.equal(bitSample.receivePackets, 3);
    assert.equal(bitSample.sendPackets, 0);

    const byteSample = core.parseRealtimeData([
        '接收 1 KiB/s 2 数据包/s',
        '发送 1 MiB/s 1 数据包/s'
    ], 3000);
    assert.equal(byteSample.receiveSpeed, 0.008192);
    assert.equal(byteSample.sendSpeed, 8.388608);
    assert.equal(core.convertSpeedToMbps(1, 'B/s'), 0.000008);
    assert.equal(core.convertSpeedToMbps(1, 'b/秒'), 0.000001);
    assert.ok(Number.isNaN(core.convertSpeedToMbps(1, 'unknown/s')));
});

test('请求协调器阻止同类请求重叠并使替换前响应失效', () => {
    const coordinator = new core.RequestCoordinator();
    const first = coordinator.begin('realtime');
    assert.ok(first);
    assert.equal(coordinator.begin('realtime'), null);

    const replacement = coordinator.begin('realtime', { replace: true });
    assert.ok(replacement);
    assert.equal(first.signal.aborted, true);
    assert.equal(coordinator.isCurrent(first), false);
    assert.equal(coordinator.isCurrent(replacement), true);

    let rendered = '';
    const commit = (ticket, value) => {
        if (coordinator.isCurrent(ticket)) rendered = value;
    };
    commit(replacement, 'ethB');
    commit(first, 'ethA stale');
    assert.equal(rendered, 'ethB');
    assert.equal(coordinator.finish(first), false);
    assert.equal(coordinator.finish(replacement), true);
});

test('接口和日期上下文任一变化都会拒绝旧响应', () => {
    const expected = { interfaceName: 'eth0', start: '2026-09-01', end: '2026-09-15' };
    assert.equal(core.sameRequestContext(expected, { ...expected }), true);
    assert.equal(core.sameRequestContext(expected, { ...expected, interfaceName: 'eth1' }), false);
    assert.equal(core.sameRequestContext(expected, { ...expected, end: '2026-09-16' }), false);
});

test('实时样本按接收时间判断是否过期', () => {
    assert.equal(core.isSampleStale(0, 20000, 15000), true);
    assert.equal(core.isSampleStale(5000, 20000, 15000), false);
    assert.equal(core.isSampleStale(4999, 20000, 15000), true);
});

test('页面按最近成功响应判断连接新鲜度，并尊重服务端 stale 结果', () => {
    const appSource = fs.readFileSync(path.join(root, 'public', 'js', 'app.js'), 'utf8');
    assert.match(appSource, /this\.lastSampleReceivedAt\s*=\s*Date\.now\(\)/);
    assert.match(
        appSource,
        /this\.lastRealtimeServerStale\s*\|\|\s*core\.isSampleStale\(\s*this\.lastSampleReceivedAt/s
    );
    assert.doesNotMatch(
        appSource,
        /core\.isSampleStale\(\s*this\.lastRealtimeTimestamp/s
    );
});

test('公共页面不再暴露需要管理员令牌的操作', () => {
    const html = fs.readFileSync(path.join(root, 'public', 'index.html'), 'utf8');
    const appSource = fs.readFileSync(path.join(root, 'public', 'js', 'app.js'), 'utf8');
    assert.doesNotMatch(html, /clearCache|runDiagnosis|诊断问题|清空缓存/);
    assert.doesNotMatch(appSource, /\/api\/cache\/clear|\/api\/test\/vnstat/);
});

test('页面具备主要 landmark、控件标签和动态状态语义', () => {
    const html = fs.readFileSync(path.join(root, 'public', 'index.html'), 'utf8');
    assert.match(html, /<main id="main-content"/);
    assert.match(html, /<label class="form-label" for="networkInterface">网络接口<\/label>/);
    assert.match(html, /role="status" aria-live="polite"/);
    assert.match(html, /:aria-busy=/);
    assert.match(html, /class="skip-link"/);
});

test('无接口时不伪造 eth0、不会发起空接口统计请求且暗色卡片可读', () => {
    const html = fs.readFileSync(path.join(root, 'public', 'index.html'), 'utf8');
    const appSource = fs.readFileSync(path.join(root, 'public', 'js', 'app.js'), 'utf8');
    const css = fs.readFileSync(path.join(root, 'public', 'css', 'main.css'), 'utf8');

    assert.doesNotMatch(appSource, /this\.interfaces\s*=\s*\[['"]eth0['"]\]/);
    assert.doesNotMatch(appSource, /this\.selectedInterface\s*=\s*['"]eth0['"]/);
    assert.match(appSource, /async loadRealtimeStats\([^)]*\)\s*{\s*if \(!this\.selectedInterface\)/);
    assert.match(html, /未检测到可用接口/);
    assert.match(css, /\.card\s*{[^}]*color:\s*var\(--text-color\)/s);
});
