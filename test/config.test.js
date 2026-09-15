'use strict';

const assert = require('node:assert/strict');
const { spawn, spawnSync } = require('node:child_process');
const { once } = require('node:events');
const readline = require('node:readline');
const path = require('node:path');
const test = require('node:test');

const root = path.join(__dirname, '..');

function readRuntimeConfig(environment) {
    const result = spawnSync(
        process.execPath,
        ['-e', "process.stdout.write(JSON.stringify(require('./server').runtimeConfig))"],
        {
            cwd: root,
            env: { ...process.env, ...environment },
            encoding: 'utf8'
        }
    );
    assert.equal(result.status, 0, result.stderr);
    return JSON.parse(result.stdout);
}

async function startConfiguredServer(environment) {
    const script = [
        "const { app } = require('./server');",
        "const server = app.listen(0, '127.0.0.1', () => console.log(server.address().port));",
        "process.on('SIGTERM', () => server.close(() => process.exit(0)));"
    ].join('');
    const child = spawn(process.execPath, ['-e', script], {
        cwd: root,
        env: { ...process.env, ...environment },
        stdio: ['ignore', 'pipe', 'pipe']
    });
    const lines = readline.createInterface({ input: child.stdout });
    const [line] = await Promise.race([
        once(lines, 'line'),
        once(child, 'exit').then(([code]) => {
            throw new Error(`配置测试服务提前退出: ${code}`);
        })
    ]);
    const port = Number.parseInt(line, 10);
    assert.ok(Number.isInteger(port) && port > 0);
    return {
        baseUrl: `http://127.0.0.1:${port}`,
        async close() {
            lines.close();
            child.kill('SIGTERM');
            await once(child, 'exit');
        }
    };
}

test('CORS 白名单和限流配置在 Express 5 下生效', async t => {
    const server = await startConfiguredServer({
        CORS_ORIGINS: 'https://allowed.example',
        RATE_LIMIT_WINDOW_MS: '60000',
        RATE_LIMIT_MAX: '2'
    });
    t.after(() => server.close());

    const denied = await fetch(`${server.baseUrl}/api/version`, {
        headers: { Origin: 'https://denied.example' }
    });
    assert.equal(denied.status, 403);
    assert.equal((await denied.json()).error, '请求来源不被允许');

    const allowed = await fetch(`${server.baseUrl}/api/version`, {
        headers: { Origin: 'https://allowed.example' }
    });
    assert.equal(allowed.status, 200);
    assert.equal(allowed.headers.get('access-control-allow-origin'), 'https://allowed.example');

    const limited = await fetch(`${server.baseUrl}/api/version`);
    assert.equal(limited.status, 429);
    assert.ok(Number.parseInt(limited.headers.get('retry-after'), 10) > 0);
});

test('CSP 不再允许内联脚本但保留 Vue 运行时编译所需边界', async t => {
    const server = await startConfiguredServer({});
    t.after(() => server.close());

    const response = await fetch(server.baseUrl);
    assert.equal(response.status, 200);
    const csp = response.headers.get('content-security-policy');
    const scriptDirective = csp.split(';').map(value => value.trim())
        .find(value => value.startsWith('script-src'));
    assert.ok(scriptDirective);
    assert.doesNotMatch(scriptDirective, /'unsafe-inline'/);
    assert.match(scriptDirective, /'unsafe-eval'/);
});

test('请求体解析错误发生前已经计入 API 限流', async t => {
    const server = await startConfiguredServer({
        RATE_LIMIT_WINDOW_MS: '60000',
        RATE_LIMIT_MAX: '1'
    });
    t.after(() => server.close());

    const invalidJson = await fetch(`${server.baseUrl}/api/cache/clear`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: '{'
    });
    assert.equal(invalidJson.status, 400);
    assert.equal((await invalidJson.json()).error, '请求体不是有效的 JSON');
    assert.equal((await fetch(`${server.baseUrl}/api/version`)).status, 429);
});

test('未配置令牌时默认拒绝匿名管理接口', async t => {
    const server = await startConfiguredServer({
        ADMIN_TOKEN: '',
        ALLOW_ANONYMOUS_ADMIN: ''
    });
    t.after(() => server.close());

    const response = await fetch(`${server.baseUrl}/api/cache/clear`, { method: 'POST' });
    assert.equal(response.status, 403);
    assert.equal((await response.json()).error, '匿名管理接口已禁用');
});

test('显式允许匿名管理时仅接受无 Origin 或同 Host 请求', async t => {
    const server = await startConfiguredServer({
        ADMIN_TOKEN: '',
        ALLOW_ANONYMOUS_ADMIN: 'true'
    });
    t.after(() => server.close());

    const withoutOrigin = await fetch(`${server.baseUrl}/api/cache/clear`, { method: 'POST' });
    assert.equal(withoutOrigin.status, 200);

    const sameHost = await fetch(`${server.baseUrl}/api/cache/clear`, {
        method: 'POST',
        headers: { Origin: server.baseUrl }
    });
    assert.equal(sameHost.status, 200);

    const crossSite = await fetch(`${server.baseUrl}/api/cache/clear`, {
        method: 'POST',
        headers: { Origin: 'https://attacker.example' }
    });
    assert.equal(crossSite.status, 403);
    assert.equal((await crossSite.json()).error, '拒绝跨站管理请求');
});

test('数值配置严格校验格式和安全边界', () => {
    const config = readRuntimeConfig({
        PORT: '70000',
        VNSTAT_COMMAND_TIMEOUT_MS: '999',
        MAX_RANGE_DAYS: '1day',
        CACHE_MAX_SIZE: '0',
        CACHE_MAX_MEMORY_MB: '999999',
        CACHE_CLEANUP_INTERVAL: '1',
        MEMORY_MONITOR_INTERVAL: '999999999',
        RATE_LIMIT_WINDOW_MS: '100ms',
        RATE_LIMIT_MAX: '2x',
        RATE_LIMIT_MAX_CLIENTS: '0',
        VNSTAT_MAX_CONCURRENCY: '100',
        VNSTAT_MAX_QUEUE: '-1',
        REALTIME_INTERVAL_MS: '10',
        REALTIME_IDLE_TIMEOUT_MS: '10',
        REALTIME_MAX_STALE_MS: '10',
        REALTIME_MAX_ACTIVE: '100',
        REALTIME_MAX_BACKOFF_MS: '10'
    });

    assert.equal(config.port, 10089);
    assert.equal(config.commandTimeout, 15000);
    assert.equal(config.maxRangeDays, 3660);
    assert.deepEqual(config.cache, {
        maxSize: 100,
        maxMemoryMB: 50,
        cleanupInterval: 60000,
        memoryMonitorInterval: 300000
    });
    assert.equal(config.rateLimitWindowMs, 60000);
    assert.equal(config.rateLimitMax, 180);
    assert.equal(config.rateLimitMaxClients, 10000);
    assert.equal(config.vnstatMaxConcurrency, 4);
    assert.equal(config.vnstatMaxQueue, 256);
    assert.equal(config.realtimeInterval, 5000);
    assert.equal(config.realtimeIdleTimeout, 30000);
    assert.equal(config.realtimeMaxStale, 15000);
    assert.equal(config.realtimeMaxActive, 2);
    assert.equal(config.realtimeMaxBackoff, 60000);
});
