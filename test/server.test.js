'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');

const {
    app,
    buildStatsResult,
    CacheManager,
    RealtimeCollectorManager,
    VnstatCommandRunner,
    cacheManager,
    isValidInterfaceName,
    normalizeStatsLines,
    normalizeValue,
    parseDatabaseInterfaceList,
    parseInterfaceList,
    parseIsoDate,
    stripTerminalControlSequences,
    translateOutput,
    vnstatRunner
} = require('../server');

async function startTestServer(t) {
    const server = app.listen(0, '127.0.0.1');
    await new Promise(resolve => server.once('listening', resolve));
    t.after(() => new Promise(resolve => server.close(resolve)));
    return `http://127.0.0.1:${server.address().port}`;
}

function createFakeClock(start = 100000) {
    let current = start;
    let nextId = 1;
    const timers = new Map();
    return {
        now: () => current,
        setTimer(callback, delay) {
            const id = nextId++;
            timers.set(id, { callback, dueAt: current + delay });
            return id;
        },
        clearTimer(id) {
            timers.delete(id);
        },
        jumpBy(milliseconds) {
            current += milliseconds;
        },
        async advanceBy(milliseconds) {
            const target = current + milliseconds;
            while (true) {
                let next = null;
                for (const [id, timer] of timers) {
                    if (timer.dueAt <= target && (!next || timer.dueAt < next.timer.dueAt)) {
                        next = { id, timer };
                    }
                }
                if (!next) break;
                current = next.timer.dueAt;
                timers.delete(next.id);
                await next.timer.callback();
            }
            current = target;
        }
    };
}

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
    assert.equal(normalizeValue('1024 B', 'MiB'), '0.000977 MiB');
    assert.equal(normalizeValue('512 KiB', 'MiB'), '0.50 MiB');
    assert.equal(normalizeValue('1024 MiB', 'GiB'), '1.00 GiB');
    assert.equal(normalizeValue('1 GiB', 'MiB'), '1024.00 MiB');
    assert.equal(normalizeValue('1 TiB', 'GiB'), '1024.00 GiB');
    assert.equal(normalizeValue('1 PiB', 'TiB'), '1024.00 TiB');
    assert.equal(normalizeValue('1 MiB', 'GiB'), '0.000977 GiB');
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

test('英文 vnstat 日统计日期表头被完整翻译', () => {
    const output = translateOutput([
        'eth0 / daily',
        ' date        received | transmitted | total | avg. rate',
        ' ---------------------+-------------+-------+----------',
        ' 2026-09-15        5 MiB |       3 MiB | 8 MiB | 1 kbit/s'
    ].join('\n'));

    assert.match(output, /^eth0 \/ 每日/m);
    assert.match(output, /^ 日期\s+接收 \| 发送 \| 总计 \| 平均速率/m);
});

test('vnstat KiB 列保持正确数值而不只替换单位', () => {
    const lines = normalizeStatsLines([
        '         时间        接收      |     发送      |    总计    |   平均速率',
        '         22:30      1.33 MiB |    2.95 KiB |    1.33 MiB |   37.14 kb/秒'
    ], '5', 'MiB');
    assert.match(lines[1], /1\.33 MiB\| 0\.00288 MiB\| 1\.33 MiB/);
});

test('低速 bit/s 被翻译，旧版 MM/DD/YY 统计列保持对齐', () => {
    const realtime = translateOutput('tx 540 bit/s 0 packets/s');
    assert.equal(realtime, '发送 540 b/秒 0 数据包/s');

    const result = buildStatsResult([
        'eth0 / daily',
        ' day        received | transmitted | total | avg. rate',
        ' ---------------------+-------------+-------+----------',
        ' 09/15/26        5 MiB |       3 MiB | 8 MiB | 1 kbit/s',
        ''
    ].join('\n'), 'range', 'GiB');

    assert.ok(result.data.some(line =>
        /09\/15\/26\s+\| 0\.00488 GiB\| 0\.00293 GiB\| 0\.00781 GiB\| 1 kb\/秒/.test(line)
    ));
    assert.deepEqual(result.series.points, [
        { label: '09/15/26', rx: 5, tx: 3, total: 8 }
    ]);
});

test('数据库接口列表按行解析、去重且拒绝非法名称', () => {
    assert.deepEqual(
        parseDatabaseInterfaceList('eth0\nens3\neth0\neth0;reboot\n\n'),
        ['eth0', 'ens3']
    );
});

test('结构化数值保留旧 data 舍入前的流量精度', () => {
    const result = buildStatsResult([
        'eth0 / yearly',
        ' year        received | transmitted | total | avg. rate',
        ' ----------------------+-------------+-------+----------',
        ' 2026            1 GiB |     512 MiB | 1.50 GiB | 1 kbit/s',
        ''
    ].join('\n'), 'y');

    assert.ok(result.data.some(line => line.includes('0.000977 TiB')));
    assert.deepEqual(result.series, {
        unit: 'MiB',
        points: [{ label: '2026', rx: 1024, tx: 512, total: 1536 }]
    });
});

test('vnstat 全局执行器限制并发并固定 C locale', async () => {
    let active = 0;
    let observedMax = 0;
    const locales = [];
    const runner = new VnstatCommandRunner({
        maxConcurrency: 2,
        maxQueue: 20,
        execFileImpl(command, args, options, callback) {
            assert.equal(command, 'vnstat');
            active++;
            observedMax = Math.max(observedMax, active);
            locales.push([options.env.LC_ALL, options.env.LANG]);
            setTimeout(() => {
                active--;
                callback(null, args.join(' '), '');
            }, 5);
        }
    });

    const results = await Promise.all(
        Array.from({ length: 8 }, (_, index) => runner.execute([`job-${index}`]))
    );
    assert.equal(results.length, 8);
    assert.equal(observedMax, 2);
    assert.ok(locales.every(locale => locale[0] === 'C' && locale[1] === 'C'));
    assert.deepEqual(runner.getStats(), {
        active: 0,
        queued: 0,
        maxConcurrency: 2,
        maxQueue: 20
    });
});

test('vnstat 执行队列满时快速拒绝而不是无限堆积', async () => {
    const callbacks = [];
    const runner = new VnstatCommandRunner({
        maxConcurrency: 1,
        maxQueue: 1,
        execFileImpl(command, args, options, callback) {
            callbacks.push(callback);
        }
    });

    const active = runner.execute(['active']);
    const queued = runner.execute(['queued']);
    await assert.rejects(
        runner.execute(['rejected']),
        error => error.code === 'VNSTAT_QUEUE_FULL'
    );
    callbacks.shift()(null, 'active', '');
    callbacks.shift()(null, 'queued', '');
    assert.deepEqual(await Promise.all([active, queued]), ['active', 'queued']);
});

test('实时采集限制活跃接口并按最后访问时间回收', async () => {
    const clock = createFakeClock();
    const cache = new CacheManager(20, 1);
    let calls = 0;
    const manager = new RealtimeCollectorManager({
        cache,
        runCommand: async () => {
            calls++;
            return 'rx 1 kbit/s 1 packets/s\ntx 2 kbit/s 2 packets/s\n';
        },
        intervalMs: 5,
        idleTimeoutMs: 30,
        maxStaleMs: 10,
        maxActive: 2,
        maxBackoffMs: 40,
        now: clock.now,
        setTimer: clock.setTimer,
        clearTimer: clock.clearTimer,
        logger: { error() {} }
    });
    manager.start();

    await manager.getSample('eth0');
    await manager.getSample('ens3');
    await manager.getSample('docker0');
    assert.deepEqual(
        manager.getStateSnapshot().map(state => state.interfaceName),
        ['ens3', 'docker0']
    );

    await clock.advanceBy(30);
    assert.deepEqual(manager.getStateSnapshot(), []);
    assert.ok(calls >= 3);
    manager.stop();
    cache.close();
});

test('实时采集器不会驱逐执行中的状态来绕过活跃上限', async () => {
    const cache = new CacheManager(20, 1);
    const resolvers = [];
    let calls = 0;
    const manager = new RealtimeCollectorManager({
        cache,
        maxActive: 2,
        runCommand: () => {
            calls++;
            return new Promise(resolve => resolvers.push(resolve));
        },
        logger: { error() {} }
    });

    const first = manager.getSample('eth0');
    const second = manager.getSample('ens3');
    await assert.rejects(
        manager.getSample('docker0'),
        error => error.code === 'REALTIME_CAPACITY_FULL'
    );
    assert.equal(calls, 2);
    assert.equal(manager.getStateSnapshot().length, 2);
    assert.ok(manager.getStateSnapshot().every(state => state.inFlight));

    resolvers[0]('rx 1 kbit/s 1 packets/s\ntx 2 kbit/s 2 packets/s\n');
    resolvers[1]('rx 1 kbit/s 1 packets/s\ntx 2 kbit/s 2 packets/s\n');
    await Promise.all([first, second]);
    manager.stop();
    cache.close();
});

test('实时采集失败执行指数退避并显式返回陈旧缓存', async () => {
    const clock = createFakeClock();
    const cache = new CacheManager(20, 1);
    let calls = 0;
    let failing = false;
    const manager = new RealtimeCollectorManager({
        cache,
        runCommand: async () => {
            calls++;
            if (failing) throw new Error('fake vnstat failure');
            return 'rx 1 kbit/s 1 packets/s\ntx 2 kbit/s 2 packets/s\n';
        },
        intervalMs: 5,
        idleTimeoutMs: 100,
        maxStaleMs: 10,
        maxActive: 2,
        maxBackoffMs: 40,
        now: clock.now,
        setTimer: clock.setTimer,
        clearTimer: clock.clearTimer,
        logger: { error() {} }
    });

    const fresh = await manager.getSample('eth0');
    assert.equal(fresh.stale, false);
    clock.jumpBy(20);
    failing = true;

    const firstStale = await manager.getSample('eth0');
    assert.equal(firstStale.stale, true);
    assert.equal(firstStale.ageMs, 20);
    assert.equal(calls, 2);
    const firstState = manager.getStateSnapshot()[0];
    assert.equal(firstState.failures, 1);
    assert.equal(firstState.nextAttemptAt - clock.now(), 5);

    const duringBackoff = await manager.getSample('eth0');
    assert.equal(duringBackoff.stale, true);
    assert.equal(calls, 2);
    clock.jumpBy(5);
    await manager.getSample('eth0');
    assert.equal(calls, 3);
    const secondState = manager.getStateSnapshot()[0];
    assert.equal(secondState.failures, 2);
    assert.equal(secondState.nextAttemptAt - clock.now(), 10);
    manager.stop();
    cache.close();
});

test('相同接口的并发实时请求复用一个 fake vnstat 命令', async () => {
    const cache = new CacheManager(20, 1);
    let calls = 0;
    let finish;
    const manager = new RealtimeCollectorManager({
        cache,
        runCommand: () => {
            calls++;
            return new Promise(resolve => { finish = resolve; });
        },
        logger: { error() {} }
    });

    const first = manager.getSample('eth0');
    const second = manager.getSample('eth0');
    assert.equal(calls, 1);
    finish('rx 1 kbit/s 1 packets/s\ntx 2 kbit/s 2 packets/s\n');
    const [firstResult, secondResult] = await Promise.all([first, second]);
    assert.deepEqual(firstResult.data, secondResult.data);
    assert.equal(firstResult.stale, false);
    manager.stop();
    cache.close();
});

test('接口及非实时统计 API 使用 dbiflist 和 single-flight', async t => {
    assert.equal(vnstatRunner.getStats().active, 0);
    cacheManager.clear();
    const originalExecutor = vnstatRunner.execFileImpl;
    const calls = [];
    vnstatRunner.execFileImpl = (command, args, options, callback) => {
        calls.push({ args: [...args], locale: options.env.LC_ALL });
        const today = new Date().toISOString().slice(0, 10);
        const output = args[0] === '--dbiflist'
            ? 'eth0\nens3\n'
            : [
                'eth0 / daily',
                ' date        received | transmitted | total | avg. rate',
                ' ---------------------+-------------+-------+----------',
                ` ${today}        5 MiB |       3 MiB | 8 MiB | 1 kbit/s`,
                ''
            ].join('\n');
        setTimeout(() => callback(null, output, ''), 10);
    };
    t.after(() => {
        vnstatRunner.execFileImpl = originalExecutor;
        cacheManager.clear();
    });
    const baseUrl = await startTestServer(t);

    const interfaceResponses = await Promise.all([
        fetch(`${baseUrl}/api/interfaces`),
        fetch(`${baseUrl}/api/interfaces`),
        fetch(`${baseUrl}/api/interfaces`)
    ]);
    assert.ok(interfaceResponses.every(response => response.status === 200));
    assert.deepEqual(await interfaceResponses[0].json(), { interfaces: ['eth0', 'ens3'] });
    assert.equal(calls.filter(call => call.args[0] === '--dbiflist').length, 1);
    assert.equal(calls.filter(call => call.args[0] === '--iflist').length, 0);

    const statResponses = await Promise.all([
        fetch(`${baseUrl}/api/stats/eth0/d`),
        fetch(`${baseUrl}/api/stats/eth0/d`)
    ]);
    assert.ok(statResponses.every(response => response.status === 200));
    const stats = await statResponses[0].json();
    assert.ok(Array.isArray(stats.data));
    assert.equal(stats.series.points[0].rx, 5);
    assert.equal(calls.filter(call => call.args[0] === '-d').length, 1);

    const today = new Date().toISOString().slice(0, 10);
    const rangeResponses = await Promise.all([
        fetch(`${baseUrl}/api/stats/eth0/range/${today}/${today}`),
        fetch(`${baseUrl}/api/stats/eth0/range/${today}/${today}`)
    ]);
    assert.ok(rangeResponses.every(response => response.status === 200));
    assert.equal(calls.filter(call => call.args.includes('--begin')).length, 1);
    assert.ok(calls.every(call => call.locale === 'C'));
});

test('dbiflist 不可用时兼容 fallback，且不虚构 eth0', async t => {
    assert.equal(vnstatRunner.getStats().active, 0);
    cacheManager.clear();
    const originalExecutor = vnstatRunner.execFileImpl;
    let dbiflistMode = 'fallback';
    vnstatRunner.execFileImpl = (command, args, options, callback) => {
        setImmediate(() => {
            if (args[0] === '--dbiflist') {
                if (dbiflistMode === 'empty') return callback(null, '', '');
                const error = new Error('unknown option');
                error.code = 1;
                return callback(error, '', 'unknown option');
            }
            if (args[0] === '--iflist') {
                return callback(null, 'Available interfaces: eth0 ens3 docker0 (10000 Mbit)', '');
            }
            if (args.includes('--oneline') && args.includes('ens3')) {
                return callback(null, 'ens3;summary', '');
            }
            return callback(new Error('not tracked'), '', '');
        });
    };
    t.after(() => {
        vnstatRunner.execFileImpl = originalExecutor;
        cacheManager.clear();
    });
    const baseUrl = await startTestServer(t);

    const fallback = await fetch(`${baseUrl}/api/interfaces`);
    assert.deepEqual(await fallback.json(), { interfaces: ['ens3'] });

    cacheManager.clear();
    dbiflistMode = 'empty';
    const empty = await fetch(`${baseUrl}/api/interfaces`);
    assert.deepEqual(await empty.json(), { interfaces: [] });
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
    assert.deepEqual(await versionResponse.json(), { version: require('../package.json').version });

    process.env.FLOWMASTER_INSTANCE_TOKEN = 'temporary-instance-token';
    t.after(() => delete process.env.FLOWMASTER_INSTANCE_TOKEN);
    const unmatchedInstance = await fetch(`${baseUrl}/api/version`, {
        headers: { 'X-FlowMaster-Instance-Token': 'wrong-token' }
    });
    assert.deepEqual(await unmatchedInstance.json(), { version: require('../package.json').version });
    const matchedInstance = await fetch(`${baseUrl}/api/version`, {
        headers: { 'X-FlowMaster-Instance-Token': 'temporary-instance-token' }
    });
    assert.deepEqual(await matchedInstance.json(), {
        version: require('../package.json').version,
        instanceTokenMatched: true
    });

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
