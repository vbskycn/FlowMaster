const express = require('express');
require('dotenv').config({ quiet: true });
const { execFile } = require('child_process');
const cors = require('cors');
const crypto = require('crypto');
const path = require('path');
const app = express();
const packageJson = require('./package.json');

function parsePositiveInteger(value, fallback) {
    const parsed = Number.parseInt(value, 10);
    return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
}

// 运行配置只从进程环境读取；生产环境由 PM2/systemd 显式注入。
const port = parsePositiveInteger(process.env.PORT, 10089);
const host = process.env.HOST || '0.0.0.0';
const commandTimeout = parsePositiveInteger(process.env.VNSTAT_COMMAND_TIMEOUT_MS, 15000);
const maxRangeDays = parsePositiveInteger(process.env.MAX_RANGE_DAYS, 3660);

// 缓存配置
const cacheConfig = {
    maxSize: parsePositiveInteger(process.env.CACHE_MAX_SIZE, 100),
    maxMemoryMB: parsePositiveInteger(process.env.CACHE_MAX_MEMORY_MB, 50),
    cleanupInterval: parsePositiveInteger(process.env.CACHE_CLEANUP_INTERVAL, 60000),
    memoryMonitorInterval: parsePositiveInteger(process.env.MEMORY_MONITOR_INTERVAL, 300000)
};

// 缓存管理器类
class CacheManager {
    constructor(maxSize = 100, maxMemoryMB = 50) {
        this.cache = new Map();
        this.maxSize = maxSize;
        this.maxMemoryBytes = maxMemoryMB * 1024 * 1024;
        this.stats = {
            hits: 0,
            misses: 0,
            sets: 0,
            deletes: 0
        };
        
        // 定期清理过期缓存
        this.cleanupTimer = setInterval(() => this.cleanup(), cacheConfig.cleanupInterval);
        this.cleanupTimer.unref?.();
    }

    // 生成缓存键
    generateKey(prefix, ...params) {
        return `${prefix}:${params.join(':')}`;
    }

    // 获取缓存
    get(key) {
        const item = this.cache.get(key);
        if (!item) {
            this.stats.misses++;
            return null;
        }

        // 检查是否过期
        if (Date.now() > item.expiresAt) {
            this.cache.delete(key);
            this.stats.misses++;
            return null;
        }

        // 更新访问时间（LRU）
        item.lastAccessed = Date.now();
        this.stats.hits++;
        return item.data;
    }

    // 后台采集读取缓存时不应污染面向 API 请求的命中率。
    peek(key) {
        const item = this.cache.get(key);
        if (!item || Date.now() > item.expiresAt) {
            if (item) this.cache.delete(key);
            return null;
        }
        item.lastAccessed = Date.now();
        return item.data;
    }

    // 设置缓存
    set(key, data, ttlMs = 60000) {
        const item = {
            data,
            expiresAt: Date.now() + ttlMs,
            lastAccessed: Date.now(),
            size: this.estimateSize(data)
        };

        // 更新同名条目前先移除旧值，避免容量和内存估算失真。
        this.cache.delete(key);
        while (
            this.cache.size > 0 &&
            (this.cache.size >= this.maxSize || this.getCurrentMemoryUsage() + item.size > this.maxMemoryBytes)
        ) {
            if (!this.evictLRU()) break;
        }

        this.cache.set(key, item);
        this.stats.sets++;
    }

    // 删除缓存
    delete(key) {
        const deleted = this.cache.delete(key);
        if (deleted) {
            this.stats.deletes++;
        }
        return deleted;
    }

    // 清理过期缓存
    cleanup() {
        const now = Date.now();
        for (const [key, item] of this.cache.entries()) {
            if (now > item.expiresAt) {
                this.cache.delete(key);
            }
        }
    }

    // 清理LRU项目
    evictLRU() {
        let oldestKey = null;
        let oldestTime = Date.now();

        for (const [key, item] of this.cache.entries()) {
            if (item.lastAccessed < oldestTime) {
                oldestTime = item.lastAccessed;
                oldestKey = key;
            }
        }

        if (oldestKey) {
            this.cache.delete(oldestKey);
            this.stats.deletes++;
            return true;
        }
        return false;
    }

    // 估算数据大小（字节）
    estimateSize(data) {
        if (typeof data === 'string') {
            return Buffer.byteLength(data, 'utf8');
        }
        if (typeof data === 'object') {
            return Buffer.byteLength(JSON.stringify(data), 'utf8');
        }
        return 8; // 基本类型估算
    }

    // 获取当前内存使用
    getCurrentMemoryUsage() {
        let totalSize = 0;
        for (const item of this.cache.values()) {
            totalSize += item.size;
        }
        return totalSize;
    }

    // 获取缓存统计
    getStats() {
        const hitRate = this.stats.hits + this.stats.misses > 0 
            ? (this.stats.hits / (this.stats.hits + this.stats.misses) * 100).toFixed(2)
            : 0;
        
        return {
            ...this.stats,
            hitRate: `${hitRate}%`,
            size: this.cache.size,
            maxSize: this.maxSize,
            memoryUsage: `${(this.getCurrentMemoryUsage() / 1024 / 1024).toFixed(2)}MB`,
            maxMemory: `${(this.maxMemoryBytes / 1024 / 1024).toFixed(2)}MB`
        };
    }

    // 清空所有缓存
    clear() {
        this.cache.clear();
    }


    close() {
        clearInterval(this.cleanupTimer);
    }
}

// 创建全局缓存实例
const cacheManager = new CacheManager(cacheConfig.maxSize, cacheConfig.maxMemoryMB);

// 翻译映射
const translations = {
    'month': '月份',
    'day': '日期',
    'hour': '小时',
    'rx': '接收',
    'tx': '发送',
    'total': '总计',
    'avg. rate': '平均速率',
    'estimated': '预计',
    'daily': '每日',
    'monthly': '每月',
    'hourly': '每小时',
    'yearly': '每年',
    'year': '年份',
    'time': '时间',
    'Available interfaces': '可用接口',
    'received': '接收',
    'transmitted': '发送',
    'Sampling': '正在采样',
    'seconds average': '秒平均值',
    'packets sampled in': '个数据包采样于',
    'seconds': '秒',
    'Traffic average for': '流量平均值 -',
    'current rate': '当前速率',
    'bytes': '字节',
    'packets': '数据包',
    'packets/s': '包/秒',
    'bits/s': 'b/秒',
    'kbit/s': 'kb/秒',
    'Mbit/s': 'Mb/秒',
    'Gbit/s': 'Gb/秒',
    'KiB/s': 'KB/秒',
    'MiB/s': 'MB/秒',
    'GiB/s': 'GB/秒',
    'yesterday': '昨天',
    'today': '今天',
    'last 5 minutes': '最近5分钟',
    'last hour': '最近1小时',
    'last day': '最近24小时',
    'last month': '最近30天'
};

function escapeRegExp(value) {
    return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

// 预编译正则表达式以提高性能，并避免映射键被当作正则语法。
const compiledTranslations = Object.entries(translations).map(([key, value]) => ({
    regex: new RegExp(`\\b${escapeRegExp(key)}\\b`, 'gi'),
    value
}));

// 预编译特殊处理正则表达式
const samplingRegex = /Sampling ([^ ]+) \((\d+) seconds average\)/;
const packetsSampledRegex = /(\d+) packets sampled in (\d+) seconds/;
const trafficAverageRegex = /Traffic average for (.+)/;

// 周期到单位的映射表
const periodUnitMap = {
    '5': 'MiB',   // 5分钟
    'h': 'MiB',  // 小时
    'd': 'GiB',  // 天
    'm': 'GiB',  // 月
    'y': 'TiB'   // 年
};

// 翻译函数
function translateOutput(text) {
    const lines = text.split('\n');
    return lines.map(line => {
        // 特殊处理采样信息
        if (line.includes('Sampling')) {
            return line
                .replace(samplingRegex, '正在采样 $1 ($2秒平均值)')
                .replace(packetsSampledRegex, '$1 个数据包采样于 $2 秒');
        }
        
        // 特殊处理流量平均值
        if (line.includes('Traffic average for')) {
            return line.replace(trafficAverageRegex, '流量平均值 - $1');
        }

        // 使用预编译正则表达式替换其他常规文本
        for (const { regex, value } of compiledTranslations) {
            line = line.replace(regex, value);
        }

        return line;
    }).join('\n');
}

// 修改时间处理函数
function filterStatsByTime(lines, period) {
    let isHeader = true; // 用于标记表头部分
    const headers = []; // 存储表头行
    const currentTime = new Date();

    return lines.filter(line => {
        // 保存表头信息
        if (isHeader) {
            if (line.includes('---')) {
                headers.push(line);
                isHeader = false; // 遇到分隔线后结束表头部分
                return true;
            }
            headers.push(line);
            return true;
        }

        // 空行保留
        if (!line.trim()) {
            return true;
        }

        let match;
        
        switch(period) {
            case 'minutes':
                // 匹配时间格式 HH:mm
                match = line.match(/(\d{2}):(\d{2})/);
                if (match) {
                    const [hours, minutes] = match.slice(1).map(Number);
                    const lineTime = new Date();
                    lineTime.setHours(hours, minutes, 0, 0);
                    
                    // 如果时间大于当前时间，说明是前一天的数据
                    if (lineTime > currentTime) {
                        lineTime.setDate(lineTime.getDate() - 1);
                    }
                    
                    // 检查是否在最近60分钟内
                    return (currentTime - lineTime) <= 60 * 60 * 1000;
                }
                return false;
                
            case 'hours':
                // 匹配时间格式 HH:mm
                match = line.match(/(\d{2}):(\d{2})/);
                if (match) {
                    const [hours] = match.slice(1).map(Number);
                    const lineTime = new Date();
                    lineTime.setHours(hours, 0, 0, 0);
                    
                    // 如果时间大于当前时间，说明是前一天的数据
                    if (lineTime > currentTime) {
                        lineTime.setDate(lineTime.getDate() - 1);
                    }
                    
                    // 检查是否在最近12小时内
                    return (currentTime - lineTime) <= 12 * 60 * 60 * 1000;
                }
                return false;
                
            case 'days':
                // 匹配日期格式 MM/DD/YY 或 YYYY-MM-DD
                match = line.match(/(\d{2})\/(\d{2})\/(\d{2})/) || line.match(/(\d{4})-(\d{2})-(\d{2})/);
                if (match) {
                    let lineTime;
                    if (match[0].includes('/')) {
                        // MM/DD/YY 格式
                        const [month, day, year] = match.slice(1).map(Number);
                        lineTime = new Date(2000 + year, month - 1, day);
                    } else {
                        // YYYY-MM-DD 格式
                        const [year, month, day] = match.slice(1).map(Number);
                        lineTime = new Date(year, month - 1, day);
                    }
                    
                    // 检查是否在最近12天内
                    const diffTime = currentTime - lineTime;
                    return diffTime <= 12 * 24 * 60 * 60 * 1000 && diffTime >= 0;
                }
                return false;
        }
        return false;
    });
}

function normalizeValue(value, targetUnit) {
    if (!value) return value;
    const match = value.match(/([\d.]+)\s*(MiB|GiB|TiB)?/i);
    if (!match) return value;

    let valueInMiB = Number.parseFloat(match[1]);
    const sourceUnit = (match[2] || 'MiB').toUpperCase();
    if (sourceUnit === 'GIB') valueInMiB *= 1024;
    if (sourceUnit === 'TIB') valueInMiB *= 1024 * 1024;

    if (targetUnit === 'GiB') return `${(valueInMiB / 1024).toFixed(2)} GiB`;
    if (targetUnit === 'TiB') return `${(valueInMiB / (1024 * 1024)).toFixed(2)} TiB`;
    return `${valueInMiB.toFixed(2)} MiB`;
}

function normalizeStatsLines(lines, period, targetUnit = periodUnitMap[period] || 'MiB') {
    return lines.map(line => {
        if (line.includes('---') || !line.trim()) return line;
        if ((period === 'm' || period === 'y') && line.includes('预计')) return null;

        if (line.includes('接收')) {
            for (const label of ['时间', '小时', '日期', '月份', '年份']) {
                if (line.includes(label)) {
                    return `${label}\t| 接收(${targetUnit})\t| 发送(${targetUnit})\t| 总计(${targetUnit})\t| 平均速率`;
                }
            }
        }

        line = line.replace(/^(\s*\d{2}(:\d{2})?)(\s+)/, '$1 |$3');
        line = line.replace(/^(\s*\d{4}-\d{2}-\d{2})(\s+)/, '$1 |$2');
        line = line.replace(/^(\s*\d{4}-\d{2})(\s+)/, '$1 |$2');
        line = line.replace(/^(\s*\d{4})(\s+)/, '$1 |$2');

        const parts = line.split('|');
        if (parts.length < 4) return line;
        parts[1] = ` ${normalizeValue(parts[1].trim(), targetUnit)}`;
        parts[2] = ` ${normalizeValue(parts[2].trim(), targetUnit)}`;
        parts[3] = ` ${normalizeValue(parts[3].trim(), targetUnit)}`;
        return parts.join('|');
    }).filter(Boolean);
}

function formatStatsOutput(stdout, period) {
    let lines = translateOutput(stdout).split('\n');
    if (period === '5') lines = filterStatsByTime(lines, 'minutes');
    if (period === 'h') lines = filterStatsByTime(lines, 'hours');
    if (period === 'd') lines = filterStatsByTime(lines, 'days');
    if (period === 'l') return lines;
    return normalizeStatsLines(lines, period);
}

function isValidInterfaceName(interfaceName) {
    return typeof interfaceName === 'string' && /^[a-zA-Z0-9][a-zA-Z0-9:._-]*$/.test(interfaceName);
}

function parseInterfaceList(output) {
    const line = String(output || '')
        .split('\n')
        .find(candidate => candidate.includes('Available interfaces:'));
    if (!line) return [];

    const tokens = line.replace(/^.*Available interfaces:\s*/, '').trim().split(/\s+/);
    const interfaces = [];
    let insideDetails = false;
    for (const token of tokens) {
        if (token.startsWith('(')) insideDetails = true;
        if (!insideDetails && isValidInterfaceName(token)) interfaces.push(token);
        if (insideDetails && token.endsWith(')')) insideDetails = false;
    }
    return interfaces;
}

function parseIsoDate(value) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(value || '')) return null;
    const [year, month, day] = value.split('-').map(Number);
    const parsed = new Date(Date.UTC(year, month - 1, day));
    if (
        parsed.getUTCFullYear() !== year ||
        parsed.getUTCMonth() !== month - 1 ||
        parsed.getUTCDate() !== day
    ) return null;
    return parsed;
}

function runVnstat(args, options, callback) {
    const normalizedOptions = typeof options === 'function' ? {} : options;
    const normalizedCallback = typeof options === 'function' ? options : callback;
    execFile('vnstat', args, {
        timeout: commandTimeout,
        maxBuffer: 1024 * 1024,
        windowsHide: true,
        ...normalizedOptions
    }, normalizedCallback);
}

function runVnstatPromise(args, options = {}) {
    return new Promise((resolve, reject) => {
        runVnstat(args, options, (error, stdout, stderr) => {
            if (error) {
                error.stderr = stderr;
                reject(error);
                return;
            }
            resolve(stdout);
        });
    });
}

// ========== 主动定时采集和缓存vnstat数据 ========== //
const REALTIME_CACHE_SIZE = 20;
const REALTIME_INTERVAL = 5000; // 5秒
const PERIODS = ['5', 'h', 'd', 'm', 'y'];

// 记录采集状态和计时器，避免同一接口的慢命令重叠执行。
const startedRealtime = new Set();
const startedPeriod = new Set();
const collectionTimers = new Set();
let collectionsEnabled = false;

function scheduleAfter(task, delay) {
    const timer = setTimeout(async () => {
        collectionTimers.delete(timer);
        await task();
    }, delay);
    timer.unref?.();
    collectionTimers.add(timer);
}

function scheduleRealtimeCollection(interfaceName) {
    if (startedRealtime.has(interfaceName)) return;
    startedRealtime.add(interfaceName);

    const collect = async () => {
        const startedAt = Date.now();
        try {
            const stdout = await runVnstatPromise(['-tr', '5', '-i', interfaceName], { timeout: commandTimeout });
            if (stdout) {
                const entry = {
                    timestamp: Date.now(),
                    data: translateOutput(stdout).split('\n')
                };
                const queue = cacheManager.peek(`realtime:${interfaceName}`) || [];
                queue.push(entry);
                if (queue.length > REALTIME_CACHE_SIZE) queue.shift();
                cacheManager.set(`realtime:${interfaceName}`, queue, REALTIME_CACHE_SIZE * REALTIME_INTERVAL * 2);
            }
        } catch (error) {
            console.error(`实时采集接口 ${interfaceName} 失败:`, error.message);
        } finally {
            if (collectionsEnabled) {
                scheduleAfter(collect, Math.max(0, REALTIME_INTERVAL - (Date.now() - startedAt)));
            }
        }
    };

    void collect();
}

function schedulePeriodCollection(interfaceName, period) {
    const key = `${interfaceName}:${period}`;
    if (startedPeriod.has(key)) return;
    startedPeriod.add(key);

    const collect = async () => {
        const refreshInterval = getCacheTimeForPeriod(period);
        try {
            const args = period === '5' ? ['-5', '-i', interfaceName] : [`-${period}`, '-i', interfaceName];
            const stdout = await runVnstatPromise(args);
            if (stdout) {
                cacheManager.set(
                    `stats:${interfaceName}:${period}`,
                    { data: formatStatsOutput(stdout, period) },
                    refreshInterval * 2
                );
            }
        } catch (error) {
            console.error(`周期采集接口 ${interfaceName}/${period} 失败:`, error.message);
        } finally {
            if (collectionsEnabled) scheduleAfter(collect, refreshInterval);
        }
    };

    void collect();
}

// 启动时获取所有接口并为每个接口启动定时采集
function startAllScheduledCollections() {
    collectionsEnabled = true;
    runVnstat(['--iflist'], (error, stdout) => {
        let allInterfaces = [];
        if (!error && stdout) {
            allInterfaces = parseInterfaceList(stdout);
        }
        if (allInterfaces.length === 0) allInterfaces = ['eth0'];
        allInterfaces.forEach(iface => {
            scheduleRealtimeCollection(iface);
            PERIODS.forEach(period => schedulePeriodCollection(iface, period));
        });
    });
}

function stopAllScheduledCollections() {
    collectionsEnabled = false;
    for (const timer of collectionTimers) clearTimeout(timer);
    collectionTimers.clear();
    startedRealtime.clear();
    startedPeriod.clear();
}

if (process.env.TRUST_PROXY === 'true') app.set('trust proxy', 1);

const corsOrigins = (process.env.CORS_ORIGINS || '')
    .split(',')
    .map(value => value.trim())
    .filter(Boolean);

if (corsOrigins.length > 0) {
    app.use(cors({
        origin(origin, callback) {
            if (!origin || corsOrigins.includes(origin)) return callback(null, true);
            return callback(new Error('来源不在 CORS 白名单中'));
        }
    }));
}

app.use((req, res, next) => {
    res.set({
        'X-Content-Type-Options': 'nosniff',
        'X-Frame-Options': 'DENY',
        'Referrer-Policy': 'no-referrer',
        'Permissions-Policy': 'camera=(), microphone=(), geolocation=()',
        // 当前无构建版 Vue 需要运行时编译模板，因此暂时保留 unsafe-eval；脚本来源仍限制为本站。
        'Content-Security-Policy': "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'none'"
    });
    next();
});

app.use(express.json({ limit: '16kb' }));

const rateLimitWindowMs = parsePositiveInteger(process.env.RATE_LIMIT_WINDOW_MS, 60000);
const rateLimitMax = parsePositiveInteger(process.env.RATE_LIMIT_MAX, 180);
const requestBuckets = new Map();
app.use('/api', (req, res, next) => {
    const now = Date.now();
    const bucket = requestBuckets.get(req.ip);
    if (!bucket || now >= bucket.resetAt) {
        requestBuckets.set(req.ip, { count: 1, resetAt: now + rateLimitWindowMs });
        return next();
    }
    bucket.count++;
    if (bucket.count > rateLimitMax) {
        res.set('Retry-After', Math.ceil((bucket.resetAt - now) / 1000));
        return res.status(429).json({ error: '请求过于频繁，请稍后重试' });
    }
    next();
});

const bucketCleanupTimer = setInterval(() => {
    const now = Date.now();
    for (const [ip, bucket] of requestBuckets) {
        if (now >= bucket.resetAt) requestBuckets.delete(ip);
    }
}, rateLimitWindowMs);
bucketCleanupTimer.unref?.();

app.use('/vendor/bootstrap', express.static(path.join(__dirname, 'node_modules/bootstrap/dist')));
app.use('/vendor/bootstrap-icons', express.static(path.join(__dirname, 'node_modules/bootstrap-icons/font')));
app.use('/vendor/chart.js', express.static(path.join(__dirname, 'node_modules/chart.js/dist')));
app.use('/vendor/vue', express.static(path.join(__dirname, 'node_modules/vue/dist')));
app.use('/vendor/axios', express.static(path.join(__dirname, 'node_modules/axios/dist')));
app.use(express.static(path.join(__dirname, 'public')));

function requireAdminIfConfigured(req, res, next) {
    const expected = process.env.ADMIN_TOKEN;
    if (!expected) {
        const origin = req.get('Origin');
        if (!origin) return next();
        try {
            if (new URL(origin).host === req.get('host')) return next();
        } catch (_) {
            // 非法 Origin 按跨站请求处理。
        }
        return res.status(403).json({ error: '拒绝跨站管理请求' });
    }
    const provided = req.get('X-Admin-Token') || '';
    const expectedBuffer = Buffer.from(expected);
    const providedBuffer = Buffer.from(provided);
    if (
        expectedBuffer.length !== providedBuffer.length ||
        !crypto.timingSafeEqual(expectedBuffer, providedBuffer)
    ) {
        return res.status(401).json({ error: '需要管理员凭据' });
    }
    next();
}

// 获取网络接口列表
app.get('/api/interfaces', async (req, res) => {
    try {
        // 检查缓存
        const cacheKey = cacheManager.generateKey('interfaces');
        const cachedData = cacheManager.get(cacheKey);
        
        if (cachedData) {
            return res.json(cachedData);
        }

        // 获取所有接口列表
        const iflistResult = await runVnstatPromise(['--iflist']);

        // 解析接口列表
        const allInterfaces = parseInterfaceList(iflistResult);

        // 验证每个接口是否有效
        const validInterfaces = [];
        for (const interface of allInterfaces) {
            try {
                await new Promise((resolve, reject) => {
                    runVnstat(['-i', interface, '--oneline'], (error, stdout) => {
                        if (!error && stdout.trim()) {
                            validInterfaces.push(interface);
                        }
                        resolve();
                    });
                });
            } catch (error) {
                console.error(`检查接口 ${interface} 时出错:`, error);
            }
        }

        // 如果没有找到有效接口，默认返回 eth0
        if (validInterfaces.length === 0) {
            validInterfaces.push('eth0');
        }

        const result = { interfaces: validInterfaces };
        
        // 缓存结果（5分钟）
        cacheManager.set(cacheKey, result, 5 * 60 * 1000);
        
        res.json(result);
    } catch (error) {
        console.error('获取网络接口列表失败:', error.message);
        res.status(503).json({ error: '无法读取 vnstat 网络接口，请检查服务状态' });
    }
});

// 获取统计数据
app.get('/api/stats/:interface/:period', (req, res) => {
    const { interface: interfaceName, period } = req.params;
    const validPeriods = ['l', '5', 'h', 'd', 'm', 'y'];
    if (!isValidInterfaceName(interfaceName)) {
        return res.status(400).json({ error: '无效的接口名称' });
    }
    if (!validPeriods.includes(period)) {
        return res.status(400).json({ error: '无效的时间周期' });
    }
    if (period === 'l') {
        // 优先返回主动缓存的实时数据
        const cachedQueue = cacheManager.get(`realtime:${interfaceName}`);
        if (cachedQueue && cachedQueue.length > 0) {
            const latest = cachedQueue[cachedQueue.length - 1];
            return res.json({ data: latest.data, timestamp: latest.timestamp });
        }
        // 否则降级为现查现算
        return getStatsWithoutCache(interfaceName, period, res);
    }
    // 其他周期优先返回主动缓存
    const cachedData = cacheManager.get(`stats:${interfaceName}:${period}`);
    if (cachedData) {
        return res.json(cachedData);
    }
    // 否则降级为现查现算
    getStatsWithoutCache(interfaceName, period, res, (result) => {
        // 缓存结果
        cacheManager.set(`stats:${interfaceName}:${period}`, result, getCacheTimeForPeriod(period));
    });
});

// 获取缓存时间
function getCacheTimeForPeriod(period) {
    const cacheTimes = {
        '5': 30 * 1000,    // 30秒
        'h': 60 * 1000,    // 1分钟
        'd': 2 * 60 * 1000, // 2分钟
        'm': 5 * 60 * 1000, // 5分钟
        'y': 10 * 60 * 1000 // 10分钟
    };
    return cacheTimes[period] || 60 * 1000;
}

// 获取统计数据（无缓存）
function getStatsWithoutCache(interface, period, res, callback) {
    let args;
    switch(period) {
        case 'l':
            args = ['-tr', '5', '-i', interface];
            break;
        case '5':
            args = ['-5', '-i', interface];
            break;
        default:
            args = [`-${period}`, '-i', interface];
    }
    
    runVnstat(args, (error, stdout) => {
        if (error) {
            console.error(`读取接口 ${interface}/${period} 失败:`, error.message);
            return res.status(503).json({ error: '暂时无法读取流量统计' });
        }
        const result = { data: formatStatsOutput(stdout, period) };
        
        // 如果有回调函数，执行回调
        if (callback) {
            callback(result);
        }
        
        res.json(result);
    });
}

// 添加日期范围查询API
app.get('/api/stats/:interface/range/:startDate/:endDate', (req, res) => {
    const { interface, startDate, endDate } = req.params;
    
    if (!isValidInterfaceName(interface)) {
        return res.status(400).json({ error: '无效的接口名称' });
    }

    const parsedStartDate = parseIsoDate(startDate);
    const parsedEndDate = parseIsoDate(endDate);
    if (!parsedStartDate || !parsedEndDate) {
        return res.status(400).json({ error: '无效的日期格式' });
    }
    if (parsedStartDate > parsedEndDate) {
        return res.status(400).json({ error: '开始日期不能晚于结束日期' });
    }
    const rangeDays = Math.floor((parsedEndDate - parsedStartDate) / 86400000) + 1;
    if (rangeDays > maxRangeDays) {
        return res.status(400).json({ error: `日期范围不能超过 ${maxRangeDays} 天` });
    }

    // 检查缓存
    const cacheKey = cacheManager.generateKey('range', interface, startDate, endDate);
    const cachedData = cacheManager.get(cacheKey);
    
    if (cachedData) {
        return res.json(cachedData);
    }

    runVnstat(['-i', interface, '--begin', startDate, '--end', endDate, '-d'], (error, stdout) => {
        if (error) {
            console.error(`读取接口 ${interface} 日期范围失败:`, error.message);
            return res.status(503).json({ error: '暂时无法读取日期范围统计' });
        }
        const result = {
            data: normalizeStatsLines(translateOutput(stdout).split('\n'), 'range', 'GiB')
        };
        
        // 缓存结果（10分钟）
        cacheManager.set(cacheKey, result, 10 * 60 * 1000);
        
        res.json(result);
    });
});

// 添加获取版本号的路由
app.get('/api/version', (req, res) => {
    res.json({ version: packageJson.version });
});

// 添加缓存统计API
app.get('/api/cache/stats', (req, res) => {
    res.json(cacheManager.getStats());
});

// 添加缓存清理API
app.post('/api/cache/clear', requireAdminIfConfigured, (req, res) => {
    cacheManager.clear();
    res.json({ message: '缓存已清空' });
});

// 添加内存使用监控API
app.get('/api/system/memory', (req, res) => {
    const memUsage = process.memoryUsage();
    res.json({
        rss: `${(memUsage.rss / 1024 / 1024).toFixed(2)}MB`,
        heapTotal: `${(memUsage.heapTotal / 1024 / 1024).toFixed(2)}MB`,
        heapUsed: `${(memUsage.heapUsed / 1024 / 1024).toFixed(2)}MB`,
        external: `${(memUsage.external / 1024 / 1024).toFixed(2)}MB`,
        cacheMemory: cacheManager.getStats().memoryUsage
    });
});

// 添加服务器状态检查API
app.get('/api/system/status', async (req, res) => {
    try {
        const status = {
            server: {
                uptime: process.uptime(),
                memory: process.memoryUsage(),
                version: process.version,
                platform: process.platform,
                arch: process.arch
            },
            vnstat: {
                available: false,
                version: null,
                error: null
            },
            cache: cacheManager.getStats(),
            timestamp: new Date().toISOString()
        };

        // 检查vnstat命令是否可用
        try {
            const vnstatResult = await runVnstatPromise(['--version'], { timeout: 5000 });
            status.vnstat.available = true;
            status.vnstat.version = vnstatResult.trim();
        } catch (error) {
            status.vnstat.error = 'vnstat 命令不可用';
        }

        res.json(status);
    } catch (error) {
        console.error('服务器状态检查失败:', error.message);
        res.status(500).json({ 
            error: '服务器状态检查失败'
        });
    }
});

// 添加vnstat命令测试API
app.get('/api/test/vnstat', requireAdminIfConfigured, async (req, res) => {
    try {
        const testCommands = [
            { name: 'version', args: ['--version'] },
            { name: 'iflist', args: ['--iflist'] },
            { name: 'help', args: ['--help'] }
        ];

        const results = {};
        
        for (const test of testCommands) {
            try {
                const result = await runVnstatPromise(test.args, { timeout: 10000 });
                results[test.name] = {
                    success: true,
                    output: result.trim()
                };
            } catch (error) {
                results[test.name] = {
                    success: false,
                    error: '命令执行失败'
                };
            }
        }

        res.json({
            timestamp: new Date().toISOString(),
            results
        });
    } catch (error) {
        console.error('vnstat 测试失败:', error.message);
        res.status(500).json({ 
            error: 'vnstat测试失败'
        });
    }
});

// 错误处理中间件
app.use((err, req, res, next) => {
    console.error('服务器错误:', err.stack);
    
    // 记录详细的错误信息
    const errorInfo = {
        timestamp: new Date().toISOString(),
        url: req.url,
        method: req.method,
        userAgent: req.get('User-Agent'),
        ip: req.ip,
        error: {
            message: err.message,
            stack: err.stack,
            name: err.name
        }
    };
    
    // 如果是缓存相关错误，记录详细信息
    if (err.message && err.message.includes('cache')) {
        console.error('缓存错误详情:', {
            ...errorInfo,
            cacheStats: cacheManager.getStats()
        });
    }
    
    // 如果是vnstat相关错误，记录详细信息
    if (err.message && (err.message.includes('vnstat') || err.message.includes('command'))) {
        console.error('vnstat命令错误详情:', errorInfo);
    }
    
    // 根据错误类型返回不同的响应
    let statusCode = 500;
    let errorMessage = '服务器内部错误';
    
    if (err.code === 'ENOENT') {
        statusCode = 503;
        errorMessage = '服务暂时不可用，请检查vnstat命令是否正确安装';
    } else if (err.code === 'ETIMEDOUT') {
        statusCode = 504;
        errorMessage = '请求超时，请稍后重试';
    } else if (err.message && err.message.includes('vnstat')) {
        statusCode = 503;
        errorMessage = 'vnstat命令执行失败，请检查系统配置';
    }
    
    res.status(statusCode).json({ 
        error: errorMessage,
        timestamp: errorInfo.timestamp,
        requestId: Math.random().toString(36).substr(2, 9)
    });
});

let server = null;
let memoryMonitorTimer = null;

function startServer() {
    if (server) return server;
    startAllScheduledCollections();
    server = app.listen(port, host, () => {
        console.log(`服务器运行在 http://${host}:${port}`);
        console.log(`缓存配置: 最大条目=${cacheConfig.maxSize}, 最大内存=${cacheConfig.maxMemoryMB}MB`);

        runVnstat(['--version'], (error, stdout) => {
            if (error) {
                console.error('⚠️  vnstat命令不可用:', error.message);
                console.error('请确保已安装并启动 vnstat');
            } else {
                console.log('✅ vnstat命令可用:', stdout.trim());
            }
        });

        memoryMonitorTimer = setInterval(() => {
            const memUsage = process.memoryUsage();
            const cacheStats = cacheManager.getStats();
            console.log(`内存使用: RSS=${(memUsage.rss / 1024 / 1024).toFixed(2)}MB, 缓存=${cacheStats.memoryUsage}, 命中率=${cacheStats.hitRate}`);
        }, cacheConfig.memoryMonitorInterval);
        memoryMonitorTimer.unref?.();
    });

    server.on('error', err => {
        if (err.code === 'EADDRINUSE') {
            console.error(`端口 ${port} 已被占用，请设置 PORT 使用其他端口`);
        } else {
            console.error('启动服务器时发生错误:', err);
        }
    });
    return server;
}

function stopServer() {
    stopAllScheduledCollections();
    clearInterval(memoryMonitorTimer);
    memoryMonitorTimer = null;
    if (!server) return Promise.resolve();
    return new Promise(resolve => {
        server.close(() => {
            server = null;
            resolve();
        });
    });
}

if (require.main === module) {
    startServer();
    const shutdown = signal => {
        console.log(`收到 ${signal} 信号，正在关闭服务器...`);
        stopServer().then(() => process.exit(0));
    };
    process.on('SIGTERM', () => shutdown('SIGTERM'));
    process.on('SIGINT', () => shutdown('SIGINT'));
}

module.exports = {
    app,
    CacheManager,
    cacheManager,
    filterStatsByTime,
    formatStatsOutput,
    isValidInterfaceName,
    normalizeStatsLines,
    normalizeValue,
    parseInterfaceList,
    parseIsoDate,
    startServer,
    stopServer,
    translateOutput
};
