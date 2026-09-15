'use strict';

(function startFlowMaster() {
    const core = window.FlowMasterCore;
    if (!core || !window.Vue || !window.Chart || !window.axios) {
        throw new Error('FlowMaster 前端依赖加载失败');
    }
    window.performance?.mark?.('app-start');

    class ChartRenderScheduler {
        constructor() {
            this.tasks = new Map();
            this.retryDelay = 120;
            this.maxRetry = 20;
        }

        requestRender(key, getElement, getData, render) {
            this.cancel(key);
            const task = { getElement, getData, render, retry: 0, timer: null };
            this.tasks.set(key, task);
            this.tryRender(key);
        }

        tryRender(key) {
            const task = this.tasks.get(key);
            if (!task) return;

            let element = task.getElement();
            if (Array.isArray(element)) element = element[0];
            const data = task.getData();
            if (!element?.getContext) {
                if (task.retry >= this.maxRetry) {
                    this.tasks.delete(key);
                    return;
                }
                task.retry++;
                task.timer = window.setTimeout(() => this.tryRender(key), this.retryDelay);
                return;
            }

            if (!Array.isArray(data) || data.length === 0) {
                this.tasks.delete(key);
                return;
            }

            try {
                element._chartInstance?.destroy?.();
                element._chartInstance = task.render(element, data);
            } catch (error) {
                console.error(`图表 ${key} 渲染失败:`, error);
            } finally {
                this.tasks.delete(key);
            }
        }

        cancel(key) {
            const task = this.tasks.get(key);
            if (task?.timer) window.clearTimeout(task.timer);
            this.tasks.delete(key);
        }

        clear() {
            for (const key of [...this.tasks.keys()]) this.cancel(key);
        }
    }

    const requestCoordinator = new core.RequestCoordinator();
    const chartScheduler = new ChartRenderScheduler();
    const pollingRequestKeys = ['realtime', 'minute', 'cache', 'stat-h', 'stat-d', 'stat-m', 'stat-y'];
    const realtimeStaleAfterMs = 15000;

    function normalizeError(error, fallback) {
        return error?.response?.data?.error || error?.message || fallback;
    }

    function isCanceledRequest(error) {
        return error?.code === 'ERR_CANCELED' || error?.name === 'CanceledError' || error?.name === 'AbortError';
    }

    function safeArray(value) {
        return Array.isArray(value) ? value : [];
    }

    const app = Vue.createApp({
        data() {
            return {
                interfaces: [],
                interfacesLoading: true,
                selectedInterface: '',
                activeRealtimeInterface: '',
                error: null,
                realtimeStats: { data: [], loading: false, error: null },
                minuteStats: { data: [], loading: false, error: null, unit: 'MiB', factor: 1 },
                stats: [
                    { period: 'h', title: '小时统计', data: [], loading: false, error: null, unit: 'MiB', factor: 1 },
                    { period: 'd', title: '日统计', data: [], loading: false, error: null, unit: 'GiB', factor: 1 },
                    { period: 'm', title: '月统计', data: [], loading: false, error: null, unit: 'GiB', factor: 1 },
                    { period: 'y', title: '年统计', data: [], loading: false, error: null, unit: 'TiB', factor: 1 }
                ],
                autoRefresh: true,
                lastUpdateTime: '',
                lastSampleReceivedAt: 0,
                lastRealtimeTimestamp: 0,
                lastRealtimeServerStale: false,
                realtimeStale: true,
                realtimeData: [],
                version: '',
                dateRange: { start: '', end: '' },
                dateRangeStats: { data: [], loading: false, error: null, unit: 'GiB', factor: 1 },
                isDarkMode: false,
                cacheStats: {
                    hits: 0,
                    misses: 0,
                    hitRate: '0%',
                    size: 0,
                    maxSize: 100,
                    memoryUsage: '0MB',
                    maxMemory: '50MB'
                },
                cacheStatsLoading: false,
                performance: {
                    lastResponseTime: null,
                    averageResponseTime: 0,
                    requestCount: 0
                },
                initialized: false,
                currentYear: new Date().getFullYear()
            };
        },

        computed: {
            isDateRangeValid() {
                return Boolean(
                    this.selectedInterface &&
                    this.dateRange.start &&
                    this.dateRange.end &&
                    this.dateRange.start <= this.dateRange.end
                );
            },
            cacheHitRateGood() {
                return Number.parseFloat(this.cacheStats.hitRate) >= 50;
            },
            realtimeStatusText() {
                if (!this.lastSampleReceivedAt) return '等待首个实时样本';
                return this.realtimeStale ? '实时数据可能已过期' : '实时数据正常';
            },
            realtimeStatusClass() {
                if (!this.lastSampleReceivedAt || this.realtimeStale) return 'status-warning';
                return 'status-ok';
            },
            realtimeTableHtml() {
                return core.renderRealtimeTableHtml(this.realtimeData, this.realtimeStats.data);
            }
        },

        methods: {
            async measurePerformance(apiCall) {
                const startedAt = performance.now();
                try {
                    const result = await apiCall();
                    const responseTime = performance.now() - startedAt;
                    this.performance.lastResponseTime = Math.round(responseTime);
                    this.performance.requestCount++;
                    this.performance.averageResponseTime =
                        (this.performance.averageResponseTime * (this.performance.requestCount - 1) + responseTime) /
                        this.performance.requestCount;
                    return result;
                } catch (error) {
                    if (!isCanceledRequest(error)) {
                        this.performance.lastResponseTime = Math.round(performance.now() - startedAt);
                    }
                    throw error;
                }
            },

            apiGet(url, ticket) {
                const config = ticket?.signal ? { signal: ticket.signal } : undefined;
                return this.measurePerformance(() => axios.get(url, config));
            },

            currentInterfaceContext() {
                return { interfaceName: this.selectedInterface };
            },

            requestStillApplies(ticket, expectedContext, currentContext = this.currentInterfaceContext()) {
                return requestCoordinator.isCurrent(ticket) && core.sameRequestContext(expectedContext, currentContext);
            },

            async loadInterfaces(options = {}) {
                const ticket = requestCoordinator.begin('interfaces', { replace: options.replace === true });
                if (!ticket) return false;
                this.interfacesLoading = true;

                try {
                    const response = await this.apiGet('/api/interfaces', ticket);
                    if (!requestCoordinator.isCurrent(ticket)) return false;

                    const priority = name => {
                        if (name.startsWith('eth')) return 1;
                        if (name.startsWith('ens')) return 2;
                        if (name.startsWith('enp')) return 3;
                        if (name.startsWith('wlan')) return 10;
                        if (name.startsWith('bond')) return 11;
                        if (name.startsWith('br-')) return 12;
                        if (name.startsWith('docker')) return 100;
                        if (/veth|virbr|tun|tap/.test(name)) return 101;
                        return 50;
                    };

                    this.interfaces = safeArray(response.data.interfaces)
                        .filter(value => typeof value === 'string' && value)
                        .sort((left, right) => priority(left) - priority(right) || left.localeCompare(right));

                    if (this.interfaces.length === 0) {
                        this.selectedInterface = '';
                        this.error = '未找到可用网络接口，请检查 vnstat 是否正确安装和配置。';
                        this.resetInterfaceState();
                        await this.loadCacheStats({ replace: true });
                        return false;
                    }

                    this.error = null;
                    this.selectedInterface = this.interfaces[0];
                    this.resetInterfaceState();
                    await this.loadAllStats({ replace: true });
                    return true;
                } catch (error) {
                    if (isCanceledRequest(error) || !requestCoordinator.isCurrent(ticket)) return false;
                    this.interfaces = [];
                    this.selectedInterface = '';
                    this.error = `无法获取网络接口列表：${normalizeError(error, '未知错误')}`;
                    this.resetInterfaceState();
                    return false;
                } finally {
                    if (requestCoordinator.finish(ticket)) this.interfacesLoading = false;
                }
            },

            async handleInterfaceChange() {
                this.error = null;
                this.cancelInterfaceRequests();
                this.resetInterfaceState();
                if (this.selectedInterface) await this.loadAllStats({ replace: true });
            },

            cancelInterfaceRequests() {
                requestCoordinator.invalidateMany([
                    'realtime', 'minute', 'range', 'stat-h', 'stat-d', 'stat-m', 'stat-y'
                ]);
                this.realtimeStats.loading = false;
                this.minuteStats.loading = false;
                this.dateRangeStats.loading = false;
                this.stats.forEach(stat => { stat.loading = false; });
            },

            resetInterfaceState() {
                this.destroyAllCharts();
                this.activeRealtimeInterface = this.selectedInterface;
                this.realtimeData = [];
                this.realtimeStats.data = [];
                this.realtimeStats.error = null;
                this.minuteStats.data = [];
                this.minuteStats.error = null;
                this.stats.forEach(stat => {
                    stat.data = [];
                    stat.error = null;
                });
                this.clearDateRangeStats();
                this.lastRealtimeTimestamp = 0;
                this.lastRealtimeServerStale = false;
                this.lastSampleReceivedAt = 0;
                this.lastUpdateTime = '';
                this.realtimeStale = true;
            },

            async loadStats(stat, index, options = {}) {
                if (!this.selectedInterface) return false;
                const key = `stat-${stat.period}`;
                const ticket = requestCoordinator.begin(key, { replace: options.replace === true });
                if (!ticket) return false;

                const expectedContext = this.currentInterfaceContext();
                stat.loading = true;
                stat.error = null;
                try {
                    const interfacePath = encodeURIComponent(expectedContext.interfaceName);
                    const response = await this.apiGet(`/api/stats/${interfacePath}/${stat.period}`, ticket);
                    if (!this.requestStillApplies(ticket, expectedContext)) return false;
                    stat.data = safeArray(response.data.data);
                    this.$nextTick(() => this.renderStatChart(index));
                    return true;
                } catch (error) {
                    if (isCanceledRequest(error) || !this.requestStillApplies(ticket, expectedContext)) return false;
                    stat.data = [];
                    stat.error = normalizeError(error, '暂时无法读取统计数据');
                    this.destroyChart(`statChart${index}`, `stat-${index}`);
                    return false;
                } finally {
                    if (requestCoordinator.finish(ticket)) stat.loading = false;
                }
            },

            async loadMinuteStats(options = {}) {
                if (!this.selectedInterface) return false;
                const ticket = requestCoordinator.begin('minute', { replace: options.replace === true });
                if (!ticket) return false;

                const expectedContext = this.currentInterfaceContext();
                this.minuteStats.loading = true;
                this.minuteStats.error = null;
                try {
                    const interfacePath = encodeURIComponent(expectedContext.interfaceName);
                    const response = await this.apiGet(`/api/stats/${interfacePath}/5`, ticket);
                    if (!this.requestStillApplies(ticket, expectedContext)) return false;
                    this.minuteStats.data = safeArray(response.data.data).filter(line => String(line).trim());
                    this.$nextTick(() => this.renderMinuteChart());
                    return true;
                } catch (error) {
                    if (isCanceledRequest(error) || !this.requestStillApplies(ticket, expectedContext)) return false;
                    this.minuteStats.data = [];
                    this.minuteStats.error = normalizeError(error, '暂时无法读取分钟统计');
                    this.destroyChart('minuteChart', 'minute');
                    return false;
                } finally {
                    if (requestCoordinator.finish(ticket)) this.minuteStats.loading = false;
                }
            },

            async loadRealtimeStats(options = {}) {
                if (!this.selectedInterface) {
                    this.refreshRealtimeFreshness();
                    return false;
                }
                const ticket = requestCoordinator.begin('realtime', { replace: options.replace === true });
                if (!ticket) {
                    this.refreshRealtimeFreshness();
                    return false;
                }

                const expectedContext = this.currentInterfaceContext();
                this.realtimeStats.loading = true;
                this.realtimeStats.error = null;
                try {
                    const interfacePath = encodeURIComponent(expectedContext.interfaceName);
                    const response = await this.apiGet(`/api/stats/${interfacePath}/l`, ticket);
                    if (!this.requestStillApplies(ticket, expectedContext)) return false;

                    const rawData = safeArray(response.data.data).filter(line => String(line).trim());
                    const responseTimestamp = Number(response.data.timestamp) || Date.now();
                    const parsedData = core.parseRealtimeData(rawData, responseTimestamp);
                    this.realtimeStats.data = rawData;
                    this.lastRealtimeServerStale = response.data.stale === true;
                    // 本地只检测“多久没有成功收到响应”；样本本身的新鲜度由服务端 stale 判定。
                    this.lastSampleReceivedAt = Date.now();

                    if (parsedData && responseTimestamp !== this.lastRealtimeTimestamp) {
                        this.realtimeData.push(parsedData);
                        if (this.realtimeData.length > 20) this.realtimeData.shift();
                        this.lastRealtimeTimestamp = responseTimestamp;
                        this.lastUpdateTime = new Date(responseTimestamp).toLocaleTimeString();
                        this.refreshRealtimeFreshness();
                        this.$nextTick(() => this.renderRealtimeChart());
                        return true;
                    }

                    this.refreshRealtimeFreshness();
                    return false;
                } catch (error) {
                    if (isCanceledRequest(error) || !this.requestStillApplies(ticket, expectedContext)) return false;
                    this.realtimeStats.error = normalizeError(error, '暂时无法读取实时统计');
                    this.refreshRealtimeFreshness();
                    return false;
                } finally {
                    if (requestCoordinator.finish(ticket)) this.realtimeStats.loading = false;
                }
            },

            async loadCacheStats(options = {}) {
                const ticket = requestCoordinator.begin('cache', { replace: options.replace === true });
                if (!ticket) return false;
                this.cacheStatsLoading = true;
                try {
                    const response = await this.apiGet('/api/cache/stats', ticket);
                    if (!requestCoordinator.isCurrent(ticket)) return false;
                    this.cacheStats = response.data;
                    return true;
                } catch (error) {
                    if (!isCanceledRequest(error) && requestCoordinator.isCurrent(ticket)) {
                        console.error('获取缓存统计失败:', normalizeError(error, '未知错误'));
                    }
                    return false;
                } finally {
                    if (requestCoordinator.finish(ticket)) this.cacheStatsLoading = false;
                }
            },

            loadAllStats(options = {}) {
                const replace = options.replace === true;
                const tasks = [this.loadCacheStats({ replace })];
                if (!this.selectedInterface) return Promise.allSettled(tasks);
                tasks.push(
                    this.loadRealtimeStats({ replace }),
                    this.loadMinuteStats({ replace }),
                    ...this.stats.map((stat, index) => this.loadStats(stat, index, { replace }))
                );
                return Promise.allSettled(tasks);
            },

            async loadVersion() {
                const ticket = requestCoordinator.begin('version', { replace: true });
                try {
                    const response = await this.apiGet('/api/version', ticket);
                    if (requestCoordinator.isCurrent(ticket)) this.version = response.data.version || '';
                } catch (error) {
                    if (!isCanceledRequest(error)) console.error('获取版本号失败:', normalizeError(error, '未知错误'));
                } finally {
                    requestCoordinator.finish(ticket);
                }
            },

            async queryDateRange() {
                if (!this.selectedInterface || !this.isDateRangeValid || this.dateRangeStats.loading) return false;
                const ticket = requestCoordinator.begin('range', { replace: true });
                const expectedContext = {
                    interfaceName: this.selectedInterface,
                    start: this.dateRange.start,
                    end: this.dateRange.end
                };
                this.dateRangeStats.loading = true;
                this.dateRangeStats.error = null;

                try {
                    const interfacePath = encodeURIComponent(expectedContext.interfaceName);
                    const response = await this.apiGet(
                        `/api/stats/${interfacePath}/range/${expectedContext.start}/${expectedContext.end}`,
                        ticket
                    );
                    const currentContext = {
                        interfaceName: this.selectedInterface,
                        start: this.dateRange.start,
                        end: this.dateRange.end
                    };
                    if (!this.requestStillApplies(ticket, expectedContext, currentContext)) return false;
                    this.dateRangeStats.data = safeArray(response.data.data);
                    this.$nextTick(() => this.renderDateRangeChart());
                    return true;
                } catch (error) {
                    const currentContext = {
                        interfaceName: this.selectedInterface,
                        start: this.dateRange.start,
                        end: this.dateRange.end
                    };
                    if (isCanceledRequest(error) || !this.requestStillApplies(ticket, expectedContext, currentContext)) return false;
                    this.dateRangeStats.data = [];
                    this.dateRangeStats.error = normalizeError(error, '日期范围查询失败');
                    this.destroyChart('dateRangeChart', 'date-range');
                    return false;
                } finally {
                    if (requestCoordinator.finish(ticket)) this.dateRangeStats.loading = false;
                }
            },

            clearDateRangeStats() {
                requestCoordinator.invalidate('range');
                this.destroyChart('dateRangeChart', 'date-range');
                this.dateRangeStats.data = [];
                this.dateRangeStats.error = null;
                this.dateRangeStats.loading = false;
                this.dateRange.start = '';
                this.dateRange.end = '';
            },

            renderTableHtml(data, unit, factor, label) {
                return core.renderTableHtml(core.formatTableDataUnified(data, unit, factor), label);
            },

            refreshRealtimeFreshness() {
                this.realtimeStale = this.lastRealtimeServerStale || core.isSampleStale(
                    this.lastSampleReceivedAt,
                    Date.now(),
                    realtimeStaleAfterMs
                );
            },

            chartPalette() {
                return this.isDarkMode
                    ? {
                        receive: '#93c5fd',
                        send: '#fdba74',
                        receiveFill: 'rgba(147, 197, 253, 0.14)',
                        sendFill: 'rgba(253, 186, 116, 0.14)'
                    }
                    : {
                        receive: '#1d4ed8',
                        send: '#9a3412',
                        receiveFill: 'rgba(29, 78, 216, 0.10)',
                        sendFill: 'rgba(154, 52, 18, 0.10)'
                    };
            },

            chartOptions(unit) {
                const reducedMotion = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches === true;
                const textColor = this.isDarkMode ? '#f1f5f9' : '#1f2937';
                const gridColor = this.isDarkMode ? 'rgba(241, 245, 249, 0.16)' : 'rgba(31, 41, 55, 0.12)';
                return {
                    responsive: true,
                    maintainAspectRatio: false,
                    animation: reducedMotion ? false : undefined,
                    plugins: {
                        legend: { display: true, labels: { color: textColor } },
                        tooltip: { enabled: true }
                    },
                    scales: {
                        x: { ticks: { color: textColor }, grid: { color: gridColor } },
                        y: {
                            beginAtZero: true,
                            ticks: { color: textColor },
                            grid: { color: gridColor },
                            title: { display: true, text: unit, color: textColor }
                        }
                    }
                };
            },

            renderTrafficChart(canvas, data, options = {}) {
                const parsed = core.parseStatData(data);
                if (parsed.labels.length === 0) return null;
                const palette = this.chartPalette();
                const isBar = options.type === 'bar';
                return new Chart(canvas, {
                    type: options.type || 'line',
                    data: {
                        labels: parsed.labels,
                        datasets: [
                            {
                                label: `接收(${options.unit})`,
                                data: parsed.rx,
                                borderColor: palette.receive,
                                backgroundColor: isBar ? palette.receive : palette.receiveFill,
                                tension: 0.3,
                                fill: !isBar
                            },
                            {
                                label: `发送(${options.unit})`,
                                data: parsed.tx,
                                borderColor: palette.send,
                                backgroundColor: isBar ? palette.send : palette.sendFill,
                                tension: 0.3,
                                fill: !isBar
                            }
                        ]
                    },
                    options: this.chartOptions(options.unit)
                });
            },

            renderRealtimeChart() {
                chartScheduler.requestRender(
                    'realtime',
                    () => this.$refs.realtimeChart,
                    () => this.realtimeData,
                    (canvas, data) => {
                        const cutoff = Date.now() - 60000;
                        const recent = data.filter(item => item.timestamp >= cutoff);
                        const chartData = recent.length > 0 ? recent : data.slice(-1);
                        const palette = this.chartPalette();
                        return new Chart(canvas, {
                            type: 'line',
                            data: {
                                labels: chartData.map(item => item.time),
                                datasets: [
                                    {
                                        label: '接收速度(Mb/秒)',
                                        data: chartData.map(item => item.receiveSpeed),
                                        borderColor: palette.receive,
                                        backgroundColor: palette.receiveFill,
                                        tension: 0.3,
                                        fill: true
                                    },
                                    {
                                        label: '发送速度(Mb/秒)',
                                        data: chartData.map(item => item.sendSpeed),
                                        borderColor: palette.send,
                                        backgroundColor: palette.sendFill,
                                        tension: 0.3,
                                        fill: true
                                    }
                                ]
                            },
                            options: this.chartOptions('速度 (Mb/秒)')
                        });
                    }
                );
            },

            renderMinuteChart() {
                chartScheduler.requestRender(
                    'minute',
                    () => this.$refs.minuteChart,
                    () => this.minuteStats.data,
                    (canvas, data) => this.renderTrafficChart(canvas, data, { unit: this.minuteStats.unit })
                );
            },

            renderStatChart(index) {
                const stat = this.stats[index];
                chartScheduler.requestRender(
                    `stat-${index}`,
                    () => this.$refs[`statChart${index}`],
                    () => stat.data,
                    (canvas, data) => this.renderTrafficChart(canvas, data, {
                        unit: stat.unit,
                        type: stat.period === 'y' ? 'bar' : 'line'
                    })
                );
            },

            renderDateRangeChart() {
                chartScheduler.requestRender(
                    'date-range',
                    () => this.$refs.dateRangeChart,
                    () => this.dateRangeStats.data,
                    (canvas, data) => this.renderTrafficChart(canvas, data, { unit: this.dateRangeStats.unit })
                );
            },

            destroyChart(refName, schedulerKey) {
                chartScheduler.cancel(schedulerKey);
                let canvas = this.$refs[refName];
                if (Array.isArray(canvas)) canvas = canvas[0];
                if (canvas?._chartInstance) {
                    canvas._chartInstance.destroy();
                    canvas._chartInstance = null;
                }
            },

            destroyAllCharts() {
                chartScheduler.clear();
                document.querySelectorAll('#app canvas').forEach(canvas => {
                    canvas._chartInstance?.destroy?.();
                    canvas._chartInstance = null;
                });
            },

            rerenderVisibleCharts() {
                if (this.realtimeData.length) this.renderRealtimeChart();
                if (this.minuteStats.data.length) this.renderMinuteChart();
                this.stats.forEach((stat, index) => {
                    if (stat.data.length) this.renderStatChart(index);
                });
                if (this.dateRangeStats.data.length) this.renderDateRangeChart();
            },

            applyThemeFromPreference() {
                let storedTheme = null;
                try {
                    storedTheme = localStorage.getItem('theme');
                } catch (_) {
                    // 浏览器禁用存储时仍可使用默认主题。
                }
                this.isDarkMode = storedTheme === 'dark';
                document.body.classList.toggle('dark', this.isDarkMode);
            },

            toggleTheme() {
                this.isDarkMode = !this.isDarkMode;
                document.body.classList.toggle('dark', this.isDarkMode);
                try {
                    localStorage.setItem('theme', this.isDarkMode ? 'dark' : 'light');
                } catch (_) {
                    // 主题仍在当前页面生效，不因存储不可用而中断。
                }
                this.$nextTick(() => this.rerenderVisibleCharts());
            },

            clearAllIntervals() {
                for (const property of ['_realtimeInterval', '_statsInterval', '_freshnessInterval']) {
                    if (this[property]) window.clearInterval(this[property]);
                    this[property] = null;
                }
            },

            startAutoRefresh() {
                this.clearAllIntervals();
                if (document.hidden || !this.initialized) return;

                this._freshnessInterval = window.setInterval(() => this.refreshRealtimeFreshness(), 5000);
                if (!this.autoRefresh) return;

                this._realtimeInterval = window.setInterval(() => {
                    this.refreshRealtimeFreshness();
                    if (this.selectedInterface) this.loadRealtimeStats();
                }, 5000);
                this._statsInterval = window.setInterval(() => {
                    if (this.selectedInterface) {
                        this.loadMinuteStats();
                        this.stats.forEach((stat, index) => this.loadStats(stat, index));
                    }
                    this.loadCacheStats();
                }, 180000);
            },

            cancelPollingRequests() {
                requestCoordinator.invalidateMany(pollingRequestKeys);
                this.realtimeStats.loading = false;
                this.minuteStats.loading = false;
                this.cacheStatsLoading = false;
                this.stats.forEach(stat => { stat.loading = false; });
            },

            handleVisibilityChange() {
                if (document.hidden) {
                    this.clearAllIntervals();
                    this.cancelPollingRequests();
                    return;
                }

                this.refreshRealtimeFreshness();
                this.startAutoRefresh();
                if (this.initialized && this.autoRefresh && this.selectedInterface) {
                    this.loadRealtimeStats({ replace: true });
                }
            }
        },

        watch: {
            autoRefresh() {
                this.startAutoRefresh();
                if (this.autoRefresh && !document.hidden && this.initialized && this.selectedInterface) {
                    this.loadRealtimeStats({ replace: true });
                }
            }
        },

        mounted() {
            this.applyThemeFromPreference();
            this.loadVersion();
            this._visibilityHandler = () => this.handleVisibilityChange();
            document.addEventListener('visibilitychange', this._visibilityHandler);

            this.loadInterfaces().finally(() => {
                this.initialized = true;
                this.refreshRealtimeFreshness();
                this.startAutoRefresh();
            });
        },

        beforeUnmount() {
            this.clearAllIntervals();
            requestCoordinator.invalidateAll();
            chartScheduler.clear();
            this.destroyAllCharts();
            if (this._visibilityHandler) {
                document.removeEventListener('visibilitychange', this._visibilityHandler);
            }
        }
    });

    app.mount('#app');
    window.performance?.mark?.('app-mounted');
    if (window.performance?.measure) {
        try {
            window.performance.measure('app-load-time', 'app-start', 'app-mounted');
        } catch (_) {
            // 部分浏览器会清理早期标记，性能记录失败不影响应用。
        }
    }
})();
