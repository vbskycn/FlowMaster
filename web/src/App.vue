<template>
  <div class="min-h-screen flex flex-col bg-slate-50 text-slate-900 dark:bg-slate-950 dark:text-slate-100 transition-colors">
    <!-- 顶部品牌与全局模式切换栏 -->
    <header class="sticky top-0 z-30 border-b border-slate-200/80 dark:border-slate-800/80 bg-white/85 dark:bg-slate-900/85 backdrop-blur-md">
      <div class="max-w-7xl mx-auto px-4 sm:px-6 py-3 flex flex-wrap items-center justify-between gap-3">
        <!-- 品牌区 + 系统版本号 + 多机/单机视图切换 -->
        <div class="flex flex-wrap items-center gap-3 min-w-0">
          <button
            type="button"
            class="flex items-center gap-2.5 min-w-0 text-left cursor-pointer hover:opacity-85 transition-opacity"
            title="返回首页"
            @click="goHome"
          >
            <img src="/favicon.svg" alt="FlowMaster" class="w-8 h-8 rounded-xl shrink-0 shadow-xs" />
            <div class="flex items-baseline gap-2 min-w-0">
              <h1 class="text-base sm:text-lg font-bold tracking-tight truncate">{{ boot.siteTitle }}</h1>
              <span
                v-if="boot.version"
                class="font-num text-xs px-2 py-0.5 rounded-full bg-blue-50 text-blue-700 dark:bg-blue-950/90 dark:text-blue-300 border border-blue-200/70 dark:border-blue-800/70 shrink-0"
              >
                v{{ boot.version }}
              </span>
            </div>
          </button>

          <!-- 顶栏一级视图切换：仅在后台设置开启“主控模式”后显示多机总览与节点管理入口 -->
          <div
            v-if="boot.hubModeEnabled && (!boot.requireLoginForView || boot.authenticated) && (boot.authenticated || clusterState.nodes.length <= 1)"
            class="inline-flex items-center p-0.5 rounded-xl bg-slate-100 dark:bg-slate-950 border border-slate-200/80 dark:border-slate-800 text-xs"
          >
            <button
              type="button"
              class="px-3 py-1 rounded-lg font-medium transition-all cursor-pointer"
              :class="viewMode === 'fleet'
                ? 'bg-white dark:bg-slate-800 text-blue-600 dark:text-blue-400 shadow-2xs'
                : 'text-slate-600 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-200'"
              @click="switchViewMode('fleet')"
            >
              🌐 多机总览 ({{ clusterState.nodes.length || 1 }})
            </button>
            <button
              type="button"
              class="px-3 py-1 rounded-lg font-medium transition-all cursor-pointer"
              :class="viewMode === 'single'
                ? 'bg-white dark:bg-slate-800 text-blue-600 dark:text-blue-400 shadow-2xs'
                : 'text-slate-600 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-200'"
              @click="switchViewMode('single')"
            >
              🖥️ 单机详情
            </button>
          </div>
        </div>

        <!-- 右侧实时状态与功能按钮 -->
        <div class="flex flex-wrap items-center gap-2">
          <!-- 单机视图下的实时流状态指示 -->
          <button
            v-if="viewMode === 'single'"
            type="button"
            class="inline-flex items-center gap-1.5 px-2.5 py-1.5 rounded-lg text-xs border border-slate-200 dark:border-slate-800 bg-slate-50 dark:bg-slate-950 cursor-pointer"
            :title="livePaused ? '点击恢复实时推送' : '点击暂停实时推送'"
            @click="toggleLivePause"
          >
            <span class="w-2 h-2 rounded-full"
              :class="livePaused ? 'bg-amber-400' : (streamConnected ? 'bg-emerald-500 animate-pulse' : 'bg-slate-400')"></span>
            <span>{{ livePaused ? '已暂停' : (streamConnected ? '实时同步' : '采样中') }}</span>
          </button>

          <!-- 速率单位切换 (Mbps / MiB/s) -->
          <button
            type="button"
            class="px-2.5 py-1.5 rounded-lg text-xs font-num border border-slate-200 dark:border-slate-800 hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer"
            title="切换比特率 (Mbps) 与字节率 (MiB/s)"
            @click="toggleRateUnit"
          >
            {{ rateMode === 'bits' ? 'Mbps' : 'MiB/s' }}
          </button>

          <!-- 明暗主题切换 -->
          <button
            type="button"
            class="px-2.5 py-1.5 rounded-lg text-xs border border-slate-200 dark:border-slate-800 hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer"
            :aria-label="isDark ? '切换为浅色模式' : '切换为深色模式'"
            @click="toggleTheme"
          >
            {{ isDark ? '☀️ 浅色' : '🌙 深色' }}
          </button>

          <!-- 管理后台入口 -->
          <button
            type="button"
            class="px-3.5 py-1.5 rounded-lg text-xs font-medium bg-slate-900 text-white dark:bg-slate-100 dark:text-slate-900 hover:opacity-90 cursor-pointer"
            @click="openAdmin"
          >
            {{ boot.authenticated ? '⚙️ 本机后台' : '🔒 管理登录' }}
          </button>
        </div>
      </div>
    </header>

    <!-- 全站访问保护门禁态 -->
    <main v-if="boot.loaded && boot.requireLoginForView && !boot.authenticated" class="flex-1 flex items-center justify-center p-6">
      <AuthModal
        :needs-setup="boot.needsSetup"
        :blocking="true"
        :version="boot.version"
        :site-title="boot.siteTitle"
        @success="onAuthSuccess"
      />
    </main>

    <!-- 主内容区 -->
    <main v-else class="flex-1 max-w-7xl w-full mx-auto px-4 sm:px-6 py-5 space-y-5">
      <div v-if="globalError" class="p-3.5 rounded-xl bg-red-50 dark:bg-red-950/50 border border-red-200 dark:border-red-900 text-xs text-red-700 dark:text-red-300 flex items-center justify-between">
        <span>{{ globalError }}</span>
        <button type="button" class="underline ml-3 cursor-pointer" @click="initDashboard">重试</button>
      </div>

      <!-- ==================== 模式 A：多机总览墙与横向对比中心（仅开启主控模式后展示） ==================== -->
      <FleetOverview
        v-if="boot.hubModeEnabled && viewMode === 'fleet'"
        :nodes="clusterState.nodes"
        :hub-version="clusterState.hubVersion || boot.version"
        :latest-version="clusterState.latestReleaseVersion"
        :public-hub-url="clusterState.publicHubUrl"
        :authenticated="boot.authenticated"
        :rate-mode="rateMode"
        :dark="isDark"
        @select-node="drillIntoNode"
        @require-auth="showAuthModal = true"
        @refresh="loadClusterFleet"
      />

      <!-- ==================== 模式 B：单机全景监控详情（支持本机与任意远程机器无缝下钻） ==================== -->
      <template v-else>
        <!-- 多机环境下的节点快捷切换与返回总览导航条 -->
        <section
          v-if="boot.hubModeEnabled && (clusterState.nodes.length > 1 || activeNodeId !== 'local')"
          class="p-3.5 rounded-2xl bg-blue-50/70 dark:bg-blue-950/30 border border-blue-200/80 dark:border-blue-900/70 flex flex-wrap items-center justify-between gap-3"
        >
          <div class="flex flex-wrap items-center gap-2.5 text-xs">
            <button
              type="button"
              class="px-3 py-1.5 rounded-xl font-medium bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-700 hover:bg-slate-50 dark:hover:bg-slate-800 cursor-pointer"
              @click="switchViewMode('fleet')"
            >
              ← 返回多机总览
            </button>
            <span class="text-slate-500 dark:text-slate-400">当前查看服务器：</span>
            <select
              :value="activeNodeId"
              class="px-3 py-1.5 rounded-xl font-semibold bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-700"
              @change="drillIntoNode($event.target.value)"
            >
              <option v-for="n in clusterState.nodes" :key="n.id" :value="n.id">
                {{ n.online ? '🟢' : '🔴' }} {{ n.name }} {{ n.version ? `(v${n.version})` : '' }}
              </option>
            </select>
          </div>

          <div v-if="activeNodeSummary && !activeNodeSummary.isLocal" class="flex items-center gap-2 text-xs">
            <span class="font-num text-slate-500">
              {{ activeNodeSummary.os }}/{{ activeNodeSummary.arch }}
            </span>
            <button
              type="button"
              class="px-3 py-1.5 rounded-xl font-medium bg-slate-900 text-white dark:bg-slate-100 dark:text-slate-900 cursor-pointer"
              @click="openActiveRemoteConfig"
            >
              ⚙️ 远程配置该机器
            </button>
          </div>
        </section>

        <!-- 网卡切换与 IPv4/IPv6 链路元数据条 -->
        <section class="p-3.5 rounded-2xl bg-white dark:bg-slate-900 border border-slate-200/80 dark:border-slate-800 shadow-2xs flex flex-wrap items-center justify-between gap-3">
          <div class="flex flex-wrap items-center gap-2">
            <span class="text-xs font-medium text-slate-500 dark:text-slate-400 mr-1">监控网卡</span>
            <button
              v-for="nic in interfaces"
              :key="nic.name"
              type="button"
              class="px-3 py-1.5 rounded-xl text-xs font-medium transition-all cursor-pointer flex items-center gap-1.5"
              :class="selectedInterface === nic.name
                ? 'bg-blue-600 text-white shadow-xs'
                : 'bg-slate-100 dark:bg-slate-800 text-slate-700 dark:text-slate-300 hover:bg-slate-200/70 dark:hover:bg-slate-700'"
              @click="selectInterface(nic.name)"
            >
              <span class="w-1.5 h-1.5 rounded-full" :class="nic.operState === 'up' ? 'bg-emerald-400' : 'bg-slate-400'"></span>
              <span class="font-num">{{ nic.name }}</span>
              <span v-if="nic.alias" class="opacity-85">({{ nic.alias }})</span>
            </button>
            <span v-if="!interfacesLoading && interfaces.length === 0" class="text-xs text-slate-400">
              暂未检测到可见网卡
            </span>
          </div>

          <div v-if="currentNicMeta" class="flex flex-wrap items-center gap-3 text-xs text-slate-500 dark:text-slate-400 font-num">
            <span v-if="boot.authenticated && singleNodeDisplayIPv4" :title="singleNodeIPv4Tooltip">IPv4: {{ singleNodeDisplayIPv4 }}</span>
            <span v-if="boot.authenticated && currentNicMeta.ipv6?.length" class="truncate max-w-60" :title="currentNicMeta.ipv6.join(', ')">
              IPv6: {{ currentNicMeta.ipv6[0] }}
            </span>
            <span v-if="currentNicMeta.speedMbps > 0">{{ currentNicMeta.speedMbps }} Mbps</span>
            <span v-if="boot.authenticated && currentNicMeta.mac" class="hidden sm:inline">MAC: {{ currentNicMeta.mac }}</span>
          </div>
        </section>

        <!-- 主机 CPU / 内存 / 硬盘实时负载条 -->
        <section
          v-if="activeNodeSummary?.host && (activeNodeSummary.host.memTotalBytes > 0 || activeNodeSummary.host.diskTotalBytes > 0)"
          class="grid grid-cols-1 sm:grid-cols-3 gap-3.5"
        >
          <div class="p-3.5 rounded-2xl bg-white dark:bg-slate-900 border border-slate-200/80 dark:border-slate-800 shadow-2xs">
            <div class="flex items-center justify-between text-xs">
              <span class="text-slate-500 dark:text-slate-400">CPU 负载</span>
              <span class="font-num font-bold text-slate-800 dark:text-slate-100">
                {{ (activeNodeSummary.host.cpuPercent || 0).toFixed(1) }}%
                <span class="font-normal text-slate-400">({{ activeNodeSummary.host.cpuCores || 0 }} 核)</span>
              </span>
            </div>
            <div class="mt-2 h-1.5 w-full rounded-full bg-slate-200 dark:bg-slate-800 overflow-hidden">
              <div
                class="h-full rounded-full transition-all duration-300"
                :class="(activeNodeSummary.host.cpuPercent || 0) >= 90 ? 'bg-red-500' : ((activeNodeSummary.host.cpuPercent || 0) >= 75 ? 'bg-amber-500' : 'bg-blue-600')"
                :style="{ width: Math.min(100, activeNodeSummary.host.cpuPercent || 0) + '%' }"
              ></div>
            </div>
          </div>

          <div class="p-3.5 rounded-2xl bg-white dark:bg-slate-900 border border-slate-200/80 dark:border-slate-800 shadow-2xs">
            <div class="flex items-center justify-between text-xs">
              <span class="text-slate-500 dark:text-slate-400">内存占用</span>
              <span class="font-num font-bold text-slate-800 dark:text-slate-100">
                {{ formatBytes(activeNodeSummary.host.memUsedBytes) }} / {{ formatBytes(activeNodeSummary.host.memTotalBytes) }}
                <span class="font-normal text-slate-400">({{ (activeNodeSummary.host.memPercent || 0).toFixed(1) }}%)</span>
              </span>
            </div>
            <div class="mt-2 h-1.5 w-full rounded-full bg-slate-200 dark:bg-slate-800 overflow-hidden">
              <div
                class="h-full rounded-full transition-all duration-300"
                :class="(activeNodeSummary.host.memPercent || 0) >= 90 ? 'bg-red-500' : ((activeNodeSummary.host.memPercent || 0) >= 75 ? 'bg-amber-500' : 'bg-emerald-500')"
                :style="{ width: Math.min(100, activeNodeSummary.host.memPercent || 0) + '%' }"
              ></div>
            </div>
          </div>

          <div class="p-3.5 rounded-2xl bg-white dark:bg-slate-900 border border-slate-200/80 dark:border-slate-800 shadow-2xs">
            <div class="flex items-center justify-between text-xs">
              <span class="text-slate-500 dark:text-slate-400">硬盘空间 (/)</span>
              <span class="font-num font-bold text-slate-800 dark:text-slate-100">
                {{ formatBytes(activeNodeSummary.host.diskUsedBytes) }} / {{ formatBytes(activeNodeSummary.host.diskTotalBytes) }}
                <span class="font-normal text-slate-400">({{ (activeNodeSummary.host.diskPercent || 0).toFixed(1) }}%)</span>
              </span>
            </div>
            <div class="mt-2 h-1.5 w-full rounded-full bg-slate-200 dark:bg-slate-800 overflow-hidden">
              <div
                class="h-full rounded-full transition-all duration-300"
                :class="(activeNodeSummary.host.diskPercent || 0) >= 90 ? 'bg-red-500' : ((activeNodeSummary.host.diskPercent || 0) >= 75 ? 'bg-amber-500' : 'bg-indigo-500')"
                :style="{ width: Math.min(100, activeNodeSummary.host.diskPercent || 0) + '%' }"
              ></div>
            </div>
          </div>
        </section>

        <!-- 核心指标 4 宫格卡片 -->
        <section class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
          <div class="p-4 rounded-2xl bg-white dark:bg-slate-900 border border-slate-200/80 dark:border-slate-800 shadow-2xs">
            <div class="flex items-center justify-between text-xs text-slate-500 dark:text-slate-400">
              <span>实时下行速率 (RX)</span>
              <span class="px-1.5 py-0.5 rounded bg-blue-50 text-blue-600 dark:bg-blue-950 dark:text-blue-300 font-num">↓ IN</span>
            </div>
            <div class="mt-2 text-2xl font-bold font-num text-blue-600 dark:text-blue-400">
              {{ formatRate(latestRealtime.rxBytesPerSec, rateMode) }}
            </div>
            <div class="mt-1.5 flex items-center justify-between text-[11px] text-slate-400 font-num">
              <span>{{ Math.round(latestRealtime.rxPacketsPerSec || 0) }} pkt/s</span>
              <span>近期峰值 {{ formatRate(realtimePeakRx, rateMode) }}</span>
            </div>
          </div>

          <div class="p-4 rounded-2xl bg-white dark:bg-slate-900 border border-slate-200/80 dark:border-slate-800 shadow-2xs">
            <div class="flex items-center justify-between text-xs text-slate-500 dark:text-slate-400">
              <span>实时上行速率 (TX)</span>
              <span class="px-1.5 py-0.5 rounded bg-emerald-50 text-emerald-600 dark:bg-emerald-950 dark:text-emerald-300 font-num">↑ OUT</span>
            </div>
            <div class="mt-2 text-2xl font-bold font-num text-emerald-600 dark:text-emerald-400">
              {{ formatRate(latestRealtime.txBytesPerSec, rateMode) }}
            </div>
            <div class="mt-1.5 flex items-center justify-between text-[11px] text-slate-400 font-num">
              <span>{{ Math.round(latestRealtime.txPacketsPerSec || 0) }} pkt/s</span>
              <span>近期峰值 {{ formatRate(realtimePeakTx, rateMode) }}</span>
            </div>
          </div>

          <div class="p-4 rounded-2xl bg-white dark:bg-slate-900 border border-slate-200/80 dark:border-slate-800 shadow-2xs">
            <div class="flex items-center justify-between text-xs text-slate-500 dark:text-slate-400">
              <span>今日累计流量</span>
              <span class="font-num">{{ todayPoint.label || '今日' }}</span>
            </div>
            <div class="mt-2 text-2xl font-bold font-num text-slate-900 dark:text-white">
              {{ formatBytes(todayPoint.totalBytes) }}
            </div>
            <div class="mt-1.5 flex items-center justify-between text-[11px] text-slate-500 dark:text-slate-400 font-num">
              <span>↓ {{ formatBytes(todayPoint.rxBytes) }}</span>
              <span>↑ {{ formatBytes(todayPoint.txBytes) }}</span>
            </div>
          </div>

          <div class="p-4 rounded-2xl bg-white dark:bg-slate-900 border border-slate-200/80 dark:border-slate-800 shadow-2xs">
            <template v-if="quotaStatus.enabled && quotaStatus.limitBytes > 0">
              <div class="flex items-center justify-between text-xs text-slate-500 dark:text-slate-400">
                <span>月度流量包 ({{ quotaDirectionLabel }})</span>
                <span class="font-num text-[11px]">{{ quotaStatus.cycleStart?.slice(5) }}~{{ quotaStatus.cycleEnd?.slice(5) }}</span>
              </div>
              <div class="mt-1.5 flex items-baseline justify-between">
                <span class="text-xl font-bold font-num" :class="quotaColorClass">
                  {{ formatBytes(quotaStatus.usedBytes) }}
                </span>
                <span class="text-xs font-num text-slate-500">
                  / {{ formatBytes(quotaStatus.limitBytes) }} ({{ (quotaStatus.usagePercent || 0).toFixed(1) }}%)
                </span>
              </div>
              <div class="mt-2 w-full h-2 rounded-full bg-slate-200 dark:bg-slate-800 overflow-hidden">
                <div
                  class="h-full rounded-full transition-all duration-300"
                  :class="quotaStatus.overLimit ? 'bg-red-500' : (quotaStatus.overWarn ? 'bg-amber-500' : 'bg-blue-600')"
                  :style="{ width: Math.min(100, quotaStatus.usagePercent || 0) + '%' }"
                ></div>
              </div>
              <div class="mt-1.5 flex items-center justify-between text-[11px] text-slate-400 font-num">
                <span>剩余 {{ formatBytes(quotaStatus.remainingBytes) }}</span>
                <span>预计周期末 {{ formatBytes(quotaStatus.projectedBytes) }}</span>
              </div>
            </template>
            <template v-else>
              <div class="flex items-center justify-between text-xs text-slate-500 dark:text-slate-400">
                <span>本月累计流量</span>
                <button
                  type="button"
                  class="text-[11px] text-blue-600 dark:text-blue-400 hover:underline cursor-pointer"
                  @click="activeNodeId === 'local' ? openAdmin() : openActiveRemoteConfig()"
                >
                  设置流量包配额
                </button>
              </div>
              <div class="mt-2 text-2xl font-bold font-num text-slate-900 dark:text-white">
                {{ formatBytes(thisMonthPoint.totalBytes) }}
              </div>
              <div class="mt-1.5 flex items-center justify-between text-[11px] text-slate-500 dark:text-slate-400 font-num">
                <span>↓ {{ formatBytes(thisMonthPoint.rxBytes) }}</span>
                <span>↑ {{ formatBytes(thisMonthPoint.txBytes) }}</span>
              </div>
            </template>
          </div>
        </section>

        <!-- 实时吞吐波形图 -->
        <section class="p-5 rounded-2xl bg-white dark:bg-slate-900 border border-slate-200/80 dark:border-slate-800 shadow-2xs">
          <div class="flex flex-wrap items-center justify-between gap-2 mb-3">
            <div>
              <h2 class="text-sm sm:text-base font-bold text-slate-900 dark:text-white">实时吞吐波形</h2>
              <p class="text-xs text-slate-500 dark:text-slate-400">最近 60 次动态采样曲线（页面切至后台标签时自动休眠省电）</p>
            </div>
            <span v-if="lastSampleTimeText" class="text-xs font-num text-slate-400">
              最新样本：{{ lastSampleTimeText }}
            </span>
          </div>
          <TrafficChart
            type="line"
            :labels="realtimeChartData.labels"
            :rx-data="realtimeChartData.rx"
            :tx-data="realtimeChartData.tx"
            rx-label="实时下行"
            tx-label="实时上行"
            :unit="realtimeChartData.unit"
            :dark="isDark"
            :height="240"
            :animate="false"
          />
        </section>

        <!-- 多周期历史统计分析与增强分页表 -->
        <section class="p-5 rounded-2xl bg-white dark:bg-slate-900 border border-slate-200/80 dark:border-slate-800 shadow-2xs space-y-4">
          <div class="flex flex-col md:flex-row md:items-center md:justify-between gap-3">
            <div class="inline-flex flex-wrap items-center gap-1 p-1 rounded-xl bg-slate-100 dark:bg-slate-950 border border-slate-200/60 dark:border-slate-800">
              <button
                v-for="p in periodTabs"
                :key="p.key"
                type="button"
                class="px-3.5 py-1.5 rounded-lg text-xs font-medium transition-all cursor-pointer"
                :class="activePeriod === p.key
                  ? 'bg-white dark:bg-slate-800 text-blue-600 dark:text-blue-400 shadow-2xs'
                  : 'text-slate-600 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-200'"
                @click="switchPeriod(p.key)"
              >
                {{ p.label }}
              </button>
            </div>

            <div class="flex items-center gap-2 text-xs text-slate-500 dark:text-slate-400">
              <span v-if="statsResult.source" class="px-2 py-1 rounded bg-slate-100 dark:bg-slate-800 font-num">
                引擎: {{ statsResult.source }}
              </span>
              <button
                type="button"
                class="px-3 py-1.5 rounded-lg border border-slate-200 dark:border-slate-800 hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer"
                :disabled="statsLoading"
                @click="refreshActiveStats"
              >
                {{ statsLoading ? '加载中…' : '刷新统计' }}
              </button>
            </div>
          </div>

          <div v-if="activePeriod === 'range'" class="p-3.5 rounded-xl bg-slate-50 dark:bg-slate-950/70 border border-slate-200/70 dark:border-slate-800 flex flex-wrap items-end gap-3">
            <div>
              <label class="block text-[11px] text-slate-500 mb-1">开始日期</label>
              <input v-model="rangeForm.start" type="date" class="px-2.5 py-1.5 text-xs font-num rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900" />
            </div>
            <div>
              <label class="block text-[11px] text-slate-500 mb-1">结束日期</label>
              <input v-model="rangeForm.end" type="date" class="px-2.5 py-1.5 text-xs font-num rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900" />
            </div>
            <button
              type="button"
              class="px-4 py-1.5 text-xs font-medium rounded-lg bg-blue-600 hover:bg-blue-700 text-white cursor-pointer"
              @click="loadRangeStats"
            >
              查询区间
            </button>
            <div class="flex items-center gap-1.5 text-xs ml-auto">
              <button type="button" class="px-2.5 py-1 rounded border border-slate-200 dark:border-slate-700 hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer" @click="applyQuickRange(7)">近 7 天</button>
              <button type="button" class="px-2.5 py-1 rounded border border-slate-200 dark:border-slate-700 hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer" @click="applyQuickRange(30)">近 30 天</button>
              <button type="button" class="px-2.5 py-1 rounded border border-slate-200 dark:border-slate-700 hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer" @click="applyThisMonthRange">本月</button>
            </div>
          </div>

          <div class="grid grid-cols-2 sm:grid-cols-4 gap-3 p-3.5 rounded-xl bg-slate-50/80 dark:bg-slate-950/50 border border-slate-200/60 dark:border-slate-800/80 text-xs">
            <div>
              <span class="text-slate-500 dark:text-slate-400">区间总流量</span>
              <div class="mt-0.5 text-sm font-bold font-num text-slate-900 dark:text-white">{{ formatBytes(statsResult.summary.totalBytes) }}</div>
            </div>
            <div>
              <span class="text-slate-500 dark:text-slate-400">总下行 / 总上行</span>
              <div class="mt-0.5 text-sm font-semibold font-num">
                <span class="text-blue-600 dark:text-blue-400">{{ formatBytes(statsResult.summary.totalRxBytes) }}</span>
                <span class="mx-1 text-slate-400">/</span>
                <span class="text-emerald-600 dark:text-emerald-400">{{ formatBytes(statsResult.summary.totalTxBytes) }}</span>
              </div>
            </div>
            <div>
              <span class="text-slate-500 dark:text-slate-400">最高流量时段</span>
              <div class="mt-0.5 text-sm font-semibold font-num text-slate-800 dark:text-slate-200">{{ statsResult.summary.peakLabel || '—' }}</div>
            </div>
            <div>
              <span class="text-slate-500 dark:text-slate-400">区间平均速率</span>
              <div class="mt-0.5 text-sm font-semibold font-num text-slate-800 dark:text-slate-200">{{ formatBps(statsResult.summary.avgBps) }}</div>
            </div>
          </div>

          <TrafficChart
            v-if="statsResult.points.length > 0"
            :type="activePeriod === 'm' || activePeriod === 'y' ? 'bar' : 'line'"
            :labels="periodChartData.labels"
            :rx-data="periodChartData.rx"
            :tx-data="periodChartData.tx"
            :unit="periodChartData.unit"
            :dark="isDark"
            :height="280"
          />
          <div v-else-if="!statsLoading" class="py-12 text-center text-sm text-slate-400 dark:text-slate-500 border border-dashed border-slate-200 dark:border-slate-800 rounded-xl">
            当前周期暂未产生流量样本，等待下一个采样窗口自动汇入…
          </div>

          <DataTable :rows="statsResult.points" />
        </section>
      </template>
    </main>

    <!-- 页脚品牌与版本 -->
    <footer class="border-t border-slate-200/80 dark:border-slate-800/80 py-4 px-4 text-xs text-slate-500 dark:text-slate-400">
      <div class="max-w-7xl mx-auto flex flex-wrap items-center justify-between gap-2">
        <div class="flex items-center gap-2">
          <span class="font-semibold text-slate-700 dark:text-slate-300">FlowMaster</span>
          <span v-if="boot.version" class="font-num text-[11px] px-1.5 py-0.5 rounded bg-slate-200/70 dark:bg-slate-800">v{{ boot.version }}</span>
          <span>轻量级多主机网络流量统一监控与管理系统</span>
        </div>
        <a
          href="https://github.com/vbskycn/FlowMaster"
          target="_blank"
          rel="noopener noreferrer"
          class="inline-flex items-center gap-1.5 font-medium text-slate-600 dark:text-slate-300 hover:text-blue-600 dark:hover:text-blue-400 transition-colors"
        >
          <svg class="w-4 h-4 fill-current shrink-0" viewBox="0 0 24 24" aria-hidden="true">
            <path fill-rule="evenodd" clip-rule="evenodd" d="M12 2C6.477 2 2 6.484 2 12.017c0 4.425 2.865 8.18 6.839 9.504.5.092.682-.217.682-.483 0-.237-.008-.868-.013-1.703-2.782.605-3.369-1.343-3.369-1.343-.454-1.158-1.11-1.466-1.11-1.466-.908-.62.069-.608.069-.608 1.003.07 1.53 1.032 1.53 1.032.892 1.53 2.341 1.088 2.91.832.092-.647.35-1.088.636-1.338-2.22-.253-4.555-1.113-4.555-4.951 0-1.093.39-1.988 1.029-2.688-.103-.253-.446-1.272.098-2.65 0 0 .84-.27 2.75 1.026A9.564 9.564 0 0112 6.844c.85.004 1.705.115 2.504.337 1.909-1.296 2.747-1.027 2.747-1.027.546 1.379.202 2.398.1 2.651.64.7 1.028 1.595 1.028 2.688 0 3.848-2.339 4.695-4.566 4.943.359.309.678.92.678 1.855 0 1.338-.012 2.419-.012 2.747 0 .268.18.58.688.482A10.019 10.019 0 0022 12.017C22 6.484 17.522 2 12 2z" />
          </svg>
          <span>vbskycn</span>
        </a>
      </div>
    </footer>

    <AuthModal
      v-if="showAuthModal"
      :needs-setup="boot.needsSetup"
      :blocking="false"
      :version="boot.version"
      :site-title="boot.siteTitle"
      @close="showAuthModal = false"
      @success="onAuthModalSuccess"
    />

    <AdminConsole
      v-if="showAdminConsole"
      :version="boot.version"
      :connected-to-hub="boot.connectedToHub"
      @close="showAdminConsole = false"
      @updated="onAdminUpdated"
      @logged-out="onAdminLoggedOut"
    />

    <RemoteNodeConfigModal
      v-if="editingRemoteNode"
      :node="editingRemoteNode"
      :latest-version="clusterState.latestReleaseVersion || boot.version"
      @close="editingRemoteNode = null"
      @updated="onRemoteConfigUpdated"
      @deleted="onRemoteNodeDeleted"
    />
  </div>
</template>

<script setup>
import { ref, reactive, computed, onMounted, onBeforeUnmount } from 'vue';
import TrafficChart from './components/TrafficChart.vue';
import DataTable from './components/DataTable.vue';
import AuthModal from './components/AuthModal.vue';
import AdminConsole from './components/AdminConsole.vue';
import FleetOverview from './components/FleetOverview.vue';
import RemoteNodeConfigModal from './components/RemoteNodeConfigModal.vue';
import { formatBytes, formatRate, formatBps, apiRequest } from './utils/format';

const periodTabs = [
  { key: '5', label: '5 分钟' },
  { key: 'h', label: '小时统计' },
  { key: 'd', label: '按天统计' },
  { key: 'm', label: '按月统计' },
  { key: 'y', label: '按年统计' },
  { key: 'range', label: '自定义区间' }
];

const boot = reactive({
  loaded: false,
  appName: 'FlowMaster',
  version: '',
  siteTitle: 'FlowMaster 流量监控',
  requireLoginForView: false,
  dataSourceMode: 'hybrid',
  hubModeEnabled: false,
  authenticated: false,
  needsSetup: false,
  vnstatAvailable: false,
  vnstatVersion: '',
  remoteNodeCount: 0,
  connectedToHub: false
});

const viewMode = ref('single');
const hasChosenInitialView = ref(false);
const activeNodeId = ref('local');

const clusterState = reactive({
  hubVersion: '',
  latestReleaseVersion: '',
  publicHubUrl: '',
  nodes: []
});

const isDark = ref(false);
const rateMode = ref('bits');
const livePaused = ref(false);
const streamConnected = ref(false);
const globalError = ref('');

const interfaces = ref([]);
const interfacesLoading = ref(false);
const selectedInterface = ref('');

const realtimeSamples = ref([]);
const latestRealtime = reactive({
  rxBytesPerSec: 0,
  txBytesPerSec: 0,
  rxPacketsPerSec: 0,
  txPacketsPerSec: 0,
  timestamp: 0
});

const todayPoint = reactive({ label: '', rxBytes: 0, txBytes: 0, totalBytes: 0 });
const thisMonthPoint = reactive({ label: '', rxBytes: 0, txBytes: 0, totalBytes: 0 });
const quotaStatus = reactive({
  enabled: false,
  interface: '',
  direction: 'both',
  cycleStart: '',
  cycleEnd: '',
  usedBytes: 0,
  limitBytes: 0,
  remainingBytes: 0,
  usagePercent: 0,
  projectedBytes: 0,
  overWarn: false,
  overLimit: false
});

const activePeriod = ref('5');
const statsLoading = ref(false);
const statsResult = reactive({
  source: '',
  points: [],
  summary: {
    totalRxBytes: 0,
    totalTxBytes: 0,
    totalBytes: 0,
    peakLabel: '',
    avgBps: 0
  }
});

const rangeForm = reactive({ start: '', end: '' });

const showAuthModal = ref(false);
const showAdminConsole = ref(false);
const editingRemoteNode = ref(null);

let sseSource = null;
let fleetPollTimer = null;
let summaryRefreshTimer = null;

const activeNodeSummary = computed(() => clusterState.nodes.find(n => n.id === activeNodeId.value) || null);
const currentNicMeta = computed(() => interfaces.value.find(i => i.name === selectedInterface.value) || null);

function isPrivateOrLoopbackIPv4(ip) {
  if (!ip || ip.includes(':')) return true;
  if (ip.startsWith('127.') || ip.startsWith('10.') || ip.startsWith('192.168.') || ip.startsWith('169.254.')) return true;
  const m172 = /^172\.(\d+)\./.exec(ip);
  if (m172 && Number(m172[1]) >= 16 && Number(m172[1]) <= 31) return true;
  const m100 = /^100\.(\d+)\./.exec(ip);
  if (m100 && Number(m100[1]) >= 64 && Number(m100[1]) <= 127) return true;
  return false;
}

const singleNodeDisplayIPv4 = computed(() => {
  const nicIPs = currentNicMeta.value?.ipv4 || [];
  const publicNic = nicIPs.find(ip => !isPrivateOrLoopbackIPv4(ip));
  if (publicNic) return publicNic;
  const ep = activeNodeSummary.value?.endpointIp || '';
  if (ep && !isPrivateOrLoopbackIPv4(ep)) return ep;
  return nicIPs[0] || '';
});

const singleNodeIPv4Tooltip = computed(() => {
  const pub = singleNodeDisplayIPv4.value;
  const nicFirst = currentNicMeta.value?.ipv4?.[0] || '';
  if (pub && nicFirst && pub !== nicFirst) {
    return `公网 IPv4: ${pub} | 内网网卡: ${nicFirst}`;
  }
  return pub;
});

function goHome() {
  showAdminConsole.value = false;
  editingRemoteNode.value = null;
  if (boot.hubModeEnabled && clusterState.nodes.length > 1) {
    switchViewMode('fleet');
  } else {
    activeNodeId.value = 'local';
    switchViewMode('single');
  }
  window.scrollTo({ top: 0, behavior: 'smooth' });
}

const realtimePeakRx = computed(() => {
  let m = 0;
  for (const s of realtimeSamples.value) if (s.rxBytesPerSec > m) m = s.rxBytesPerSec;
  return m;
});

const realtimePeakTx = computed(() => {
  let m = 0;
  for (const s of realtimeSamples.value) if (s.txBytesPerSec > m) m = s.txBytesPerSec;
  return m;
});

const lastSampleTimeText = computed(() => {
  if (!latestRealtime.timestamp) return '';
  return new Date(latestRealtime.timestamp).toLocaleTimeString('zh-CN', { hour12: false });
});

const quotaDirectionLabel = computed(() => {
  const map = { both: '双向', tx: '仅上行', rx: '仅下行', max: '单向取大' };
  return map[quotaStatus.direction] || '双向';
});

const quotaColorClass = computed(() => {
  if (quotaStatus.overLimit) return 'text-red-600 dark:text-red-400';
  if (quotaStatus.overWarn) return 'text-amber-600 dark:text-amber-400';
  return 'text-slate-900 dark:text-white';
});

const realtimeChartData = computed(() => {
  const isBytes = rateMode.value === 'bytes';
  const unit = isBytes ? 'MiB/s' : 'Mbps';
  const labels = realtimeSamples.value.map(s =>
    new Date(s.timestamp).toLocaleTimeString('zh-CN', { hour12: false })
  );
  const rx = realtimeSamples.value.map(s =>
    Number((isBytes ? s.rxBytesPerSec / (1024 * 1024) : (s.rxBytesPerSec * 8) / 1_000_000).toFixed(3))
  );
  const tx = realtimeSamples.value.map(s =>
    Number((isBytes ? s.txBytesPerSec / (1024 * 1024) : (s.txBytesPerSec * 8) / 1_000_000).toFixed(3))
  );
  return { labels, rx, tx, unit };
});

const periodChartData = computed(() => {
  const pts = statsResult.points || [];
  let maxVal = 0;
  for (const p of pts) {
    if (p.rxBytes > maxVal) maxVal = p.rxBytes;
    if (p.txBytes > maxVal) maxVal = p.txBytes;
  }
  let divisor = 1024 * 1024;
  let unit = 'MiB';
  if (maxVal >= 1024 * 1024 * 1024 * 1024) {
    divisor = 1024 * 1024 * 1024 * 1024;
    unit = 'TiB';
  } else if (maxVal >= 1024 * 1024 * 1024) {
    divisor = 1024 * 1024 * 1024;
    unit = 'GiB';
  } else if (maxVal > 0 && maxVal < 1024 * 1024) {
    divisor = 1024;
    unit = 'KiB';
  }
  return {
    unit,
    labels: pts.map(p => p.label),
    rx: pts.map(p => Number((p.rxBytes / divisor).toFixed(3))),
    tx: pts.map(p => Number((p.txBytes / divisor).toFixed(3)))
  };
});

function nodeApiBase() {
  if (!activeNodeId.value || activeNodeId.value === 'local') {
    return '/api/v1';
  }
  return `/api/v1/cluster/nodes/${encodeURIComponent(activeNodeId.value)}`;
}

function initPreferences() {
  try {
    const savedTheme = localStorage.getItem('fm_theme');
    if (savedTheme === 'dark' || (!savedTheme && window.matchMedia?.('(prefers-color-scheme: dark)').matches)) {
      isDark.value = true;
    }
    const savedRate = localStorage.getItem('fm_rate_mode');
    if (savedRate === 'bytes' || savedRate === 'bits') {
      rateMode.value = savedRate;
    }
  } catch (_) {}
  document.documentElement.classList.toggle('dark', isDark.value);
}

function toggleTheme() {
  isDark.value = !isDark.value;
  document.documentElement.classList.toggle('dark', isDark.value);
  try {
    localStorage.setItem('fm_theme', isDark.value ? 'dark' : 'light');
  } catch (_) {}
}

function toggleRateUnit() {
  rateMode.value = rateMode.value === 'bits' ? 'bytes' : 'bits';
  try {
    localStorage.setItem('fm_rate_mode', rateMode.value);
  } catch (_) {}
}

function formatLocalDate(d) {
  const yr = d.getFullYear();
  const mo = String(d.getMonth() + 1).padStart(2, '0');
  const da = String(d.getDate()).padStart(2, '0');
  return `${yr}-${mo}-${da}`;
}

function initDefaultRangeDates() {
  const end = new Date();
  const start = new Date();
  start.setDate(end.getDate() - 6);
  rangeForm.start = formatLocalDate(start);
  rangeForm.end = formatLocalDate(end);
}

async function loadBootstrap() {
  const data = await apiRequest('/api/v1/bootstrap');
  Object.assign(boot, data, { loaded: true });
  document.title = boot.siteTitle || 'FlowMaster 流量监控';
  if (!boot.hubModeEnabled) {
    hasChosenInitialView.value = true;
    viewMode.value = 'single';
    activeNodeId.value = 'local';
    return;
  }
  if (!hasChosenInitialView.value) {
    hasChosenInitialView.value = true;
    // 当主控已接入多台子节点时，打开首页默认直接展示“多机总览与对比墙”
    if ((boot.remoteNodeCount || 0) > 0) {
      viewMode.value = 'fleet';
    }
  }
}

async function loadClusterFleet() {
  try {
    const data = await apiRequest('/api/v1/cluster/nodes');
    clusterState.hubVersion = data.hubVersion || '';
    clusterState.latestReleaseVersion = data.latestReleaseVersion || '';
    clusterState.publicHubUrl = data.publicHubUrl || '';
    clusterState.nodes = data.nodes || [];
  } catch (_) {}
}

async function initDashboard() {
  globalError.value = '';
  try {
    await loadBootstrap();
    if (boot.requireLoginForView && !boot.authenticated) {
      closeRealtimeStream();
      return;
    }
    await loadClusterFleet();
    if (viewMode.value === 'single') {
      await loadSingleNodeDashboard();
    } else {
      closeRealtimeStream();
    }
  } catch (err) {
    globalError.value = err.message || '加载监控面板失败';
  }
}

async function switchViewMode(mode) {
  if (mode === 'fleet' && !boot.hubModeEnabled) {
    mode = 'single';
  }
  viewMode.value = mode;
  if (mode === 'fleet') {
    closeRealtimeStream();
    await loadClusterFleet();
  } else {
    await loadSingleNodeDashboard();
  }
}

async function drillIntoNode(nodeId) {
  if (!boot.authenticated && clusterState.nodes.length > 1) {
    showAuthModal.value = true;
    return;
  }
  activeNodeId.value = nodeId || 'local';
  viewMode.value = 'single';
  selectedInterface.value = '';
  realtimeSamples.value = [];
  Object.assign(latestRealtime, { rxBytesPerSec: 0, txBytesPerSec: 0, rxPacketsPerSec: 0, txPacketsPerSec: 0, timestamp: 0 });
  Object.assign(todayPoint, { label: '', rxBytes: 0, txBytes: 0, totalBytes: 0 });
  Object.assign(thisMonthPoint, { label: '', rxBytes: 0, txBytes: 0, totalBytes: 0 });
  Object.assign(quotaStatus, { enabled: false, usedBytes: 0, limitBytes: 0, remainingBytes: 0, usagePercent: 0, projectedBytes: 0, overWarn: false, overLimit: false });
  statsResult.points = [];
  Object.assign(statsResult.summary, { totalRxBytes: 0, totalTxBytes: 0, totalBytes: 0, peakLabel: '', avgBps: 0 });
  await loadSingleNodeDashboard();
}

async function loadSingleNodeDashboard() {
  interfacesLoading.value = true;
  globalError.value = '';
  try {
    const ifData = await apiRequest(`${nodeApiBase()}/interfaces`);
    interfaces.value = ifData.interfaces || [];
    interfacesLoading.value = false;

    if (interfaces.value.length > 0) {
      const stillExists = interfaces.value.some(i => i.name === selectedInterface.value);
      if (!stillExists) {
        selectedInterface.value = interfaces.value[0].name;
      }
      await refreshAllForSelectedInterface();
    } else {
      selectedInterface.value = '';
      closeRealtimeStream();
    }
  } catch (err) {
    interfacesLoading.value = false;
    globalError.value = err.message;
  }
}

async function selectInterface(name) {
  if (selectedInterface.value === name) return;
  selectedInterface.value = name;
  realtimeSamples.value = [];
  Object.assign(latestRealtime, { rxBytesPerSec: 0, txBytesPerSec: 0, rxPacketsPerSec: 0, txPacketsPerSec: 0, timestamp: 0 });
  await refreshAllForSelectedInterface();
}

async function refreshAllForSelectedInterface() {
  if (!selectedInterface.value) return;
  connectRealtimeStream();
  await Promise.allSettled([
    refreshActiveStats(),
    loadTodayAndMonthCards(),
    loadQuotaCard()
  ]);
}

function closeRealtimeStream() {
  if (sseSource) {
    sseSource.close();
    sseSource = null;
  }
  streamConnected.value = false;
}

function connectRealtimeStream() {
  closeRealtimeStream();
  if (viewMode.value !== 'single' || livePaused.value || document.hidden || !selectedInterface.value) return;

  const params = new URLSearchParams({
    interface: selectedInterface.value,
    node: activeNodeId.value || 'local'
  });
  const es = new EventSource(`/api/v1/stream/realtime?${params.toString()}`);
  sseSource = es;

  es.onopen = () => {
    streamConnected.value = true;
  };
  es.onmessage = event => {
    try {
      const msg = JSON.parse(event.data);
      if (msg.type === 'init' && Array.isArray(msg.history)) {
        realtimeSamples.value = msg.history.slice(-60);
        if (realtimeSamples.value.length > 0) {
          Object.assign(latestRealtime, realtimeSamples.value[realtimeSamples.value.length - 1]);
        }
      } else if (msg.type === 'sample' && msg.sample) {
        const next = [...realtimeSamples.value, msg.sample];
        realtimeSamples.value = next.length > 60 ? next.slice(-60) : next;
        Object.assign(latestRealtime, msg.sample);
      }
    } catch (_) {}
  };
  es.onerror = () => {
    streamConnected.value = false;
  };
}

function toggleLivePause() {
  livePaused.value = !livePaused.value;
  if (livePaused.value) closeRealtimeStream();
  else connectRealtimeStream();
}

async function loadTodayAndMonthCards() {
  if (!selectedInterface.value) return;
  const todayStr = formatLocalDate(new Date());
  const ymStr = todayStr.slice(0, 7);

  // 查看远程节点主网卡时，直接复用心跳快照中的今日/本月汇总即时渲染，减少 2 次跨国反向 RPC 并发开销
  const summaryNode = activeNodeSummary.value;
  if (
    activeNodeId.value !== 'local' &&
    summaryNode &&
    summaryNode.primaryInterface === selectedInterface.value
  ) {
    Object.assign(todayPoint, {
      label: todayStr,
      rxBytes: summaryNode.todayRxBytes || 0,
      txBytes: summaryNode.todayTxBytes || 0,
      totalBytes: summaryNode.todayTotalBytes || 0
    });
    Object.assign(thisMonthPoint, {
      label: ymStr,
      rxBytes: summaryNode.monthRxBytes || 0,
      txBytes: summaryNode.monthTxBytes || 0,
      totalBytes: summaryNode.monthTotalBytes || 0
    });
    return;
  }

  const iface = encodeURIComponent(selectedInterface.value);
  const base = nodeApiBase();
  const [dayRes, monthRes] = await Promise.allSettled([
    apiRequest(`${base}/stats/${iface}/d?limit=2`),
    apiRequest(`${base}/stats/${iface}/m?limit=2`)
  ]);

  if (dayRes.status === 'fulfilled') {
    const pts = dayRes.value.points || [];
    const found = pts.find(p => p.label === todayStr) || pts[pts.length - 1];
    Object.assign(todayPoint, found || { label: todayStr, rxBytes: 0, txBytes: 0, totalBytes: 0 });
  }
  if (monthRes.status === 'fulfilled') {
    const pts = monthRes.value.points || [];
    const found = pts.find(p => p.label === ymStr) || pts[pts.length - 1];
    Object.assign(thisMonthPoint, found || { label: ymStr, rxBytes: 0, txBytes: 0, totalBytes: 0 });
  }
}

async function loadQuotaCard() {
  try {
    const endpoint = activeNodeId.value === 'local'
      ? '/api/v1/quota/status'
      : `/api/v1/cluster/nodes/${encodeURIComponent(activeNodeId.value)}/quota`;
    const data = await apiRequest(endpoint);
    Object.assign(quotaStatus, data);
  } catch (_) {}
}

async function switchPeriod(key) {
  activePeriod.value = key;
  if (key === 'range' && (!rangeForm.start || !rangeForm.end)) {
    initDefaultRangeDates();
  }
  await refreshActiveStats();
}

async function refreshActiveStats() {
  if (!selectedInterface.value) return;
  if (activePeriod.value === 'range') {
    return loadRangeStats();
  }
  statsLoading.value = true;
  try {
    const iface = encodeURIComponent(selectedInterface.value);
    const data = await apiRequest(`${nodeApiBase()}/stats/${iface}/${activePeriod.value}`);
    statsResult.source = data.source || '';
    statsResult.points = data.points || [];
    Object.assign(statsResult.summary, data.summary || {});
  } catch (err) {
    globalError.value = err.message;
  } finally {
    statsLoading.value = false;
  }
}

async function loadRangeStats() {
  if (!selectedInterface.value || !rangeForm.start || !rangeForm.end) return;
  statsLoading.value = true;
  try {
    const iface = encodeURIComponent(selectedInterface.value);
    const data = await apiRequest(`${nodeApiBase()}/stats/${iface}/range/${rangeForm.start}/${rangeForm.end}`);
    statsResult.source = data.source || '';
    statsResult.points = data.points || [];
    Object.assign(statsResult.summary, data.summary || {});
  } catch (err) {
    globalError.value = err.message;
  } finally {
    statsLoading.value = false;
  }
}

function applyQuickRange(days) {
  const end = new Date();
  const start = new Date();
  start.setDate(end.getDate() - (days - 1));
  rangeForm.start = formatLocalDate(start);
  rangeForm.end = formatLocalDate(end);
  loadRangeStats();
}

function applyThisMonthRange() {
  const now = new Date();
  const start = new Date(now.getFullYear(), now.getMonth(), 1);
  rangeForm.start = formatLocalDate(start);
  rangeForm.end = formatLocalDate(now);
  loadRangeStats();
}

function openAdmin() {
  if (boot.authenticated) {
    showAdminConsole.value = true;
  } else {
    showAuthModal.value = true;
  }
}

function openActiveRemoteConfig() {
  if (!boot.authenticated) {
    showAuthModal.value = true;
    return;
  }
  if (activeNodeSummary.value && !activeNodeSummary.value.isLocal) {
    editingRemoteNode.value = activeNodeSummary.value;
  }
}

async function onRemoteConfigUpdated() {
  await loadClusterFleet();
  if (viewMode.value === 'single') {
    await loadSingleNodeDashboard();
  }
}

async function onRemoteNodeDeleted() {
  editingRemoteNode.value = null;
  activeNodeId.value = 'local';
  viewMode.value = 'fleet';
  await loadClusterFleet();
}

async function onAuthSuccess() {
  await initDashboard();
}

async function onAuthModalSuccess() {
  showAuthModal.value = false;
  await loadBootstrap();
  await loadClusterFleet();
}

async function onAdminUpdated() {
  await initDashboard();
}

async function onAdminLoggedOut() {
  showAdminConsole.value = false;
  if (clusterState.nodes.length > 1) {
    activeNodeId.value = 'local';
    viewMode.value = 'fleet';
    closeRealtimeStream();
  }
  await initDashboard();
}

function handleVisibilityChange() {
  if (document.hidden) {
    closeRealtimeStream();
  } else if (!boot.requireLoginForView || boot.authenticated) {
    loadClusterFleet();
    if (viewMode.value === 'single' && !livePaused.value && selectedInterface.value) {
      connectRealtimeStream();
      loadTodayAndMonthCards();
      loadQuotaCard();
    }
  }
}

onMounted(async () => {
  initPreferences();
  initDefaultRangeDates();
  document.addEventListener('visibilitychange', handleVisibilityChange);
  await initDashboard();

  // 多机视图每 3 秒自动刷新各节点在线状态与实时带宽汇总
  fleetPollTimer = window.setInterval(() => {
    if (!document.hidden && (!boot.requireLoginForView || boot.authenticated)) {
      if (viewMode.value === 'fleet' || clusterState.nodes.length > 1) {
        loadClusterFleet();
      }
    }
  }, 3000);

  summaryRefreshTimer = window.setInterval(() => {
    if (!document.hidden && viewMode.value === 'single' && selectedInterface.value && (!boot.requireLoginForView || boot.authenticated)) {
      loadTodayAndMonthCards();
      loadQuotaCard();
      if (activePeriod.value === '5') {
        refreshActiveStats();
      }
    }
  }, 30000);
});

onBeforeUnmount(() => {
  closeRealtimeStream();
  if (fleetPollTimer) window.clearInterval(fleetPollTimer);
  if (summaryRefreshTimer) window.clearInterval(summaryRefreshTimer);
  document.removeEventListener('visibilitychange', handleVisibilityChange);
});
</script>
