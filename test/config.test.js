'use strict';

const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const readline = require('node:readline');
const path = require('node:path');
const test = require('node:test');

const root = path.join(__dirname, '..');

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

    assert.equal((await fetch(`${server.baseUrl}/api/version`)).status, 200);
    const limited = await fetch(`${server.baseUrl}/api/version`);
    assert.equal(limited.status, 429);
    assert.ok(Number.parseInt(limited.headers.get('retry-after'), 10) > 0);
});
