const express = require('express');
require('dotenv').config({ quiet: true });
const { execFile } = require('child_process');
const cors = require('cors');
const crypto = require('crypto');
const path = require('path');
const app = express();
const packageJson = require('./package.json');

function parseIntegerInRange(value, fallback, minimum, maximum) {
    if (value === undefined || value === null || value === '') return fallback;
    const normalized = String(value).trim();
    if (!/^\d+$/.test(normalized)) return fallback;
    const parsed = Number(normalized);
    return Number.isSafeInteger(parsed) && parsed >= minimum && parsed <= maximum
        ? parsed
        : fallback;
}

function parseBoolean(value, fallback) {
    if (value === undefined || value === null || value === '') return fallback;
    if (String(value).trim().toLowerCase() === 'true') return true;
    if (String(value).trim().toLowerCase() === 'false') return false;
    return fallback;
}

// 运行配置优先由环境变量或 .env 提供；生产环境由 systemd 托管进程。
const port = parseIntegerInRange(process.env.PORT, 10089, 1, 65535);
const host = process.env.HOST || '0.0.0.0';
const commandTimeout = parseIntegerInRange(process.env.VNSTAT_COMMAND_TIMEOUT_MS, 15000, 1000, 120000);
const maxRangeDays = parseIntegerInRange(process.env.MAX_RANGE_DAYS, 3660, 1, 36525);
const vnstatMaxConcurrency = parseIntegerInRange(process.env.VNSTAT_MAX_CONCURRENCY, 4, 1, 32);
const vnstatMaxQueue = parseIntegerInRange(process.env.VNSTAT_MAX_QUEUE, 256, 1, 10000);
const realtimeInterval = parseIntegerInRange(process.env.REALTIME_INTERVAL_MS, 5000, 1000, 60000);
const realtimeIdleTimeout = parseIntegerInRange(process.env.REALTIME_IDLE_TIMEOUT_MS, 30000, 10000, 3600000);
const realtimeMaxStale = parseIntegerInRange(process.env.REALTIME_MAX_STALE_MS, 15000, 5000, 600000);
const realtimeMaxActive = parseIntegerInRange(process.env.REALTIME_MAX_ACTIVE, 2, 1, 16);
const realtimeMaxBackoff = Math.max(
    realtimeInterval,
    parseIntegerInRange(process.env.REALTIME_MAX_BACKOFF_MS, 60000, 5000, 3600000)
);

// 缓存配置
const cacheConfig = {
    maxSize: parseIntegerInRange(process.env.CACHE_MAX_SIZE, 100, 1, 10000),
    maxMemoryMB: parseIntegerInRange(process.env.CACHE_MAX_MEMORY_MB, 50, 1, 4096),
    cleanupInterval: parseIntegerInRange(process.env.CACHE_CLEANUP_INTERVAL, 60000, 1000, 3600000),
    memoryMonitorInterval: parseIntegerInRange(
        process.env.MEMORY_MONITOR_INTERVAL,
        300000,
        10000,
        86400000
    )
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
            deletes: 0,
            rejected: 0
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

        if (item.size > this.maxMemoryBytes) {
            this.stats.rejected++;
            return false;
        }

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
        return true;
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
        let oldestTime = Number.POSITIVE_INFINITY;

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
    'date': '日期',
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
    'bit/s': 'b/秒',
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
const ansiEscapeRegex = /\u001B(?:\[[0-?]*[ -/]*[@-~]|[@-_])/g;

function stripTerminalControlSequences(value) {
    return String(value || '').replace(ansiEscapeRegex, '').replace(/\r/g, '');
}

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
    const lines = stripTerminalControlSequences(text).split('\n');
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
    const match = value.match(/([\d.]+)\s*(B|KiB|MiB|GiB|TiB|PiB)?/i);
    if (!match) return value;

    let valueInMiB = Number.parseFloat(match[1]);
    const sourceUnit = (match[2] || 'MiB').toUpperCase();
    const sourceFactors = {
        B: 1 / (1024 * 1024),
        KIB: 1 / 1024,
        MIB: 1,
        GIB: 1024,
        TIB: 1024 * 1024,
        PIB: 1024 * 1024 * 1024
    };
    valueInMiB *= sourceFactors[sourceUnit] || 1;

    const formatAmount = amount => {
        if (amount === 0 || Math.abs(amount) >= 0.01) return amount.toFixed(2);
        // 小流量换算到大单位时保留约三位有效数字，避免非零值显示成 0.00。
        const decimals = Math.min(8, Math.max(3, Math.ceil(-Math.log10(Math.abs(amount))) + 2));
        return amount.toFixed(decimals);
    };
    if (targetUnit === 'GiB') return `${formatAmount(valueInMiB / 1024)} GiB`;
    if (targetUnit === 'TiB') return `${formatAmount(valueInMiB / (1024 * 1024))} TiB`;
    return `${formatAmount(valueInMiB)} MiB`;
}

function parseTrafficValueMiB(value) {
    const match = String(value || '').match(/([\d.]+)\s*(B|KiB|MiB|GiB|TiB|PiB)\b/i);
    if (!match) return null;
    const amount = Number.parseFloat(match[1]);
    if (!Number.isFinite(amount)) return null;
    const factors = {
        B: 1 / (1024 * 1024),
        KIB: 1 / 1024,
        MIB: 1,
        GIB: 1024,
        TIB: 1024 * 1024,
        PIB: 1024 * 1024 * 1024
    };
    return amount * factors[match[2].toUpperCase()];
}

// 旧 data 保持原有文本结构；新增结构化 MiB 数值供客户端稳定绘图并避免字符串解析损失。
function parseTrafficSeries(stdout, period) {
    const points = [];
    const labelPattern = /^(?:\d{2}(?::\d{2})?|\d{2}\/\d{2}\/\d{2}|\d{4}(?:-\d{2}(?:-\d{2})?)?)$/;
    let lines = stripTerminalControlSequences(stdout).split('\n');
    if (period === '5') lines = filterStatsByTime(lines, 'minutes');
    if (period === 'h') lines = filterStatsByTime(lines, 'hours');
    if (period === 'd') lines = filterStatsByTime(lines, 'days');
    for (const rawLine of lines) {
        const parts = rawLine.split('|');
        if (parts.length < 3) continue;

        const receiveMatch = parts[0].match(/([\d.]+\s*(?:B|KiB|MiB|GiB|TiB|PiB))\s*$/i);
        if (!receiveMatch) continue;
        const label = parts[0].slice(0, receiveMatch.index).trim();
        if (!labelPattern.test(label)) continue;

        const rx = parseTrafficValueMiB(receiveMatch[1]);
        const tx = parseTrafficValueMiB(parts[1]);
        const total = parseTrafficValueMiB(parts[2]);
        if (rx === null || tx === null || total === null) continue;
        points.push({ label, rx, tx, total });
    }
    return { unit: 'MiB', points };
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
        line = line.replace(/^(\s*\d{2}\/\d{2}\/\d{2})(\s+)/, '$1 |$2');
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

function buildStatsResult(stdout, period, targetUnit) {
    const translatedLines = translateOutput(stdout).split('\n');
    const data = targetUnit
        ? normalizeStatsLines(translatedLines, period, targetUnit)
        : formatStatsOutput(stdout, period);
    return {
        data,
        series: parseTrafficSeries(stdout, period)
    };
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

function parseDatabaseInterfaceList(output) {
    return [...new Set(
        String(output || '')
            .split(/\r?\n/)
            .map(value => value.trim())
            .filter(isValidInterfaceName)
    )];
}

const singleFlightRequests = new Map();
function singleFlight(key, task) {
    const existing = singleFlightRequests.get(key);
    if (existing) return existing;
    const promise = Promise.resolve().then(task);
    singleFlightRequests.set(key, promise);
    const clear = () => {
        if (singleFlightRequests.get(key) === promise) singleFlightRequests.delete(key);
    };
    promise.then(clear, clear);
    return promise;
}

async function mapWithConcurrency(values, concurrency, mapper) {
    const results = new Array(values.length);
    let nextIndex = 0;
    const workers = Array.from(
        { length: Math.min(concurrency, values.length) },
        async () => {
            while (nextIndex < values.length) {
                const index = nextIndex++;
                results[index] = await mapper(values[index], index);
            }
        }
    );
    await Promise.all(workers);
    return results;
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

class VnstatCommandRunner {
    constructor({ maxConcurrency = 4, maxQueue = 256, execFileImpl = execFile } = {}) {
        this.maxConcurrency = maxConcurrency;
        this.maxQueue = maxQueue;
        this.execFileImpl = execFileImpl;
        this.active = 0;
        this.foregroundQueue = [];
        this.backgroundQueue = [];
    }

    execute(args, options = {}) {
        const queued = this.foregroundQueue.length + this.backgroundQueue.length;
        if (queued >= this.maxQueue) {
            const error = new Error('vnstat 命令队列已满');
            error.code = 'VNSTAT_QUEUE_FULL';
            return Promise.reject(error);
        }

        return new Promise((resolve, reject) => {
            const job = { args, options, resolve, reject };
            if (options.priority === 'background') {
                this.backgroundQueue.push(job);
            } else {
                this.foregroundQueue.push(job);
            }
            this.pump();
        });
    }

    pump() {
        while (this.active < this.maxConcurrency) {
            const job = this.foregroundQueue.shift() || this.backgroundQueue.shift();
            if (!job) return;
            this.startJob(job);
        }
    }

    startJob(job) {
        this.active++;
        const { priority, env, ...overrides } = job.options;
        const execOptions = {
            timeout: commandTimeout,
            maxBuffer: 1024 * 1024,
            windowsHide: true,
            ...overrides,
            env: {
                ...process.env,
                ...(env || {}),
                LC_ALL: 'C',
                LANG: 'C'
            }
        };
        let completed = false;
        const finish = (error, stdout = '', stderr = '') => {
            if (completed) return;
            completed = true;
            this.active--;
            if (error) {
                error.stderr = stderr;
                job.reject(error);
            } else {
                job.resolve(stdout);
            }
            this.pump();
        };

        try {
            this.execFileImpl('vnstat', job.args, execOptions, finish);
        } catch (error) {
            finish(error);
        }
    }

    getStats() {
        return {
            active: this.active,
            queued: this.foregroundQueue.length + this.backgroundQueue.length,
            maxConcurrency: this.maxConcurrency,
            maxQueue: this.maxQueue
        };
    }
}

const vnstatRunner = new VnstatCommandRunner({
    maxConcurrency: vnstatMaxConcurrency,
    maxQueue: vnstatMaxQueue
});

function runVnstatPromise(args, options = {}) {
    return vnstatRunner.execute(args, options);
}

function runVnstat(args, options, callback) {
    const normalizedOptions = typeof options === 'function' ? {} : options;
    const normalizedCallback = typeof options === 'function' ? options : callback;
    runVnstatPromise(args, normalizedOptions).then(
        stdout => normalizedCallback(null, stdout, ''),
        error => normalizedCallback(error, '', error.stderr || '')
    );
}

class RealtimeCollectorManager {
    constructor({
        cache,
        runCommand,
        intervalMs = 5000,
        idleTimeoutMs = 30000,
        maxStaleMs = 15000,
        maxActive = 2,
        maxBackoffMs = 60000,
        cacheSize = 20,
        now = () => Date.now(),
        setTimer = setTimeout,
        clearTimer = clearTimeout,
        logger = console
    }) {
        this.cache = cache;
        this.runCommand = runCommand;
        this.intervalMs = intervalMs;
        this.idleTimeoutMs = idleTimeoutMs;
        this.maxStaleMs = maxStaleMs;
        this.maxActive = maxActive;
        this.maxBackoffMs = Math.max(intervalMs, maxBackoffMs);
        this.cacheSize = cacheSize;
        this.cacheTtlMs = Math.max(cacheSize * intervalMs * 2, idleTimeoutMs + maxStaleMs);
        this.now = now;
        this.setTimer = setTimer;
        this.clearTimer = clearTimer;
        this.logger = logger;
        this.states = new Map();
        this.enabled = false;
    }

    start() {
        this.enabled = true;
    }

    stop() {
        this.enabled = false;
        for (const state of this.states.values()) this.disposeState(state);
        this.states.clear();
    }

    disposeState(state) {
        state.disposed = true;
        if (state.timer) this.clearTimer(state.timer);
        state.timer = null;
    }

    removeState(state) {
        if (this.states.get(state.interfaceName) !== state) return;
        this.disposeState(state);
        this.states.delete(state.interfaceName);
    }

    touch(interfaceName) {
        let state = this.states.get(interfaceName);
        if (state) {
            state.lastAccessed = this.now();
            return state;
        }

        while (this.states.size >= this.maxActive) {
            let oldest = null;
            for (const candidate of this.states.values()) {
                // 正在执行的采样不能被驱逐；否则同一接口可被重新创建并绕过活跃上限。
                if (candidate.inFlight) continue;
                if (!oldest || candidate.lastAccessed < oldest.lastAccessed) oldest = candidate;
            }
            if (!oldest) {
                const error = new Error('实时采集器当前已满');
                error.code = 'REALTIME_CAPACITY_FULL';
                throw error;
            }
            this.removeState(oldest);
        }

        state = {
            interfaceName,
            lastAccessed: this.now(),
            timer: null,
            inFlight: null,
            failures: 0,
            nextAttemptAt: 0,
            lastError: null,
            disposed: false
        };
        this.states.set(interfaceName, state);
        return state;
    }

    latest(interfaceName, countStats = true) {
        const queue = countStats
            ? this.cache.get(`realtime:${interfaceName}`)
            : this.cache.peek(`realtime:${interfaceName}`);
        return queue && queue.length > 0 ? queue[queue.length - 1] : null;
    }

    responseFor(entry, stale) {
        return {
            data: entry.data,
            timestamp: entry.timestamp,
            stale,
            ageMs: Math.max(0, this.now() - entry.timestamp)
        };
    }

    schedule(state, delay) {
        if (!this.enabled || state.disposed || this.states.get(state.interfaceName) !== state) return;
        if (state.timer) this.clearTimer(state.timer);
        const idleRemaining = this.idleTimeoutMs - (this.now() - state.lastAccessed);
        if (idleRemaining <= 0) {
            this.removeState(state);
            return;
        }
        const boundedDelay = Math.max(0, Math.min(delay, idleRemaining));
        state.timer = this.setTimer(async () => {
            state.timer = null;
            await this.onTimer(state);
        }, boundedDelay);
        state.timer?.unref?.();
    }

    ensureScheduled(state) {
        if (!this.enabled || state.timer || state.inFlight || state.disposed) return;
        const now = this.now();
        const latest = this.latest(state.interfaceName, false);
        const delay = state.nextAttemptAt > now
            ? state.nextAttemptAt - now
            : latest
                ? Math.max(0, this.intervalMs - (now - latest.timestamp))
                : 0;
        this.schedule(state, delay);
    }

    async onTimer(state) {
        if (state.disposed || this.states.get(state.interfaceName) !== state) return;
        const now = this.now();
        if (now - state.lastAccessed >= this.idleTimeoutMs) {
            this.removeState(state);
            return;
        }
        if (state.nextAttemptAt > now) {
            this.schedule(state, state.nextAttemptAt - now);
            return;
        }
        try {
            await this.collect(state, 'background');
        } catch (_) {
            // collect 已记录简明错误并安排退避重试。
        }
    }

    collect(state, priority = 'foreground') {
        if (state.inFlight) return state.inFlight;
        if (state.timer) this.clearTimer(state.timer);
        state.timer = null;
        const startedAt = this.now();
        const promise = (async () => {
            try {
                const stdout = await this.runCommand(
                    ['-tr', '5', '-i', state.interfaceName],
                    { timeout: commandTimeout, priority }
                );
                if (!stdout) {
                    const error = new Error('vnstat 未返回实时统计');
                    error.code = 'VNSTAT_EMPTY_OUTPUT';
                    throw error;
                }
                const entry = {
                    timestamp: this.now(),
                    data: translateOutput(stdout).split('\n')
                };
                const previous = this.cache.peek(`realtime:${state.interfaceName}`) || [];
                const keepCount = Math.max(0, this.cacheSize - 1);
                const queue = keepCount > 0 ? previous.slice(-keepCount) : [];
                queue.push(entry);
                this.cache.set(`realtime:${state.interfaceName}`, queue, this.cacheTtlMs);
                state.failures = 0;
                state.nextAttemptAt = 0;
                state.lastError = null;
                return entry;
            } catch (error) {
                state.failures++;
                const backoff = Math.min(
                    this.maxBackoffMs,
                    this.intervalMs * (2 ** Math.min(state.failures - 1, 20))
                );
                state.nextAttemptAt = this.now() + backoff;
                state.lastError = error;
                this.logger.error(`实时采集接口 ${state.interfaceName} 失败: ${error.message}`);
                throw error;
            } finally {
                state.inFlight = null;
                if (!state.disposed && this.states.get(state.interfaceName) === state) {
                    const delay = state.nextAttemptAt > this.now()
                        ? state.nextAttemptAt - this.now()
                        : Math.max(0, this.intervalMs - (this.now() - startedAt));
                    this.schedule(state, delay);
                }
            }
        })();
        state.inFlight = promise;
        return promise;
    }

    async getSample(interfaceName) {
        const state = this.touch(interfaceName);
        let latest = this.latest(interfaceName);
        if (latest && this.now() - latest.timestamp <= this.maxStaleMs) {
            this.ensureScheduled(state);
            return this.responseFor(latest, false);
        }

        if (state.nextAttemptAt <= this.now()) {
            try {
                latest = await this.collect(state, 'foreground');
                return this.responseFor(latest, false);
            } catch (error) {
                latest = this.latest(interfaceName, false);
                if (!latest) throw error;
            }
        } else {
            this.ensureScheduled(state);
        }

        if (!latest) {
            throw state.lastError || new Error('暂时无法读取实时流量统计');
        }
        return this.responseFor(latest, true);
    }

    getStateSnapshot() {
        return Array.from(this.states.values(), state => ({
            interfaceName: state.interfaceName,
            lastAccessed: state.lastAccessed,
            failures: state.failures,
            nextAttemptAt: state.nextAttemptAt,
            inFlight: Boolean(state.inFlight)
        }));
    }
}

const effectiveRealtimeMaxActive = Math.min(
    realtimeMaxActive,
    vnstatMaxConcurrency > 1 ? vnstatMaxConcurrency - 1 : 1
);
const realtimeCollectorManager = new RealtimeCollectorManager({
    cache: cacheManager,
    runCommand: (args, options) => runVnstatPromise(args, options),
    intervalMs: realtimeInterval,
    idleTimeoutMs: realtimeIdleTimeout,
    maxStaleMs: realtimeMaxStale,
    maxActive: effectiveRealtimeMaxActive,
    maxBackoffMs: realtimeMaxBackoff
});

// 实时采集由 API 首次访问按需启动，并在客户端停止访问后自动回收。
function startAllScheduledCollections() {
    realtimeCollectorManager.start();
}

function stopAllScheduledCollections() {
    realtimeCollectorManager.stop();
}

if (parseBoolean(process.env.TRUST_PROXY, false)) app.set('trust proxy', 1);

const corsOrigins = (process.env.CORS_ORIGINS || '')
    .split(',')
    .map(value => value.trim())
    .filter(Boolean);

app.use((req, res, next) => {
    res.set({
        'X-Content-Type-Options': 'nosniff',
        'X-Frame-Options': 'DENY',
        'Referrer-Policy': 'no-referrer',
        'Permissions-Policy': 'camera=(), microphone=(), geolocation=()',
        // 当前无构建版 Vue 需要运行时编译模板，因此暂时保留 unsafe-eval；页面已无内联脚本。
        'Content-Security-Policy': "default-src 'self'; script-src 'self' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'none'"
    });
    next();
});

const rateLimitWindowMs = parseIntegerInRange(process.env.RATE_LIMIT_WINDOW_MS, 60000, 1000, 3600000);
const rateLimitMax = parseIntegerInRange(process.env.RATE_LIMIT_MAX, 180, 1, 1000000);
const rateLimitMaxClients = parseIntegerInRange(process.env.RATE_LIMIT_MAX_CLIENTS, 10000, 1, 1000000);
const requestBuckets = new Map();
// 限流必须先于 CORS 和请求体解析，确保预期拒绝与解析错误同样消耗配额。
app.use('/api', (req, res, next) => {
    const now = Date.now();
    const bucket = requestBuckets.get(req.ip);
    if (!bucket || now >= bucket.resetAt) {
        while (requestBuckets.size >= rateLimitMaxClients) {
            const oldestIp = requestBuckets.keys().next().value;
            if (oldestIp === undefined) break;
            requestBuckets.delete(oldestIp);
        }
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

if (corsOrigins.length > 0) {
    app.use(cors({
        origin(origin, callback) {
            if (!origin || corsOrigins.includes(origin)) return callback(null, true);
            const error = new Error('来源不在 CORS 白名单中');
            error.status = 403;
            error.expose = true;
            return callback(error);
        }
    }));
}

app.use(express.json({ limit: '16kb' }));

app.use('/vendor/bootstrap', express.static(path.join(__dirname, 'node_modules/bootstrap/dist')));
app.use('/vendor/chart.js', express.static(path.join(__dirname, 'node_modules/chart.js/dist')));
app.use('/vendor/vue', express.static(path.join(__dirname, 'node_modules/vue/dist')));
app.use('/vendor/axios', express.static(path.join(__dirname, 'node_modules/axios/dist')));
app.use(express.static(path.join(__dirname, 'public')));

function timingSafeStringEqual(expected, provided) {
    const expectedBuffer = Buffer.from(String(expected || ''));
    const providedBuffer = Buffer.from(String(provided || ''));
    return expectedBuffer.length === providedBuffer.length &&
        crypto.timingSafeEqual(expectedBuffer, providedBuffer);
}

const allowAnonymousAdmin = parseBoolean(process.env.ALLOW_ANONYMOUS_ADMIN, false);

function requireAdminIfConfigured(req, res, next) {
    const expected = process.env.ADMIN_TOKEN;
    if (!expected) {
        if (!allowAnonymousAdmin) {
            return res.status(403).json({ error: '匿名管理接口已禁用' });
        }
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
    if (!timingSafeStringEqual(expected, provided)) {
        return res.status(401).json({ error: '需要管理员凭据' });
    }
    next();
}

async function readTrackedInterfaces() {
    try {
        const databaseInterfaces = await runVnstatPromise(['--dbiflist', '1']);
        return parseDatabaseInterfaceList(databaseInterfaces);
    } catch (error) {
        // 兼容不支持 --dbiflist 的旧版 vnstat；fallback 仍受全局并发限制。
        console.warn(`vnstat --dbiflist 不可用，回退到接口逐项检查: ${error.message}`);
        const iflistResult = await runVnstatPromise(['--iflist']);
        const allInterfaces = parseInterfaceList(iflistResult);
        const validation = await mapWithConcurrency(
            allInterfaces,
            vnstatMaxConcurrency,
            async interfaceName => {
                try {
                    const stdout = await runVnstatPromise(['-i', interfaceName, '--oneline']);
                    return stdout.trim() ? interfaceName : null;
                } catch (_) {
                    return null;
                }
            }
        );
        return validation.filter(Boolean);
    }
}

// 获取网络接口列表
app.get('/api/interfaces', async (req, res) => {
    const cacheKey = cacheManager.generateKey('interfaces');
    const cachedData = cacheManager.get(cacheKey);
    if (cachedData) return res.json(cachedData);

    try {
        const result = await singleFlight(cacheKey, async () => {
            const cachedInsideFlight = cacheManager.peek(cacheKey);
            if (cachedInsideFlight) return cachedInsideFlight;
            const interfaces = await readTrackedInterfaces();
            const loaded = { interfaces };
            cacheManager.set(cacheKey, loaded, 5 * 60 * 1000);
            return loaded;
        });
        return res.json(result);
    } catch (error) {
        console.error('获取网络接口列表失败:', error.message);
        return res.status(503).json({ error: '无法读取 vnstat 网络接口，请检查服务状态' });
    }
});

// 获取统计数据
app.get('/api/stats/:interface/:period', async (req, res) => {
    const { interface: interfaceName, period } = req.params;
    const validPeriods = ['l', '5', 'h', 'd', 'm', 'y'];
    if (!isValidInterfaceName(interfaceName)) {
        return res.status(400).json({ error: '无效的接口名称' });
    }
    if (!validPeriods.includes(period)) {
        return res.status(400).json({ error: '无效的时间周期' });
    }
    if (period === 'l') {
        try {
            const sample = await realtimeCollectorManager.getSample(interfaceName);
            return res.json(sample);
        } catch (_) {
            return res.status(503).json({ error: '暂时无法读取实时流量统计' });
        }
    }
    const cacheKey = `stats:${interfaceName}:${period}`;
    const cachedData = cacheManager.get(cacheKey);
    if (cachedData) return res.json(cachedData);

    try {
        const result = await singleFlight(cacheKey, async () => {
            const cachedInsideFlight = cacheManager.peek(cacheKey);
            if (cachedInsideFlight) return cachedInsideFlight;
            const loaded = await getStatsWithoutCache(interfaceName, period);
            cacheManager.set(cacheKey, loaded, getCacheTimeForPeriod(period));
            return loaded;
        });
        return res.json(result);
    } catch (error) {
        console.error(`读取接口 ${interfaceName}/${period} 失败:`, error.message);
        return res.status(503).json({ error: '暂时无法读取流量统计' });
    }
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
async function getStatsWithoutCache(interfaceName, period) {
    let args;
    switch(period) {
        case '5':
            args = ['-5', '-i', interfaceName];
            break;
        default:
            args = [`-${period}`, '-i', interfaceName];
    }
    const stdout = await runVnstatPromise(args);
    return buildStatsResult(stdout, period);
}

// 添加日期范围查询API
app.get('/api/stats/:interface/range/:startDate/:endDate', async (req, res) => {
    const { interface: interfaceName, startDate, endDate } = req.params;
    
    if (!isValidInterfaceName(interfaceName)) {
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
    const cacheKey = cacheManager.generateKey('range', interfaceName, startDate, endDate);
    const cachedData = cacheManager.get(cacheKey);
    if (cachedData) return res.json(cachedData);

    try {
        const result = await singleFlight(cacheKey, async () => {
            const cachedInsideFlight = cacheManager.peek(cacheKey);
            if (cachedInsideFlight) return cachedInsideFlight;
            const stdout = await runVnstatPromise([
                '-i', interfaceName, '--begin', startDate, '--end', endDate, '-d'
            ]);
            const loaded = buildStatsResult(stdout, 'range', 'GiB');
            cacheManager.set(cacheKey, loaded, 10 * 60 * 1000);
            return loaded;
        });
        return res.json(result);
    } catch (error) {
        console.error(`读取接口 ${interfaceName} 日期范围失败:`, error.message);
        return res.status(503).json({ error: '暂时无法读取日期范围统计' });
    }
});

// 添加获取版本号的路由
app.get('/api/version', (req, res) => {
    const result = { version: packageJson.version };
    const expectedInstanceToken = process.env.FLOWMASTER_INSTANCE_TOKEN;
    if (
        expectedInstanceToken &&
        timingSafeStringEqual(expectedInstanceToken, req.get('X-FlowMaster-Instance-Token') || '')
    ) {
        result.instanceTokenMatched = true;
    }
    res.json(result);
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

app.use('/api', (req, res) => {
    res.status(404).json({ error: 'API 路径不存在' });
});

// 错误处理中间件
app.use((err, req, res, next) => {
    void next;
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

    let statusCode = Number.isInteger(err.status) && err.status >= 400 && err.status <= 599 ? err.status : 500;
    let errorMessage = '服务器内部错误';

    if (statusCode === 403) {
        errorMessage = '请求来源不被允许';
    } else if (err.type === 'entity.parse.failed') {
        statusCode = 400;
        errorMessage = '请求体不是有效的 JSON';
    } else if (err.type === 'entity.too.large') {
        statusCode = 413;
        errorMessage = '请求体过大';
    } else if (err.code === 'ENOENT') {
        statusCode = 503;
        errorMessage = '服务暂时不可用，请检查vnstat命令是否正确安装';
    } else if (err.code === 'VNSTAT_QUEUE_FULL') {
        statusCode = 503;
        errorMessage = '服务繁忙，请稍后重试';
    } else if (err.code === 'ETIMEDOUT') {
        statusCode = 504;
        errorMessage = '请求超时，请稍后重试';
    } else if (err.message && err.message.includes('vnstat')) {
        statusCode = 503;
        errorMessage = 'vnstat命令执行失败，请检查系统配置';
    }

    const expectedError = err.expose === true ||
        err.type === 'entity.parse.failed' ||
        err.type === 'entity.too.large';
    if (expectedError) {
        console.warn(`请求被拒绝: ${req.method} ${req.originalUrl} -> ${statusCode}`);
    } else {
        console.error('服务器错误:', err.stack || err.message);
        if (err.message && err.message.includes('cache')) {
            console.error('缓存错误详情:', { ...errorInfo, cacheStats: cacheManager.getStats() });
        }
        if (err.message && (err.message.includes('vnstat') || err.message.includes('command'))) {
            console.error('vnstat命令错误详情:', errorInfo);
        }
    }

    res.status(statusCode).json({ 
        error: errorMessage,
        timestamp: errorInfo.timestamp,
        requestId: crypto.randomUUID()
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

const runtimeConfig = Object.freeze({
    port,
    host,
    commandTimeout,
    maxRangeDays,
    cache: Object.freeze({ ...cacheConfig }),
    rateLimitWindowMs,
    rateLimitMax,
    rateLimitMaxClients,
    vnstatMaxConcurrency,
    vnstatMaxQueue,
    realtimeInterval,
    realtimeIdleTimeout,
    realtimeMaxStale,
    realtimeMaxActive: effectiveRealtimeMaxActive,
    realtimeMaxBackoff,
    allowAnonymousAdmin
});

module.exports = {
    app,
    CacheManager,
    RealtimeCollectorManager,
    VnstatCommandRunner,
    buildStatsResult,
    cacheManager,
    filterStatsByTime,
    formatStatsOutput,
    isValidInterfaceName,
    normalizeStatsLines,
    normalizeValue,
    parseBoolean,
    parseDatabaseInterfaceList,
    parseIntegerInRange,
    parseInterfaceList,
    parseIsoDate,
    parseTrafficSeries,
    realtimeCollectorManager,
    runtimeConfig,
    startServer,
    stopServer,
    stripTerminalControlSequences,
    timingSafeStringEqual,
    translateOutput,
    vnstatRunner
};
