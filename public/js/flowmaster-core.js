'use strict';

(function exposeFlowMasterCore(root, factory) {
    const api = factory();
    if (typeof module === 'object' && module.exports) module.exports = api;
    if (root) root.FlowMasterCore = api;
})(typeof globalThis === 'object' ? globalThis : this, function createFlowMasterCore() {
    function escapeHtml(value) {
        return String(value ?? '').replace(/[&<>'"]/g, character => ({
            '&': '&amp;',
            '<': '&lt;',
            '>': '&gt;',
            "'": '&#39;',
            '"': '&quot;'
        })[character]);
    }

    function splitColumns(line) {
        const text = String(line ?? '');
        if (!text.includes('|')) {
            return text.trim().split(/\s{2,}/).map(value => value.trim()).filter(Boolean);
        }

        const segments = text.split('|');
        const columns = segments[0].trim().split(/\s{2,}/).map(value => value.trim()).filter(Boolean);
        for (let index = 1; index < segments.length; index++) {
            const value = segments[index].trim();
            if (value) columns.push(value);
        }
        return columns;
    }

    function extractPureNumber(value) {
        const match = String(value ?? '').match(/([\d.]+)/);
        return match ? Number.parseFloat(match[1]) : 0;
    }

    function formatValueToUnitNoUnit(value, factor) {
        const match = String(value ?? '').match(/([\d.]+)/);
        if (!match) return String(value ?? '');
        const number = Number.parseFloat(match[1]);
        if (!Number.isFinite(number)) return String(value ?? '');

        const converted = number * factor;
        if (converted === 0 || Math.abs(converted) >= 0.01) return converted.toFixed(2);
        // 与服务端保持一致：极小但非零的流量保留约三位有效数字。
        const decimals = Math.min(8, Math.max(3, Math.ceil(-Math.log10(Math.abs(converted))) + 2));
        return converted.toFixed(decimals);
    }

    function formatTableDataUnified(data, unit, factor = 1) {
        if (!Array.isArray(data)) return [];

        const result = new Array(data.length);
        let started = false;
        let receiveIndex = -1;
        let sendIndex = -1;
        let totalIndex = -1;

        for (let index = 0; index < data.length; index++) {
            const line = String(data[index] ?? '');
            if (!started && line.includes('---')) {
                started = true;
                result[index] = line;
                continue;
            }

            if (!started) {
                const header = line.replace(/\s+/g, ' ').trim().split(' ');
                receiveIndex = header.findIndex(value => value.startsWith('接收') || value.toLowerCase() === 'rx');
                sendIndex = header.findIndex(value => value.startsWith('发送') || value.toLowerCase() === 'tx');
                totalIndex = header.findIndex(value => value.startsWith('总计') || value.toLowerCase() === 'total');
                if (receiveIndex !== -1 && !header[receiveIndex].includes('(')) header[receiveIndex] += `(${unit})`;
                if (sendIndex !== -1 && !header[sendIndex].includes('(')) header[sendIndex] += `(${unit})`;
                if (totalIndex !== -1 && !header[totalIndex].includes('(')) header[totalIndex] += `(${unit})`;
                result[index] = header.join(' ');
                continue;
            }

            const columns = line.replace(/\s+/g, ' ').trim().split(' ');
            if (columns.length < Math.max(receiveIndex, sendIndex, totalIndex) + 1 ||
                /总计|平均|预计|total|avg|est|sum/i.test(columns[0])) {
                result[index] = line;
                continue;
            }

            if (receiveIndex !== -1) columns[receiveIndex] = formatValueToUnitNoUnit(columns[receiveIndex], factor);
            if (sendIndex !== -1) columns[sendIndex] = formatValueToUnitNoUnit(columns[sendIndex], factor);
            if (totalIndex !== -1) columns[totalIndex] = formatValueToUnitNoUnit(columns[totalIndex], factor);
            result[index] = columns.join(' ');
        }

        return result;
    }

    function parseStatData(data) {
        const labels = [];
        const receive = [];
        const send = [];
        let receiveIndex = -1;
        let sendIndex = -1;
        let labelIndex = 0;
        let started = false;

        if (!Array.isArray(data)) return { labels, rx: receive, tx: send };

        for (const rawLine of data) {
            const line = String(rawLine ?? '').trim();
            if (!line) continue;
            if (line.includes('---')) {
                started = true;
                continue;
            }

            if (!started) {
                const header = line.replace(/\s+/g, ' ').trim().split(' ');
                receiveIndex = header.findIndex(value => value.startsWith('接收'));
                sendIndex = header.findIndex(value => value.startsWith('发送'));
                labelIndex = 0;
                continue;
            }

            const columns = line.replace(/\s+/g, ' ').trim().split(' ');
            if (receiveIndex < 0 || sendIndex < 0 || columns.length < Math.max(receiveIndex, sendIndex) + 1) continue;
            if (/总计|平均|预计|total|avg|est|sum/i.test(columns[labelIndex])) continue;
            labels.push(columns[labelIndex]);
            receive.push(extractPureNumber(columns[receiveIndex]));
            send.push(extractPureNumber(columns[sendIndex]));
        }

        return { labels, rx: receive, tx: send };
    }

    function convertSpeedToMbps(speed, fromUnit) {
        const number = Number(speed);
        if (!Number.isFinite(number)) return Number.NaN;
        const unit = String(fromUnit ?? '').trim();
        // 目标统一为十进制 Mb/s；大小写用于区分 bit 与 Byte，不能先统一转小写。
        const multipliers = {
            'b/秒': 1 / 1000000,
            'kb/秒': 1 / 1000,
            'Kb/秒': 1 / 1000,
            'Mb/秒': 1,
            'mb/秒': 1,
            'Gb/秒': 1000,
            'gb/秒': 1000,
            'Tb/秒': 1000000,
            'tb/秒': 1000000,
            'B/秒': 8 / 1000000,
            'KB/秒': (8 * 1024) / 1000000,
            'MB/秒': (8 * 1024 * 1024) / 1000000,
            'GB/秒': (8 * 1024 * 1024 * 1024) / 1000000,
            'TB/秒': (8 * 1024 * 1024 * 1024 * 1024) / 1000000,
            'bit/s': 1 / 1000000,
            'bits/s': 1 / 1000000,
            'kbit/s': 1 / 1000,
            'Mbit/s': 1,
            'Gbit/s': 1000,
            'Tbit/s': 1000000,
            'Kibit/s': 1024 / 1000000,
            'Mibit/s': (1024 * 1024) / 1000000,
            'Gibit/s': (1024 * 1024 * 1024) / 1000000,
            'Tibit/s': (1024 * 1024 * 1024 * 1024) / 1000000,
            'B/s': 8 / 1000000,
            'KiB/s': (8 * 1024) / 1000000,
            'MiB/s': (8 * 1024 * 1024) / 1000000,
            'GiB/s': (8 * 1024 * 1024 * 1024) / 1000000,
            'TiB/s': (8 * 1024 * 1024 * 1024 * 1024) / 1000000
        };
        return Object.prototype.hasOwnProperty.call(multipliers, unit)
            ? number * multipliers[unit]
            : Number.NaN;
    }

    function parseRealtimeData(rawData, timestamp = Date.now()) {
        if (!Array.isArray(rawData)) return null;
        const receiveLine = rawData.find(line => /^\s*(?:接收(?:\s|$)|rx(?:\s|$))/i.test(String(line)));
        const sendLine = rawData.find(line => /^\s*(?:发送(?:\s|$)|tx(?:\s|$))/i.test(String(line)));
        if (!receiveLine || !sendLine) return null;

        const speedPattern = /(\d+(?:\.\d+)?)\s*([A-Za-z]+\/(?:s|秒)).*?(\d+(?:\.\d+)?)\s*(?:数据包|packets?|包|p)\/s/i;
        const receiveMatch = String(receiveLine).match(speedPattern);
        const sendMatch = String(sendLine).match(speedPattern);
        if (!receiveMatch || !sendMatch) return null;

        const receiveSpeed = convertSpeedToMbps(Number.parseFloat(receiveMatch[1]), receiveMatch[2]);
        const sendSpeed = convertSpeedToMbps(Number.parseFloat(sendMatch[1]), sendMatch[2]);
        const receivePackets = Number.parseFloat(receiveMatch[3]);
        const sendPackets = Number.parseFloat(sendMatch[3]);
        if (![receiveSpeed, sendSpeed, receivePackets, sendPackets].every(Number.isFinite)) return null;

        const numericTimestamp = Number(timestamp);
        const safeTimestamp = Number.isFinite(numericTimestamp) ? numericTimestamp : Date.now();
        return {
            time: new Date(safeTimestamp).toLocaleTimeString(),
            timestamp: safeTimestamp,
            receiveSpeed,
            receiveSpeedUnit: 'Mb/秒',
            receivePackets,
            sendSpeed,
            sendSpeedUnit: 'Mb/秒',
            sendPackets
        };
    }

    function metricClass(index, columnIndexes) {
        if (index === columnIndexes.receive) return 'metric-receive';
        if (index === columnIndexes.send) return 'metric-send';
        if (index === columnIndexes.total) return 'metric-total';
        if (index === columnIndexes.average) return 'metric-average';
        return '';
    }

    function renderTableHtml(data, tableLabel = '流量统计') {
        if (!Array.isArray(data) || data.length === 0) {
            return '<p class="data-empty mb-0">暂无数据</p>';
        }

        if (data.length < 2) {
            return `<p class="data-message mb-0">${escapeHtml(data[0])}</p>`;
        }

        const title = String(data[0] ?? tableLabel);
        const header = splitColumns(data[1]);
        if (header.length === 0) {
            return `<p class="data-message mb-0">${escapeHtml(title)}</p>`;
        }

        const columnIndexes = {
            receive: header.findIndex(value => value.includes('接收')),
            send: header.findIndex(value => value.includes('发送')),
            total: header.findIndex(value => value.includes('总计')),
            average: header.findIndex(value => value.includes('平均速率'))
        };

        const parts = [
            `<div class="data-table-title">${escapeHtml(title)}</div>`,
            '<table class="table table-sm table-bordered data-table mb-0">',
            `<caption class="visually-hidden">${escapeHtml(tableLabel)}</caption>`,
            '<thead><tr>',
            ...header.map(value => `<th scope="col">${escapeHtml(value)}</th>`),
            '</tr></thead><tbody>'
        ];

        let rowIndex = 0;
        for (let index = 2; index < data.length; index++) {
            const line = String(data[index] ?? '');
            if (!line.trim() || line.includes('---')) continue;
            const columns = splitColumns(line);
            if (columns.length === 0) continue;
            parts.push(`<tr class="${rowIndex % 2 === 0 ? 'data-row-even' : 'data-row-odd'}">`);
            for (let columnIndex = 0; columnIndex < columns.length; columnIndex++) {
                const className = metricClass(columnIndex, columnIndexes);
                parts.push(`<td${className ? ` class="${className}"` : ''}>${escapeHtml(columns[columnIndex])}</td>`);
            }
            parts.push('</tr>');
            rowIndex++;
        }

        parts.push('</tbody></table>');
        return parts.join('');
    }

    function formatFiniteNumber(value, fractionDigits = 2) {
        const number = Number(value);
        return Number.isFinite(number) ? number.toFixed(fractionDigits) : '0.00';
    }

    function renderRealtimeTableHtml(realtimeData, rawData) {
        const rows = Array.isArray(realtimeData) ? realtimeData.slice(-8) : [];
        if (rows.length === 0) {
            const rawLines = Array.isArray(rawData) ? rawData.filter(line => String(line).trim()) : [];
            if (rawLines.length > 0) {
                return '<p class="data-message">暂无可解析的实时数据，显示原始数据：</p>' +
                    `<pre class="raw-data mb-0">${escapeHtml(rawLines.join('\n'))}</pre>`;
            }
            return '<p class="data-empty mb-0">等待首个实时样本…</p>';
        }

        const parts = [
            '<table class="table table-sm table-bordered data-table mb-0">',
            '<caption class="visually-hidden">最近八次实时流量样本</caption>',
            '<thead><tr>',
            '<th scope="col">时间</th>',
            '<th scope="col">接收速度(Mb/秒)</th>',
            '<th scope="col">接收数据包</th>',
            '<th scope="col">发送速度(Mb/秒)</th>',
            '<th scope="col">发送数据包</th>',
            '</tr></thead><tbody>'
        ];

        rows.forEach((item, index) => {
            const latestClass = index === rows.length - 1 ? ' data-row-latest' : '';
            const stripeClass = index % 2 === 0 ? 'data-row-even' : 'data-row-odd';
            parts.push(`<tr class="${stripeClass}${latestClass}">`);
            parts.push(`<td>${escapeHtml(item.time)}</td>`);
            parts.push(`<td class="metric-receive">${formatFiniteNumber(item.receiveSpeed)} Mb/秒</td>`);
            parts.push(`<td class="metric-receive">${escapeHtml(item.receivePackets)} 包/s</td>`);
            parts.push(`<td class="metric-send">${formatFiniteNumber(item.sendSpeed)} Mb/秒</td>`);
            parts.push(`<td class="metric-send">${escapeHtml(item.sendPackets)} 包/s</td>`);
            parts.push('</tr>');
        });

        parts.push('</tbody></table>');
        return parts.join('');
    }

    function sameRequestContext(expected, current) {
        if (!expected || !current) return false;
        const keys = Object.keys(expected);
        return keys.length === Object.keys(current).length && keys.every(key => expected[key] === current[key]);
    }

    function isSampleStale(lastReceivedAt, now = Date.now(), thresholdMs = 15000) {
        const receivedAt = Number(lastReceivedAt);
        return !Number.isFinite(receivedAt) || receivedAt <= 0 || Number(now) - receivedAt > thresholdMs;
    }

    class RequestCoordinator {
        constructor(AbortControllerClass = typeof AbortController === 'function' ? AbortController : null) {
            this.AbortControllerClass = AbortControllerClass;
            this.generations = new Map();
            this.active = new Map();
        }

        begin(key, options = {}) {
            const replace = options.replace === true;
            const previous = this.active.get(key);
            if (previous && !replace) return null;
            if (previous) previous.controller?.abort();

            const generation = (this.generations.get(key) || 0) + 1;
            this.generations.set(key, generation);
            const controller = this.AbortControllerClass ? new this.AbortControllerClass() : null;
            const ticket = { key, generation, controller, signal: controller?.signal };
            this.active.set(key, ticket);
            return ticket;
        }

        isCurrent(ticket) {
            if (!ticket) return false;
            return this.active.get(ticket.key)?.generation === ticket.generation;
        }

        finish(ticket) {
            if (!this.isCurrent(ticket)) return false;
            this.active.delete(ticket.key);
            return true;
        }

        invalidate(key) {
            const ticket = this.active.get(key);
            if (ticket) ticket.controller?.abort();
            this.generations.set(key, (this.generations.get(key) || 0) + 1);
            this.active.delete(key);
        }

        invalidateMany(keys) {
            for (const key of keys) this.invalidate(key);
        }

        invalidateAll() {
            for (const key of [...this.active.keys()]) this.invalidate(key);
        }

        hasActive(key) {
            return this.active.has(key);
        }
    }

    return {
        RequestCoordinator,
        convertSpeedToMbps,
        escapeHtml,
        formatTableDataUnified,
        isSampleStale,
        parseRealtimeData,
        parseStatData,
        renderRealtimeTableHtml,
        renderTableHtml,
        sameRequestContext,
        splitColumns
    };
});
