'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');

const {
    app,
    CacheManager,
    isValidInterfaceName,
    normalizeStatsLines,
    normalizeValue,
    parseInterfaceList,
    parseIsoDate,
    stripTerminalControlSequences
} = require('../server');

test('CacheManager 按 LRU 淘汰并限制条目数', () => {
    const cache = new CacheManager(2, 1);
    cache.set('a', { value: 1 });
    cache.set('b', { value: 2 });
    cache.cache.get('a').lastAccessed = 20;
    cache.cache.get('b').lastAccessed = 10;
    cache.set('c', { value: 3 });

    assert.deepEqual(cache.get('a'), { value: 1 });
    assert.equal(cache.get('b'), null);
    assert.deepEqual(cache.get('c'), { value: 3 });
    assert.equal(cache.cache.size, 2);
    cache.close();
});

test('CacheManager 拒绝超过内存上限的单个条目', () => {
    const cache = new CacheManager(2, 0.00001);
    assert.equal(cache.set('small', 'ok'), true);
    assert.equal(cache.set('oversized', 'x'.repeat(1024)), false);
    assert.equal(cache.get('oversized'), null);
    assert.equal(cache.getStats().rejected, 1);
    cache.close();
});

test('单位归一化覆盖 B 到 PiB', () => {
    assert.equal(normalizeValue('1024 B', 'MiB'), '0.00 MiB');
    assert.equal(normalizeValue('512 KiB', 'MiB'), '0.50 MiB');
    assert.equal(normalizeValue('1024 MiB', 'GiB'), '1.00 GiB');
    assert.equal(normalizeValue('1 GiB', 'MiB'), '1024.00 MiB');
    assert.equal(normalizeValue('1 TiB', 'GiB'), '1024.00 GiB');
    assert.equal(normalizeValue('1 PiB', 'TiB'), '1024.00 TiB');
});

test('接口名和 ISO 日期执行严格校验', () => {
    assert.equal(isValidInterfaceName('enp1s0.100'), true);
    assert.equal(isValidInterfaceName('eth0;reboot'), false);
    assert.equal(parseIsoDate('2024-02-29')?.toISOString(), '2024-02-29T00:00:00.000Z');
    assert.equal(parseIsoDate('2025-02-29'), null);
    assert.equal(parseIsoDate('2025-13-01'), null);
});

test('vnstat 2.13 接口列表忽略链路速率说明', () => {
    const output = 'Available interfaces: eth0 docker0 (10000 Mbit) veth0556071 (10000 Mbit)';
    assert.deepEqual(parseInterfaceList(output), ['eth0', 'docker0', 'veth0556071']);
});

test('实时输出移除 vnstat 终端控制序列', () => {
    const output = 'Sampling eth0...\u001b[1G\u001b[2K42 packets sampled in 5 seconds\r\n';
    assert.equal(
        stripTerminalControlSequences(output),
        'Sampling eth0...42 packets sampled in 5 seconds\n'
    );
});

test('vnstat 统计输出统一为 GiB', () => {
    const lines = normalizeStatsLines([
        'eth0 / 每日',
        '         日期        接收      |     发送      |    总计    |   平均速率',
        '     ------------------------+-------------+-------------+---------------',
        '     2026-08-28     1024 MiB |    512 MiB |    1.50 GiB |    1 Mbit/s',
        ''
    ], 'd', 'GiB');
    assert.ok(lines.some(line => line.includes('1.00 GiB')));
    assert.ok(lines.some(line => line.includes('0.50 GiB')));
});

test('vnstat KiB 列保持正确数值而不只替换单位', () => {
    const lines = normalizeStatsLines([
        '         时间        接收      |     发送      |    总计    |   平均速率',
        '         22:30      1.33 MiB |    2.95 KiB |    1.33 MiB |   37.14 kb/秒'
    ], '5', 'MiB');
    assert.match(lines[1], /1\.33 MiB\| 0\.00 MiB\| 1\.33 MiB/);
});

test('API 提供版本、安全响应头和参数错误', async t => {
    const server = app.listen(0, '127.0.0.1');
    await new Promise(resolve => server.once('listening', resolve));
    t.after(() => new Promise(resolve => server.close(resolve)));
    const { port } = server.address();
    const baseUrl = `http://127.0.0.1:${port}`;

    const versionResponse = await fetch(`${baseUrl}/api/version`);
    assert.equal(versionResponse.status, 200);
    assert.equal(versionResponse.headers.get('x-content-type-options'), 'nosniff');
    assert.equal(versionResponse.headers.get('access-control-allow-origin'), null);
    assert.equal((await versionResponse.json()).version, require('../package.json').version);

    const invalidInterface = await fetch(`${baseUrl}/api/stats/eth0%3Breboot/d`);
    assert.equal(invalidInterface.status, 400);

    const invalidPeriod = await fetch(`${baseUrl}/api/stats/eth0/week`);
    assert.equal(invalidPeriod.status, 400);

    const invalidDate = await fetch(`${baseUrl}/api/stats/eth0/range/2025-02-29/2025-03-01`);
    assert.equal(invalidDate.status, 400);

    const reversedDate = await fetch(`${baseUrl}/api/stats/eth0/range/2025-03-02/2025-03-01`);
    assert.equal(reversedDate.status, 400);

    const excessiveDateRange = await fetch(`${baseUrl}/api/stats/eth0/range/2010-01-01/2025-03-01`);
    assert.equal(excessiveDateRange.status, 400);

    const cacheStats = await fetch(`${baseUrl}/api/cache/stats`);
    assert.equal(cacheStats.status, 200);
    assert.equal(typeof (await cacheStats.json()).size, 'number');

    const memory = await fetch(`${baseUrl}/api/system/memory`);
    assert.equal(memory.status, 200);
    assert.match((await memory.json()).rss, /MB$/);

    const systemStatus = await fetch(`${baseUrl}/api/system/status`);
    assert.equal(systemStatus.status, 200);
    assert.equal(typeof (await systemStatus.json()).vnstat.available, 'boolean');

    const page = await fetch(`${baseUrl}/`);
    assert.equal(page.status, 200);
    assert.match(await page.text(), /FlowMaster/);

    const vueAsset = await fetch(`${baseUrl}/vendor/vue/vue.global.prod.js`);
    assert.equal(vueAsset.status, 200);

    const unknownApi = await fetch(`${baseUrl}/api/not-found`);
    assert.equal(unknownApi.status, 404);
    assert.deepEqual(await unknownApi.json(), { error: 'API 路径不存在' });
});

test('配置 ADMIN_TOKEN 后保护管理接口', async t => {
    process.env.ADMIN_TOKEN = 'test-only-token';
    t.after(() => delete process.env.ADMIN_TOKEN);
    const server = app.listen(0, '127.0.0.1');
    await new Promise(resolve => server.once('listening', resolve));
    t.after(() => new Promise(resolve => server.close(resolve)));
    const { port } = server.address();
    const url = `http://127.0.0.1:${port}/api/cache/clear`;

    assert.equal((await fetch(url, { method: 'POST' })).status, 401);
    assert.equal((await fetch(url, {
        method: 'POST',
        headers: { 'X-Admin-Token': 'test-only-token' }
    })).status, 200);
});

test('未配置令牌时拒绝跨站管理请求', async t => {
    delete process.env.ADMIN_TOKEN;
    const server = app.listen(0, '127.0.0.1');
    await new Promise(resolve => server.once('listening', resolve));
    t.after(() => new Promise(resolve => server.close(resolve)));
    const { port } = server.address();

    const response = await fetch(`http://127.0.0.1:${port}/api/cache/clear`, {
        method: 'POST',
        headers: { Origin: 'https://attacker.example' }
    });
    assert.equal(response.status, 403);
});
