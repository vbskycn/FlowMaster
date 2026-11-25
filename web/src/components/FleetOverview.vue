<template>
  <div class="space-y-5">
    <!-- 全集群汇总 4 宫格卡片 -->
    <section class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
      <div class="p-4 rounded-2xl bg-white dark:bg-slate-900 border border-slate-200/80 dark:border-slate-800 shadow-2xs">
        <div class="flex items-center justify-between text-xs text-slate-500 dark:text-slate-400">
          <span>服务器在线状态</span>
          <span class="px-2 py-0.5 rounded-full text-[11px] font-num bg-emerald-50 text-emerald-700 dark:bg-emerald-950 dark:text-emerald-300">
            在线率 {{ nodes.length ? Math.round((onlineCount / nodes.length) * 100) : 100 }}%
          </span>
        </div>
        <div class="mt-2 flex items-baseline gap-2">
          <span class="text-2xl font-bold font-num text-slate-900 dark:text-white">{{ onlineCount }}</span>
          <span class="text-xs text-slate-500 font-num">/ {{ nodes.length }} 台在线</span>
        </div>
        <div class="mt-1.5 text-[11px] text-slate-400 font-num">
          最新版本 v{{ latestVersion || hubVersion }} · 待升级 {{ outdatedCount }} 台
        </div>
      </div>

      <div class="p-4 rounded-2xl bg-white dark:bg-slate-900 border border-slate-200/80 dark:border-slate-800 shadow-2xs">
        <div class="text-xs text-slate-500 dark:text-slate-400">全集群实时总吞吐</div>
        <div class="mt-2 text-lg font-bold font-num">
          <span class="text-blue-600 dark:text-blue-400">↓ {{ formatRate(fleetSummary.rxBps, rateMode) }}</span>
        </div>
        <div class="mt-1 text-xs font-semibold font-num text-emerald-600 dark:text-emerald-400">
          ↑ {{ formatRate(fleetSummary.txBps, rateMode) }}
        </div>
      </div>

      <div class="p-4 rounded-2xl bg-white dark:bg-slate-900 border border-slate-200/80 dark:border-slate-800 shadow-2xs">
        <div class="text-xs text-slate-500 dark:text-slate-400">所有机器今日累计流量</div>
        <div class="mt-2 text-2xl font-bold font-num text-slate-900 dark:text-white">
          {{ formatBytes(fleetSummary.todayTotal) }}
        </div>
        <div class="mt-1.5 flex items-center justify-between text-[11px] text-slate-500 font-num">
          <span>↓ {{ formatBytes(fleetSummary.todayRx) }}</span>
          <span>↑ {{ formatBytes(fleetSummary.todayTx) }}</span>
        </div>
      </div>

      <div class="p-4 rounded-2xl bg-white dark:bg-slate-900 border border-slate-200/80 dark:border-slate-800 shadow-2xs">
        <div class="flex items-center justify-between text-xs text-slate-500 dark:text-slate-400">
          <span>所有机器本月累计流量</span>
          <span v-if="fleetSummary.warnCount > 0" class="px-1.5 py-0.5 rounded bg-amber-50 text-amber-700 dark:bg-amber-950 dark:text-amber-300 font-num">
            {{ fleetSummary.warnCount }} 台告警
          </span>
        </div>
        <div class="mt-2 text-2xl font-bold font-num text-slate-900 dark:text-white">
          {{ formatBytes(fleetSummary.monthTotal) }}
        </div>
        <div class="mt-1.5 flex items-center justify-between text-[11px] text-slate-500 font-num">
          <span>↓ {{ formatBytes(fleetSummary.monthRx) }}</span>
          <span>↑ {{ formatBytes(fleetSummary.monthTx) }}</span>
        </div>
      </div>
    </section>

    <!-- 多机横向对比图表卡片 -->
    <section v-if="filteredNodes.length > 0" class="p-5 rounded-2xl bg-white dark:bg-slate-900 border border-slate-200/80 dark:border-slate-800 shadow-2xs space-y-3">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <div>
          <h2 class="text-sm sm:text-base font-bold text-slate-900 dark:text-white">多机横向流量对比排行 (Top {{ compareChart.labels.length }})</h2>
          <p class="text-xs text-slate-500 dark:text-slate-400">直观对比各台机器的带宽与周期流量消耗，快速定位高负载节点</p>
        </div>
        <div class="inline-flex flex-wrap gap-1 p-1 rounded-xl bg-slate-100 dark:bg-slate-950 border border-slate-200/60 dark:border-slate-800 text-xs">
          <button
            v-for="m in compareMetrics"
            :key="m.key"
            type="button"
            class="px-3 py-1 rounded-lg font-medium cursor-pointer transition-all"
            :class="compareMode === m.key
              ? 'bg-white dark:bg-slate-800 text-blue-600 dark:text-blue-400 shadow-2xs'
              : 'text-slate-600 dark:text-slate-400'"
            @click="compareMode = m.key"
          >
            {{ m.label }}
          </button>
        </div>
      </div>

      <TrafficChart
        type="bar"
        :labels="compareChart.labels"
        :rx-data="compareChart.rx"
        :tx-data="compareChart.tx"
        :rx-label="compareChart.rxLabel"
        :tx-label="compareChart.txLabel"
        :unit="compareChart.unit"
        :dark="dark"
        :height="230"
      />
    </section>

    <!-- 工具栏：搜索、分组过滤、排序、视图切换 + 添加节点 / 批量远程升级 -->
    <section class="p-4 rounded-2xl bg-white dark:bg-slate-900 border border-slate-200/80 dark:border-slate-800 shadow-2xs space-y-3">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div class="flex flex-wrap items-center gap-2">
          <input
            v-model.trim="searchQuery"
            type="text"
            :placeholder="authenticated ? '搜索机器名称、IPv4/IPv6、分组或备注...' : '搜索机器名称、分组或备注...'"
            class="w-60 px-3 py-1.5 text-xs rounded-xl border border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-950 focus:outline-none focus:ring-2 focus:ring-blue-500/40"
          />

          <select
            v-model="selectedGroup"
            class="px-2.5 py-1.5 text-xs rounded-xl border border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-950"
          >
            <option value="__all__">全部分组 ({{ nodes.length }})</option>
            <option v-for="g in groupOptions" :key="g.name" :value="g.name">{{ g.name }} ({{ g.count }})</option>
            <option v-if="ungroupedCount > 0" value="__ungrouped__">未分组 ({{ ungroupedCount }})</option>
          </select>

          <select
            v-model="sortBy"
            class="px-2.5 py-1.5 text-xs rounded-xl border border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-950"
          >
            <option value="month">按本月总流量排序</option>
            <option value="today">按今日总流量排序</option>
            <option value="speed">按当前实时网速排序</option>
            <option value="quota">按月度配额使用率排序</option>
            <option value="cpu">按 CPU 使用率排序</option>
            <option value="mem">按内存使用率排序</option>
            <option value="name">按机器名称排序</option>
          </select>
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <div class="inline-flex rounded-xl border border-slate-200 dark:border-slate-700 overflow-hidden text-xs">
            <button
              type="button"
              class="px-3 py-1.5 cursor-pointer"
              :class="displayMode === 'grid' ? 'bg-slate-900 text-white dark:bg-slate-100 dark:text-slate-900' : 'text-slate-600 dark:text-slate-300'"
              @click="displayMode = 'grid'"
            >
              卡片墙
            </button>
            <button
              type="button"
              class="px-3 py-1.5 cursor-pointer"
              :class="displayMode === 'table' ? 'bg-slate-900 text-white dark:bg-slate-100 dark:text-slate-900' : 'text-slate-600 dark:text-slate-300'"
              @click="displayMode = 'table'"
            >
              对比表格
            </button>
          </div>

          <button
            v-if="authenticated"
            type="button"
            class="px-3.5 py-1.5 rounded-xl text-xs font-medium bg-blue-600 hover:bg-blue-700 text-white cursor-pointer"
            @click="handleOpenAddModal"
          >
            + 添加服务器节点
          </button>

          <button
            v-if="authenticated"
            type="button"
            class="px-3.5 py-1.5 rounded-xl text-xs font-medium border border-indigo-200 dark:border-indigo-800 bg-indigo-50 dark:bg-indigo-950/60 text-indigo-700 dark:text-indigo-300 hover:opacity-90 cursor-pointer"
            @click="handleOpenUpgradeModal"
          >
            🚀 统一远程升级
          </button>
        </div>
      </div>

      <!-- 管理员批量操作栏（勾选任意节点后自动展开，所有高危操作强制二次确认） -->
      <div
        v-if="authenticated && selectedNodeIds.length > 0"
        class="p-3 rounded-xl bg-blue-50/80 dark:bg-blue-950/40 border border-blue-200 dark:border-blue-800/80 flex flex-wrap items-center justify-between gap-2 text-xs"
      >
        <div class="flex flex-wrap items-center gap-2">
          <span class="font-semibold text-blue-800 dark:text-blue-200">
            已勾选 <strong class="font-num">{{ selectedNodeIds.length }}</strong> 台机器
          </span>
          <button type="button" class="underline text-blue-600 dark:text-blue-400 cursor-pointer" @click="selectAllFilteredNodes">全选当前 ({{ filteredNodes.length }})</button>
          <button type="button" class="underline text-slate-500 cursor-pointer" @click="selectedNodeIds = []">清空</button>
        </div>
        <div class="flex flex-wrap items-center gap-1.5">
          <button type="button" :disabled="batchBusy" class="px-2.5 py-1 rounded-lg bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-700 hover:border-blue-400 cursor-pointer" @click="runBatchGroup">
            批量改分组
          </button>
          <button type="button" :disabled="batchBusy" class="px-2.5 py-1 rounded-lg bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-700 hover:border-blue-400 cursor-pointer" @click="showBatchQuotaModal = true">
            批量下发配额
          </button>
          <button type="button" :disabled="batchBusy" class="px-2.5 py-1 rounded-lg bg-amber-50 dark:bg-amber-950/60 border border-amber-200 dark:border-amber-800 text-amber-700 dark:text-amber-300 cursor-pointer" @click="runBatchRestart">
            🔄 批量平滑重启
          </button>
          <button type="button" :disabled="batchBusy" class="px-2.5 py-1 rounded-lg bg-indigo-600 text-white cursor-pointer" @click="openUpgradeForSelected">
            🚀 升级选中
          </button>
          <button type="button" :disabled="batchBusy" class="px-2.5 py-1 rounded-lg bg-red-50 dark:bg-red-950/60 border border-red-200 dark:border-red-900 text-red-600 dark:text-red-400 cursor-pointer" @click="runBatchDelete">
            批量删除
          </button>
        </div>
      </div>
      <div v-if="batchNotice" class="px-3 py-2 rounded-xl bg-slate-100 dark:bg-slate-800/70 text-xs text-slate-700 dark:text-slate-200 flex items-center justify-between">
        <span>{{ batchNotice }}</span>
        <button type="button" class="underline text-slate-500 ml-2 cursor-pointer" @click="batchNotice = ''">关闭</button>
      </div>

      <!-- 视图一：响应式多机卡片墙 -->
      <div v-if="displayMode === 'grid'" class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-4 pt-1">
        <article
          v-for="node in filteredNodes"
          :key="node.id"
          class="group p-4 rounded-2xl border transition-all flex flex-col justify-between bg-slate-50/40 dark:bg-slate-950/40 hover:border-blue-400 dark:hover:border-blue-600"
          :class="node.online ? 'border-slate-200/90 dark:border-slate-800' : 'border-red-200/80 dark:border-red-900/50 opacity-80'"
        >
          <div>
            <!-- 顶行：在线状态 + 名称 + 分组 + 版本号 -->
            <div class="flex items-start justify-between gap-2">
              <div class="min-w-0">
                <div class="flex items-center gap-2">
                  <input
                    v-if="authenticated"
                    v-model="selectedNodeIds"
                    type="checkbox"
                    :value="node.id"
                    class="accent-blue-600 w-3.5 h-3.5 shrink-0 cursor-pointer"
                    title="勾选以进行批量操作"
                  />
                  <span class="w-2.5 h-2.5 rounded-full shrink-0" :class="node.online ? 'bg-emerald-500' : 'bg-red-500'"></span>
                  <h3
                    class="text-sm font-bold text-slate-900 dark:text-white truncate"
                    :class="authenticated ? 'cursor-pointer hover:text-blue-600 dark:hover:text-blue-400' : ''"
                    @click="authenticated && $emit('select-node', node.id)"
                  >
                    {{ node.name }}
                  </h3>
                  <span v-if="node.groupName" class="px-1.5 py-0.5 rounded text-[10px] bg-slate-200/70 dark:bg-slate-800 text-slate-600 dark:text-slate-300 shrink-0">
                    {{ node.groupName }}
                  </span>
                </div>
                <div v-if="authenticated && (primaryIPv4(node) || primaryIPv6(node))" class="mt-1 flex flex-wrap items-center gap-x-2 gap-y-0.5 text-[11px] text-slate-500 font-num">
                  <span v-if="primaryIPv4(node)" :title="ipv4Tooltip(node)">IPv4: {{ primaryIPv4(node) }}</span>
                  <span v-if="primaryIPv6(node)" class="truncate max-w-44" :title="primaryIPv6(node)">IPv6: {{ primaryIPv6(node) }}</span>
                </div>
              </div>

              <div class="flex flex-col items-end shrink-0 gap-1">
                <span class="font-num text-[11px] px-2 py-0.5 rounded-full border"
                  :class="node.upgradeOutdated
                    ? 'bg-amber-50 text-amber-700 border-amber-200 dark:bg-amber-950 dark:text-amber-300 dark:border-amber-800'
                    : 'bg-slate-100 text-slate-600 border-slate-200 dark:bg-slate-800 dark:text-slate-300 dark:border-slate-700'">
                  {{ node.version ? `v${node.version}` : '待连接' }}
                </span>
                <span v-if="node.upgradeState === 'upgrading' || node.upgradeState === 'restarting'" class="text-[10px] text-indigo-600 dark:text-indigo-400 animate-pulse">
                  {{ node.upgradeMessage || '升级中…' }}
                </span>
              </div>
            </div>

            <!-- 实时上下行网速与今日/本月汇总 -->
            <div class="mt-3.5 grid grid-cols-2 gap-2.5 p-2.5 rounded-xl bg-white dark:bg-slate-900 border border-slate-200/60 dark:border-slate-800/80 text-xs font-num">
              <div>
                <div class="text-[11px] text-slate-400 font-sans">实时速率</div>
                <div class="text-blue-600 dark:text-blue-400 font-semibold mt-0.5">↓ {{ formatRate(node.rxBytesPerSec, rateMode) }}</div>
                <div class="text-emerald-600 dark:text-emerald-400 font-semibold">↑ {{ formatRate(node.txBytesPerSec, rateMode) }}</div>
              </div>
              <div>
                <div class="text-[11px] text-slate-400 font-sans">今日 / 本月累计</div>
                <div class="text-slate-800 dark:text-slate-200 font-semibold mt-0.5">日: {{ formatBytes(node.todayTotalBytes) }}</div>
                <div class="text-slate-800 dark:text-slate-200 font-semibold">月: {{ formatBytes(node.monthTotalBytes) }}</div>
              </div>
            </div>

            <!-- CPU / 内存 / 硬盘 实时资源占用条 -->
            <div
              v-if="hasHostMetrics(node)"
              class="mt-2.5 grid grid-cols-3 gap-2 px-2.5 py-2 rounded-xl bg-white/80 dark:bg-slate-900/80 border border-slate-200/60 dark:border-slate-800/80 text-[11px] font-num"
            >
              <div :title="`CPU 占用 ${(node.host.cpuPercent || 0).toFixed(1)}% (${node.host.cpuCores || 0} 核)`">
                <div class="flex items-center justify-between text-slate-500">
                  <span class="font-sans">CPU</span>
                  <span class="font-semibold text-slate-700 dark:text-slate-200">{{ (node.host.cpuPercent || 0).toFixed(0) }}%</span>
                </div>
                <div class="mt-1 h-1.5 w-full rounded-full bg-slate-200 dark:bg-slate-800 overflow-hidden">
                  <div class="h-full rounded-full transition-all" :class="meterBarClass(node.host.cpuPercent)" :style="{ width: Math.min(100, node.host.cpuPercent || 0) + '%' }"></div>
                </div>
              </div>
              <div :title="`内存: ${formatBytes(node.host.memUsedBytes)} / ${formatBytes(node.host.memTotalBytes)}`">
                <div class="flex items-center justify-between text-slate-500">
                  <span class="font-sans">内存</span>
                  <span class="font-semibold text-slate-700 dark:text-slate-200">{{ (node.host.memPercent || 0).toFixed(0) }}%</span>
                </div>
                <div class="mt-1 h-1.5 w-full rounded-full bg-slate-200 dark:bg-slate-800 overflow-hidden">
                  <div class="h-full rounded-full transition-all" :class="meterBarClass(node.host.memPercent)" :style="{ width: Math.min(100, node.host.memPercent || 0) + '%' }"></div>
                </div>
              </div>
              <div :title="`硬盘 (/): ${formatBytes(node.host.diskUsedBytes)} / ${formatBytes(node.host.diskTotalBytes)}`">
                <div class="flex items-center justify-between text-slate-500">
                  <span class="font-sans">硬盘</span>
                  <span class="font-semibold text-slate-700 dark:text-slate-200">{{ (node.host.diskPercent || 0).toFixed(0) }}%</span>
                </div>
                <div class="mt-1 h-1.5 w-full rounded-full bg-slate-200 dark:bg-slate-800 overflow-hidden">
                  <div class="h-full rounded-full transition-all" :class="meterBarClass(node.host.diskPercent)" :style="{ width: Math.min(100, node.host.diskPercent || 0) + '%' }"></div>
                </div>
              </div>
            </div>

            <!-- 月度配额进度条（若该机器启用了配额） -->
            <div v-if="node.quota?.enabled && node.quota?.limitBytes > 0" class="mt-2.5 space-y-1">
              <div class="flex items-center justify-between text-[11px] font-num">
                <span class="text-slate-500">月度流量包 ({{ node.quota.usagePercent.toFixed(1) }}%)</span>
                <span class="text-slate-600 dark:text-slate-300">
                  {{ formatBytes(node.quota.usedBytes) }} / {{ formatBytes(node.quota.limitBytes) }}
                </span>
              </div>
              <div class="w-full h-1.5 rounded-full bg-slate-200 dark:bg-slate-800 overflow-hidden">
                <div
                  class="h-full rounded-full"
                  :class="node.quota.overLimit ? 'bg-red-500' : (node.quota.overWarn ? 'bg-amber-500' : 'bg-blue-600')"
                  :style="{ width: Math.min(100, node.quota.usagePercent) + '%' }"
                ></div>
              </div>
            </div>
          </div>

          <!-- 底栏：点击查看单机详情 / 独立面板跳转 / 远程配置 -->
          <div class="mt-3.5 pt-2.5 border-t border-slate-200/60 dark:border-slate-800 flex items-center justify-between text-xs">
            <span class="text-[11px] text-slate-400 truncate max-w-44" :title="node.remark">
              {{ node.remark || (node.online ? `运行 ${formatUptime(node.uptimeSeconds)}` : '等待节点连接上报') }}
            </span>
            <div v-if="authenticated" class="flex items-center gap-2 shrink-0">
              <a
                v-if="!node.isLocal && directPanelUrl(node)"
                :href="directPanelUrl(node)"
                target="_blank"
                rel="noopener noreferrer"
                class="px-2 py-1 rounded-lg text-slate-500 hover:text-blue-600 hover:bg-slate-100 dark:hover:bg-slate-800"
                title="在新标签页打开该机器自身的独立 10089 面板"
              >
                独立面板 ↗
              </a>
              <button
                v-if="!node.isLocal"
                type="button"
                class="px-2 py-1 rounded-lg text-slate-600 dark:text-slate-300 hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer"
                @click="openNodeConfig(node)"
              >
                配置
              </button>
              <button
                v-if="!node.isLocal"
                type="button"
                class="px-2 py-1 rounded-lg text-red-600 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-950/50 cursor-pointer"
                title="从主控删除该节点"
                @click="confirmDeleteNode(node)"
              >
                删除
              </button>
              <button
                type="button"
                class="px-3 py-1 rounded-lg font-medium bg-blue-600 hover:bg-blue-700 text-white cursor-pointer"
                @click="$emit('select-node', node.id)"
              >
                查看详情 →
              </button>
            </div>
          </div>
        </article>
      </div>

      <!-- 视图二：带序号列与 20/50/100 分页的多机紧凑对比表 -->
      <div v-else class="space-y-3 pt-1">
        <div class="overflow-x-auto rounded-xl border border-slate-200 dark:border-slate-800">
          <table class="w-full text-xs text-left border-collapse">
            <thead class="bg-slate-100/80 dark:bg-slate-900/80 text-slate-500 dark:text-slate-400">
              <tr>
                <th v-if="authenticated" class="py-2.5 px-2.5 w-9 text-center">
                  <input
                    type="checkbox"
                    class="accent-blue-600 cursor-pointer"
                    :checked="filteredNodes.length > 0 && selectedNodeIds.length === filteredNodes.length"
                    @change="toggleSelectAllFiltered($event.target.checked)"
                  />
                </th>
                <th class="py-2.5 px-3 w-12 text-center">#</th>
                <th class="py-2.5 px-3">节点名称 / 分组</th>
                <th v-if="authenticated" class="py-2.5 px-3">IPv4 / IPv6</th>
                <th class="py-2.5 px-3">CPU / 内存 / 硬盘</th>
                <th class="py-2.5 px-3 text-right">实时下行 / 上行</th>
                <th class="py-2.5 px-3 text-right">今日流量</th>
                <th class="py-2.5 px-3 text-right">本月流量</th>
                <th class="py-2.5 px-3">月度配额进度</th>
                <th class="py-2.5 px-3">版本</th>
                <th v-if="authenticated" class="py-2.5 px-3 text-right">操作</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-slate-200/70 dark:divide-slate-800">
              <tr v-for="(node, idx) in pagedTableNodes" :key="node.id" class="hover:bg-blue-50/30 dark:hover:bg-slate-800/40">
                <td v-if="authenticated" class="py-2.5 px-2.5 text-center">
                  <input v-model="selectedNodeIds" type="checkbox" :value="node.id" class="accent-blue-600 cursor-pointer" />
                </td>
                <td class="py-2.5 px-3 text-center font-num text-slate-400">{{ (tablePage - 1) * tablePageSize + idx + 1 }}</td>
                <td class="py-2.5 px-3">
                  <div class="flex items-center gap-1.5">
                    <span class="w-2 h-2 rounded-full" :class="node.online ? 'bg-emerald-500' : 'bg-red-500'"></span>
                    <button
                      v-if="authenticated"
                      type="button"
                      class="font-bold text-slate-900 dark:text-white hover:text-blue-600 cursor-pointer"
                      @click="$emit('select-node', node.id)"
                    >
                      {{ node.name }}
                    </button>
                    <span v-else class="font-bold text-slate-900 dark:text-white">{{ node.name }}</span>
                  </div>
                  <div v-if="node.groupName" class="text-[11px] text-slate-400 mt-0.5">{{ node.groupName }}</div>
                </td>
                <td v-if="authenticated" class="py-2.5 px-3 font-num text-[11px] text-slate-500">
                  <div v-if="primaryIPv4(node)" :title="ipv4Tooltip(node)">{{ primaryIPv4(node) }}</div>
                  <div v-if="primaryIPv6(node)" class="truncate max-w-40" :title="primaryIPv6(node)">{{ primaryIPv6(node) }}</div>
                </td>
                <td class="py-2.5 px-3 font-num text-[11px] whitespace-nowrap">
                  <template v-if="hasHostMetrics(node)">
                    <div class="flex items-center gap-1.5">
                      <span :title="`${node.host.cpuCores || 0} 核`" :class="meterTextClass(node.host.cpuPercent)">CPU {{ (node.host.cpuPercent || 0).toFixed(0) }}%</span>
                      <span class="text-slate-300 dark:text-slate-700">|</span>
                      <span :title="`${formatBytes(node.host.memUsedBytes)} / ${formatBytes(node.host.memTotalBytes)}`" :class="meterTextClass(node.host.memPercent)">内 {{ (node.host.memPercent || 0).toFixed(0) }}%</span>
                      <span class="text-slate-300 dark:text-slate-700">|</span>
                      <span :title="`${formatBytes(node.host.diskUsedBytes)} / ${formatBytes(node.host.diskTotalBytes)}`" :class="meterTextClass(node.host.diskPercent)">盘 {{ (node.host.diskPercent || 0).toFixed(0) }}%</span>
                    </div>
                  </template>
                  <span v-else class="text-slate-400">—</span>
                </td>
                <td class="py-2.5 px-3 text-right font-num whitespace-nowrap">
                  <div class="text-blue-600 dark:text-blue-400">↓ {{ formatRate(node.rxBytesPerSec, rateMode) }}</div>
                  <div class="text-emerald-600 dark:text-emerald-400">↑ {{ formatRate(node.txBytesPerSec, rateMode) }}</div>
                </td>
                <td class="py-2.5 px-3 text-right font-num font-medium whitespace-nowrap">{{ formatBytes(node.todayTotalBytes) }}</td>
                <td class="py-2.5 px-3 text-right font-num font-bold whitespace-nowrap">{{ formatBytes(node.monthTotalBytes) }}</td>
                <td class="py-2.5 px-3 font-num">
                  <template v-if="node.quota?.enabled && node.quota?.limitBytes > 0">
                    <div>{{ node.quota.usagePercent.toFixed(1) }}% ({{ formatBytes(node.quota.usedBytes) }})</div>
                  </template>
                  <span v-else class="text-slate-400">未设限额</span>
                </td>
                <td class="py-2.5 px-3 font-num">
                  <span :class="node.upgradeOutdated ? 'text-amber-600 font-semibold' : 'text-slate-500'">
                    {{ node.version ? `v${node.version}` : '—' }}
                  </span>
                </td>
                <td v-if="authenticated" class="py-2.5 px-3 text-right space-x-1.5 whitespace-nowrap">
                  <a
                    v-if="!node.isLocal && directPanelUrl(node)"
                    :href="directPanelUrl(node)"
                    target="_blank"
                    rel="noopener noreferrer"
                    class="inline-block px-2 py-1 rounded border border-slate-200 dark:border-slate-700 text-slate-600 dark:text-slate-300 hover:text-blue-600"
                    title="在新标签页打开该机器独立面板"
                  >
                    面板 ↗
                  </a>
                  <button v-if="!node.isLocal" type="button" class="px-2 py-1 rounded border border-slate-200 dark:border-slate-700 cursor-pointer" @click="openNodeConfig(node)">
                    配置
                  </button>
                  <button v-if="!node.isLocal" type="button" class="px-2 py-1 rounded border border-red-200 dark:border-red-900/70 text-red-600 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-950/40 cursor-pointer" @click="confirmDeleteNode(node)">
                    删除
                  </button>
                  <button type="button" class="px-2.5 py-1 rounded bg-blue-600 text-white cursor-pointer" @click="$emit('select-node', node.id)">
                    查看详情
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div class="flex flex-wrap items-center justify-between gap-2 text-xs text-slate-500">
          <div class="flex items-center gap-2">
            <span>共 <strong class="font-num">{{ filteredNodes.length }}</strong> 台机器</span>
            <select v-model.number="tablePageSize" class="px-2 py-1 rounded border border-slate-200 dark:border-slate-800 bg-white dark:bg-slate-900 font-num">
              <option :value="20">20 条/页</option>
              <option :value="50">50 条/页</option>
              <option :value="100">100 条/页</option>
            </select>
          </div>
          <div v-if="tableTotalPages > 1" class="flex items-center gap-1 font-num">
            <button type="button" class="px-2.5 py-1 rounded border border-slate-200 dark:border-slate-800 disabled:opacity-40" :disabled="tablePage <= 1" @click="tablePage--">上一页</button>
            <span class="px-2">{{ tablePage }} / {{ tableTotalPages }}</span>
            <button type="button" class="px-2.5 py-1 rounded border border-slate-200 dark:border-slate-800 disabled:opacity-40" :disabled="tablePage >= tableTotalPages" @click="tablePage++">下一页</button>
          </div>
        </div>
      </div>
    </section>

    <!-- 弹窗一：添加新被控服务器并生成一键接入命令 -->
    <div v-if="showAddModal" class="fixed inset-0 z-50 flex items-center justify-center p-4 bg-slate-950/60 backdrop-blur-xs">
      <div class="w-full max-w-xl rounded-2xl bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-800 shadow-2xl p-6 space-y-4">
        <div class="flex items-center justify-between">
          <h3 class="text-base font-bold text-slate-900 dark:text-white">添加被控服务器节点</h3>
          <button type="button" class="text-xs text-slate-400 hover:text-slate-600 cursor-pointer" @click="showAddModal = false">关闭</button>
        </div>

        <div v-if="addError" class="p-3 rounded-lg bg-red-50 dark:bg-red-950/50 text-xs text-red-600 dark:text-red-300">
          {{ addError }}
        </div>

        <template v-if="!createdJoinResult">
          <div class="space-y-3 text-xs">
            <div>
              <label class="block text-slate-600 dark:text-slate-300 mb-1">主控公网接入地址（供各台被控机主动连接，支持直连域名、IPv4 或 `[IPv6]:端口`）</label>
              <input v-model.trim="addForm.hubUrl" type="url" required placeholder="https://hub-direct.example.com 或 http://主控IP:10089" class="w-full px-3 py-2 font-num rounded-xl border border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-950" />
            </div>

            <label class="flex items-start gap-2.5 p-3 rounded-xl border cursor-pointer transition-colors"
              :class="addForm.useHubMirror
                ? 'border-blue-300 dark:border-blue-800 bg-blue-50/60 dark:bg-blue-950/30'
                : 'border-slate-200 dark:border-slate-800 bg-slate-50/50 dark:bg-slate-950/50'">
              <input v-model="addForm.useHubMirror" type="checkbox" class="mt-0.5 accent-blue-600 w-4 h-4 shrink-0" />
              <div class="space-y-0.5">
                <div class="font-semibold text-slate-800 dark:text-slate-100">
                  由本主控机直接分发安装脚本与二进制包（默认推荐）
                </div>
                <p class="text-[11px] text-slate-500 dark:text-slate-400 leading-relaxed">
                  国内服务器无需访问 GitHub 或依赖第三方公共代理即可秒速拉取安装与后续升级；取消勾选则改从 GitHub 官方或代理加速地址拉取。
                </p>
              </div>
            </label>

            <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <div>
                <label class="block text-slate-600 dark:text-slate-300 mb-1">服务器显示名称（可选，留空自动取主机名）</label>
                <input v-model.trim="addForm.name" type="text" placeholder="例如：美国甲骨文 ARM-1" class="w-full px-3 py-2 rounded-xl border border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-950" />
              </div>
              <div>
                <label class="block text-slate-600 dark:text-slate-300 mb-1">分组标签（可选）</label>
                <input v-model.trim="addForm.groupName" type="text" placeholder="例如：美国 / 香港 / 国内" class="w-full px-3 py-2 rounded-xl border border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-950" />
              </div>
            </div>
            <div>
              <label class="block text-slate-600 dark:text-slate-300 mb-1">备注说明（可选）</label>
              <input v-model.trim="addForm.remark" type="text" placeholder="例如：月流量 10TB / 账单日 1 号" class="w-full px-3 py-2 rounded-xl border border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-950" />
            </div>
          </div>

          <button
            type="button"
            :disabled="creatingNode"
            class="w-full py-2.5 rounded-xl bg-blue-600 hover:bg-blue-700 text-white text-sm font-medium cursor-pointer"
            @click="submitCreateNode"
          >
            {{ creatingNode ? '正在生成专属密钥…' : '生成一键安装接入命令' }}
          </button>
        </template>

        <template v-else>
          <div class="p-3.5 rounded-xl bg-emerald-50 dark:bg-emerald-950/40 border border-emerald-200 dark:border-emerald-900 text-xs text-emerald-800 dark:text-emerald-300">
            ✅ 节点记录已创建！复制下方命令到目标服务器执行，脚本将**{{ resultUseHubMirror ? '直接从本主控机拉取安装包（免连 GitHub）' : '自动从 GitHub 或加速代理拉取安装包' }}、开启本地 10089 面板并放行防火墙、自动连接本主控上线**。
          </div>

          <label class="inline-flex items-center gap-2 text-xs font-medium text-slate-700 dark:text-slate-200 cursor-pointer">
            <input v-model="resultUseHubMirror" type="checkbox" class="accent-blue-600 w-4 h-4" />
            <span>使用主控机直接分发文件（取消勾选则切换为 GitHub / 代理加速地址分发）</span>
          </label>

          <div class="space-y-2">
            <div class="flex items-center justify-between text-xs">
              <span class="font-semibold text-slate-700 dark:text-slate-200">默认推荐命令（开放本机 10089 面板 + 自动放行防火墙 + 上报主控）</span>
              <button type="button" class="text-blue-600 hover:underline cursor-pointer" @click="copyCommand(displayedJoinCommand)">
                {{ copiedHint || '一键复制命令' }}
              </button>
            </div>
            <pre class="p-3 rounded-xl bg-slate-950 text-slate-100 font-num text-[11px] whitespace-pre-wrap break-all">{{ displayedJoinCommand }}</pre>
          </div>

          <details class="text-xs">
            <summary class="text-slate-500 cursor-pointer">可选：不开放被控机 10089 端口的纯探针命令 (--no-web)</summary>
            <div class="mt-2 space-y-1.5">
              <button type="button" class="text-blue-600 hover:underline cursor-pointer" @click="copyCommand(displayedJoinCommandNoWeb)">复制纯探针命令</button>
              <pre class="p-3 rounded-xl bg-slate-950 text-slate-100 font-num text-[11px] whitespace-pre-wrap break-all">{{ displayedJoinCommandNoWeb }}</pre>
            </div>
          </details>

          <div class="flex justify-end gap-2">
            <button type="button" class="px-4 py-2 text-xs rounded-xl border border-slate-200 dark:border-slate-700 cursor-pointer" @click="resetAddModalForAnother">
              继续添加下一台
            </button>
            <button type="button" class="px-4 py-2 text-xs font-medium rounded-xl bg-slate-900 text-white dark:bg-slate-100 dark:text-slate-900 cursor-pointer" @click="showAddModal = false">
              完成
            </button>
          </div>
        </template>
      </div>
    </div>

    <!-- 弹窗二：批量远程统一升级中心 -->
    <div v-if="showUpgradeModal" class="fixed inset-0 z-50 flex items-center justify-center p-4 bg-slate-950/60 backdrop-blur-xs">
      <div class="w-full max-w-2xl rounded-2xl bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-800 shadow-2xl p-6 space-y-4">
        <div class="flex items-center justify-between">
          <div>
            <h3 class="text-base font-bold text-slate-900 dark:text-white">多节点统一远程升级中心</h3>
            <p class="text-xs text-slate-500 mt-0.5">被控二进制节点将优先从本主控机中转拉取目标版本包（免连 GitHub），失败自动回退加速源、强制核验 SHA-256 并平滑重启生效。</p>
          </div>
          <button type="button" class="text-xs text-slate-400 hover:text-slate-600 cursor-pointer" @click="showUpgradeModal = false">关闭</button>
        </div>

        <div class="flex flex-wrap items-end gap-3 p-3.5 rounded-xl bg-slate-50 dark:bg-slate-950 border border-slate-200 dark:border-slate-800 text-xs">
          <div class="flex-1 min-w-44">
            <label class="block text-slate-500 mb-1">目标发布版本号</label>
            <input v-model.trim="upgradeTargetVer" type="text" placeholder="例如 2.1.0" class="w-full px-3 py-1.5 font-num rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900" />
          </div>
          <button type="button" class="px-3 py-1.5 rounded-lg border border-slate-200 dark:border-slate-700 hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer" @click="checkLatestOnline">
            {{ checkingLatest ? '检测中…' : '刷新远程最新版' }}
          </button>
          <button type="button" class="px-3 py-1.5 rounded-lg border border-slate-200 dark:border-slate-700 hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer" @click="selectOutdatedOnlineNodes">
            勾选待升级节点
          </button>
          <button type="button" class="px-3 py-1.5 rounded-lg border border-slate-200 dark:border-slate-700 hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer" @click="selectAllUpgradeableNodes">
            全选在线二进制节点
          </button>
        </div>

        <div class="max-h-64 overflow-y-auto rounded-xl border border-slate-200 dark:border-slate-800 divide-y divide-slate-200/70 dark:divide-slate-800 text-xs">
          <label
            v-for="n in nodes"
            :key="n.id"
            class="flex items-center justify-between px-3.5 py-2.5 cursor-pointer hover:bg-slate-50 dark:hover:bg-slate-800/40"
          >
            <div class="flex items-center gap-2.5">
              <input
                v-model="selectedUpgradeIds"
                type="checkbox"
                :value="n.id"
                :disabled="!n.online || !n.canSelfUpgrade"
                class="accent-blue-600"
              />
              <span class="font-semibold text-slate-800 dark:text-slate-100">{{ n.name }}</span>
              <span class="font-num text-slate-500">v{{ n.version || '—' }}</span>
              <span class="text-[11px] px-1.5 py-0.5 rounded bg-slate-100 dark:bg-slate-800 text-slate-500">
                {{ n.deployMode === 'docker' ? 'Docker (宿主机更新)' : 'systemd 二进制' }}
              </span>
            </div>
            <div class="font-num text-[11px]">
              <span v-if="upgradeFeedback[n.id]" class="text-indigo-600 dark:text-indigo-400">{{ upgradeFeedback[n.id] }}</span>
              <span v-else-if="!n.online" class="text-slate-400">离线</span>
              <span v-else-if="n.upgradeOutdated" class="text-amber-600">有新版本</span>
              <span v-else class="text-emerald-600">最新</span>
            </div>
          </label>
        </div>

        <div class="flex justify-end gap-2">
          <button
            type="button"
            :disabled="selectedUpgradeIds.length === 0 || triggeringUpgrade"
            class="px-5 py-2 rounded-xl bg-indigo-600 hover:bg-indigo-700 disabled:opacity-40 text-white text-xs font-semibold cursor-pointer"
            @click="executeBatchUpgrade"
          >
            {{ triggeringUpgrade ? '正在下发升级指令…' : `一键远程升级选中节点 (${selectedUpgradeIds.length} 台)` }}
          </button>
        </div>
      </div>
    </div>

    <!-- 弹窗三：批量下发月度流量包配额模板 -->
    <div v-if="showBatchQuotaModal" class="fixed inset-0 z-50 flex items-center justify-center p-4 bg-slate-950/60 backdrop-blur-xs">
      <div class="w-full max-w-lg rounded-2xl bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-800 shadow-2xl p-6 space-y-4">
        <div class="flex items-center justify-between">
          <h3 class="text-base font-bold text-slate-900 dark:text-white">批量下发月度流量包模板 ({{ selectedNodeIds.length }} 台)</h3>
          <button type="button" class="text-xs text-slate-400 hover:text-slate-600 cursor-pointer" @click="showBatchQuotaModal = false">关闭</button>
        </div>

        <label class="inline-flex items-center gap-2 text-xs font-medium cursor-pointer">
          <input v-model="batchQuotaForm.enabled" type="checkbox" class="accent-blue-600 w-4 h-4" />
          <span>启用月度流量包监控</span>
        </label>

        <div class="grid grid-cols-2 gap-3 text-xs">
          <div>
            <label class="block text-slate-500 mb-1">每月重置日 (1–31)</label>
            <input v-model.number="batchQuotaForm.resetDay" type="number" min="1" max="31" class="w-full px-2.5 py-1.5 font-num rounded-lg border border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-950" />
          </div>
          <div>
            <label class="block text-slate-500 mb-1">计费方向</label>
            <select v-model="batchQuotaForm.direction" class="w-full px-2.5 py-1.5 rounded-lg border border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-950">
              <option value="both">双向合计 (RX+TX)</option>
              <option value="tx">仅出站上行 (TX)</option>
              <option value="rx">仅入站下行 (RX)</option>
              <option value="max">单向取大 max(RX,TX)</option>
            </select>
          </div>
          <div>
            <label class="block text-slate-500 mb-1">月度限额 (GiB)</label>
            <input v-model.number="batchQuotaForm.limitGiB" type="number" min="1" class="w-full px-2.5 py-1.5 font-num rounded-lg border border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-950" />
          </div>
          <div>
            <label class="block text-slate-500 mb-1">预警阈值 (%)</label>
            <input v-model.number="batchQuotaForm.warnPercent" type="number" min="1" max="99" class="w-full px-2.5 py-1.5 font-num rounded-lg border border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-950" />
          </div>
        </div>

        <div class="flex justify-end gap-2 pt-1">
          <button type="button" class="px-4 py-2 text-xs rounded-xl border border-slate-200 dark:border-slate-700 cursor-pointer" @click="showBatchQuotaModal = false">取消</button>
          <button type="button" :disabled="batchBusy" class="px-4 py-2 text-xs font-medium rounded-xl bg-blue-600 hover:bg-blue-700 text-white cursor-pointer" @click="submitBatchQuota">
            {{ batchBusy ? '下发中…' : '确认批量下发' }}
          </button>
        </div>
      </div>
    </div>

    <!-- 单机远程配置弹窗 -->
    <RemoteNodeConfigModal
      v-if="editingNode"
      :node="editingNode"
      :latest-version="latestVersion || hubVersion"
      @close="editingNode = null"
      @updated="$emit('refresh')"
      @deleted="editingNode = null; $emit('refresh')"
    />
  </div>
</template>

<script setup>
import { ref, reactive, computed, watch } from 'vue';
import TrafficChart from './TrafficChart.vue';
import RemoteNodeConfigModal from './RemoteNodeConfigModal.vue';
import { formatBytes, formatRate, formatUptime, copyTextSafe, apiRequest } from '../utils/format';

const props = defineProps({
  nodes: { type: Array, default: () => [] },
  hubVersion: { type: String, default: '' },
  latestVersion: { type: String, default: '' },
  publicHubUrl: { type: String, default: '' },
  authenticated: { type: Boolean, default: false },
  rateMode: { type: String, default: 'bits' },
  dark: { type: Boolean, default: false }
});

const emit = defineEmits(['select-node', 'require-auth', 'refresh']);

const compareMetrics = [
  { key: 'month', label: '本月流量对比' },
  { key: 'today', label: '今日流量对比' },
  { key: 'speed', label: '实时带宽对比' },
  { key: 'hardware', label: 'CPU / 内存(%)' },
  { key: 'quota', label: '配额使用率(%)' }
];

function readPref(key, fallback) {
  try {
    const val = localStorage.getItem(key);
    return val || fallback;
  } catch (_) {
    return fallback;
  }
}

const compareMode = ref(readPref('fm_fleet_compare', 'month'));
const searchQuery = ref('');
const selectedGroup = ref('__all__');
const sortBy = ref(readPref('fm_fleet_sort', 'month'));
const displayMode = ref(readPref('fm_fleet_display', 'grid'));
const tablePageSize = ref(Number(readPref('fm_fleet_pagesize', '20')) || 20);
const tablePage = ref(1);

watch([compareMode, sortBy, displayMode, tablePageSize], () => {
  try {
    localStorage.setItem('fm_fleet_compare', compareMode.value);
    localStorage.setItem('fm_fleet_sort', sortBy.value);
    localStorage.setItem('fm_fleet_display', displayMode.value);
    localStorage.setItem('fm_fleet_pagesize', String(tablePageSize.value));
  } catch (_) {}
});

const showAddModal = ref(false);
const creatingNode = ref(false);
const addError = ref('');
const copiedHint = ref('');
const createdJoinResult = ref(null);
const resultUseHubMirror = ref(true);
const addForm = reactive({
  hubUrl: '',
  name: '',
  groupName: '',
  remark: '',
  useHubMirror: true
});

const displayedJoinCommand = computed(() => {
  if (!createdJoinResult.value) return '';
  if (resultUseHubMirror.value) {
    return createdJoinResult.value.joinCommandHub || createdJoinResult.value.joinCommand;
  }
  return createdJoinResult.value.joinCommandGithub || createdJoinResult.value.joinCommand;
});

const displayedJoinCommandNoWeb = computed(() => {
  if (!createdJoinResult.value) return '';
  if (resultUseHubMirror.value) {
    return createdJoinResult.value.joinCommandHubNoWeb || createdJoinResult.value.joinCommandNoWeb;
  }
  return createdJoinResult.value.joinCommandGithubNoWeb || createdJoinResult.value.joinCommandNoWeb;
});

const showUpgradeModal = ref(false);
const upgradeTargetVer = ref('');
const checkingLatest = ref(false);
const triggeringUpgrade = ref(false);
const selectedUpgradeIds = ref([]);
const upgradeFeedback = reactive({});

const editingNode = ref(null);
const selectedNodeIds = ref([]);
const batchBusy = ref(false);
const batchNotice = ref('');
const showBatchQuotaModal = ref(false);
const batchQuotaForm = reactive({
  enabled: true,
  resetDay: 1,
  direction: 'both',
  limitGiB: 1000,
  warnPercent: 80
});

function selectAllFilteredNodes() {
  selectedNodeIds.value = filteredNodes.value.map(n => n.id);
}

function toggleSelectAllFiltered(checked) {
  selectedNodeIds.value = checked ? filteredNodes.value.map(n => n.id) : [];
}

function summarizeBatchResult(label, results) {
  const vals = Object.values(results || {});
  const failed = vals.filter(v => String(v).startsWith('失败')).length;
  batchNotice.value = `${label}完成：共 ${vals.length} 台，成功 ${vals.length - failed} 台${failed > 0 ? `，失败 ${failed} 台` : ''}`;
}

async function runBatchGroup() {
  const nextGroup = window.prompt(`为已选中的 ${selectedNodeIds.value.length} 台节点统一设置分组名称（留空则设为未分组）：`, '');
  if (nextGroup === null) return;
  batchBusy.value = true;
  try {
    const res = await apiRequest('/api/v1/admin/cluster/batch/group', {
      method: 'POST',
      body: { nodeIds: selectedNodeIds.value, groupName: nextGroup.trim() }
    });
    summarizeBatchResult('批量改分组', res.results);
    selectedNodeIds.value = [];
    emit('refresh');
  } catch (err) {
    window.alert(err.message);
  } finally {
    batchBusy.value = false;
  }
}

async function submitBatchQuota() {
  batchBusy.value = true;
  try {
    const res = await apiRequest('/api/v1/admin/cluster/batch/quota', {
      method: 'POST',
      body: {
        nodeIds: selectedNodeIds.value,
        quota: {
          enabled: batchQuotaForm.enabled,
          interface: '',
          resetDay: Math.max(1, Math.min(31, Number(batchQuotaForm.resetDay || 1))),
          direction: batchQuotaForm.direction,
          monthlyLimitBytes: Math.max(1, Number(batchQuotaForm.limitGiB || 1)) * 1024 * 1024 * 1024,
          warnPercent: Math.max(1, Math.min(99, Number(batchQuotaForm.warnPercent || 80)))
        }
      }
    });
    showBatchQuotaModal.value = false;
    summarizeBatchResult('批量下发配额', res.results);
    selectedNodeIds.value = [];
    emit('refresh');
  } catch (err) {
    window.alert(err.message);
  } finally {
    batchBusy.value = false;
  }
}

async function runBatchRestart() {
  if (!window.confirm(`确认对已选中的 ${selectedNodeIds.value.length} 台节点执行服务平滑重启吗？\n\n（仅平滑重启 FlowMaster 进程，不会重启操作系统，约 2 秒恢复）`)) return;
  batchBusy.value = true;
  try {
    const res = await apiRequest('/api/v1/admin/cluster/batch/restart', {
      method: 'POST',
      body: { nodeIds: selectedNodeIds.value, confirm: true }
    });
    summarizeBatchResult('批量平滑重启', res.results);
    selectedNodeIds.value = [];
    emit('refresh');
  } catch (err) {
    window.alert(err.message);
  } finally {
    batchBusy.value = false;
  }
}

function openUpgradeForSelected() {
  upgradeTargetVer.value = props.latestVersion || props.hubVersion;
  selectedUpgradeIds.value = props.nodes
    .filter(n => selectedNodeIds.value.includes(n.id) && n.online && n.canSelfUpgrade)
    .map(n => n.id);
  showUpgradeModal.value = true;
}

async function runBatchDelete() {
  const remoteIds = selectedNodeIds.value.filter(id => id !== 'local');
  if (remoteIds.length === 0) {
    window.alert('主控本机节点不可删除，请勾选需要移除的远程被控节点。');
    return;
  }
  if (!window.confirm(`⚠️ 确认从主控批量移除选中的 ${remoteIds.length} 台受控节点吗？\n\n（仅移除主控记录，不会删除目标机器本地流量数据）`)) return;
  batchBusy.value = true;
  try {
    const res = await apiRequest('/api/v1/admin/cluster/batch/delete', {
      method: 'POST',
      body: { nodeIds: remoteIds, confirm: true }
    });
    summarizeBatchResult('批量删除节点', res.results);
    selectedNodeIds.value = [];
    emit('refresh');
  } catch (err) {
    window.alert(err.message);
  } finally {
    batchBusy.value = false;
  }
}

watch([searchQuery, selectedGroup, tablePageSize], () => {
  tablePage.value = 1;
});

const onlineCount = computed(() => props.nodes.filter(n => n.online).length);
const outdatedCount = computed(() => props.nodes.filter(n => n.UpgradeOutdated || n.upgradeOutdated).length);

const groupOptions = computed(() => {
  const counts = new Map();
  for (const n of props.nodes) {
    const g = String(n.groupName || '').trim();
    if (g) counts.set(g, (counts.get(g) || 0) + 1);
  }
  return [...counts.entries()].map(([name, count]) => ({ name, count }));
});

const ungroupedCount = computed(() => props.nodes.filter(n => !String(n.groupName || '').trim()).length);

const fleetSummary = computed(() => {
  let rxBps = 0, txBps = 0, todayRx = 0, todayTx = 0, monthRx = 0, monthTx = 0, warnCount = 0;
  for (const n of props.nodes) {
    if (n.online) {
      rxBps += n.rxBytesPerSec || 0;
      txBps += n.txBytesPerSec || 0;
    }
    todayRx += n.todayRxBytes || 0;
    todayTx += n.todayTxBytes || 0;
    monthRx += n.monthRxBytes || 0;
    monthTx += n.monthTxBytes || 0;
    if (n.quota?.overWarn || n.quota?.overLimit) warnCount++;
  }
  return {
    rxBps,
    txBps,
    todayRx,
    todayTx,
    todayTotal: todayRx + todayTx,
    monthRx,
    monthTx,
    monthTotal: monthRx + monthTx,
    warnCount
  };
});

const filteredNodes = computed(() => {
  const q = searchQuery.value.toLowerCase();
  const list = props.nodes.filter(n => {
    if (selectedGroup.value === '__ungrouped__') {
      if (String(n.groupName || '').trim() !== '') return false;
    } else if (selectedGroup.value !== '__all__' && n.groupName !== selectedGroup.value) {
      return false;
    }
    if (!q) return true;
    const hay = [
      n.name,
      n.groupName,
      n.remark,
      n.hostname,
      n.endpointIp,
      ...(n.ipv4 || []),
      ...(n.ipv6 || [])
    ].join(' ').toLowerCase();
    return hay.includes(q);
  });

  list.sort((a, b) => {
    switch (sortBy.value) {
      case 'today':
        return (b.todayTotalBytes || 0) - (a.todayTotalBytes || 0);
      case 'speed':
        return ((b.rxBytesPerSec || 0) + (b.txBytesPerSec || 0)) - ((a.rxBytesPerSec || 0) + (a.txBytesPerSec || 0));
      case 'quota':
        return (b.quota?.usagePercent || 0) - (a.quota?.usagePercent || 0);
      case 'cpu':
        return (b.host?.cpuPercent || 0) - (a.host?.cpuPercent || 0);
      case 'mem':
        return (b.host?.memPercent || 0) - (a.host?.memPercent || 0);
      case 'name':
        return String(a.name || '').localeCompare(String(b.name || ''));
      default:
        return (b.monthTotalBytes || 0) - (a.monthTotalBytes || 0);
    }
  });
  return list;
});

const tableTotalPages = computed(() => Math.max(1, Math.ceil(filteredNodes.value.length / tablePageSize.value)));
const pagedTableNodes = computed(() => {
  const start = (tablePage.value - 1) * tablePageSize.value;
  return filteredNodes.value.slice(start, start + tablePageSize.value);
});

const compareChart = computed(() => {
  const top = filteredNodes.value.slice(0, 15);
  const labels = top.map(n => n.name);

  if (compareMode.value === 'speed') {
    const isBytes = props.rateMode === 'bytes';
    return {
      labels,
      unit: isBytes ? 'MiB/s' : 'Mbps',
      rxLabel: '实时下行',
      txLabel: '实时上行',
      rx: top.map(n => Number((isBytes ? (n.rxBytesPerSec || 0) / (1024 * 1024) : ((n.rxBytesPerSec || 0) * 8) / 1_000_000).toFixed(2))),
      tx: top.map(n => Number((isBytes ? (n.txBytesPerSec || 0) / (1024 * 1024) : ((n.txBytesPerSec || 0) * 8) / 1_000_000).toFixed(2)))
    };
  }

  if (compareMode.value === 'hardware') {
    return {
      labels,
      unit: '%',
      rxLabel: 'CPU 占用',
      txLabel: '内存占用',
      rx: top.map(n => Number((n.host?.cpuPercent || 0).toFixed(1))),
      tx: top.map(n => Number((n.host?.memPercent || 0).toFixed(1)))
    };
  }

  if (compareMode.value === 'quota') {
    return {
      labels,
      unit: '%',
      rxLabel: '已用配额占比',
      txLabel: '预警阈值',
      rx: top.map(n => Number((n.quota?.enabled ? (n.quota.usagePercent || 0) : 0).toFixed(1))),
      tx: top.map(n => Number((n.quota?.enabled ? (n.quota.warnPercent || 80) : 0).toFixed(0)))
    };
  }

  const isToday = compareMode.value === 'today';
  let maxVal = 0;
  for (const n of top) {
    const rx = isToday ? (n.todayRxBytes || 0) : (n.monthRxBytes || 0);
    const tx = isToday ? (n.todayTxBytes || 0) : (n.monthTxBytes || 0);
    maxVal = Math.max(maxVal, rx, tx);
  }
  const useTiB = maxVal >= 1024 * 1024 * 1024 * 1024;
  const divisor = useTiB ? (1024 * 1024 * 1024 * 1024) : (1024 * 1024 * 1024);
  return {
    labels,
    unit: useTiB ? 'TiB' : 'GiB',
    rxLabel: isToday ? '今日下行' : '本月下行',
    txLabel: isToday ? '今日上行' : '本月上行',
    rx: top.map(n => Number(((isToday ? (n.todayRxBytes || 0) : (n.monthRxBytes || 0)) / divisor).toFixed(2))),
    tx: top.map(n => Number(((isToday ? (n.todayTxBytes || 0) : (n.monthTxBytes || 0)) / divisor).toFixed(2)))
  };
});

function primaryIPv4(node) {
  const publicNicV4 = (node.ipv4 || []).find(ip => ip && !ip.includes(':') && !isLoopbackOrPrivateIP(ip));
  if (publicNicV4) return publicNicV4;
  if (node.endpointIp && !node.endpointIp.includes(':') && !isLoopbackOrPrivateIP(node.endpointIp)) {
    return node.endpointIp;
  }
  const anyNicV4 = (node.ipv4 || []).find(ip => ip && !ip.includes(':') && !ip.startsWith('127.'));
  if (anyNicV4) return anyNicV4;
  return '';
}

function ipv4Tooltip(node) {
  const pub = primaryIPv4(node);
  const priv = (node.ipv4 || []).find(ip => ip && ip !== pub);
  if (pub && priv) return `公网 IPv4: ${pub} | 内网网卡: ${priv}`;
  return pub;
}

function primaryIPv6(node) {
  const publicNicV6 = (node.ipv6 || []).find(ip => ip && !isLoopbackOrPrivateIP(ip));
  if (publicNicV6) return publicNicV6;
  if (node.endpointIp && node.endpointIp.includes(':') && !isLoopbackOrPrivateIP(node.endpointIp)) {
    return node.endpointIp;
  }
  return '';
}

function hasHostMetrics(node) {
  return Boolean(node?.host && (node.host.memTotalBytes > 0 || node.host.diskTotalBytes > 0 || node.host.cpuCores > 0));
}

function meterBarClass(pct) {
  const v = Number(pct || 0);
  if (v >= 90) return 'bg-red-500';
  if (v >= 75) return 'bg-amber-500';
  return 'bg-blue-600 dark:bg-blue-500';
}

function meterTextClass(pct) {
  const v = Number(pct || 0);
  if (v >= 90) return 'text-red-600 dark:text-red-400 font-semibold';
  if (v >= 75) return 'text-amber-600 dark:text-amber-400 font-semibold';
  return 'text-slate-600 dark:text-slate-300';
}

function isLoopbackOrPrivateIP(ip) {
  if (!ip) return true;
  const s = String(ip).trim().toLowerCase();
  if (s === '::1' || s.startsWith('127.') || s.startsWith('10.') || s.startsWith('192.168.') || s.startsWith('169.254.') || s.startsWith('fe80:')) {
    return true;
  }
  const m172 = /^172\.(\d+)\./.exec(s);
  if (m172) {
    const second = Number(m172[1]);
    if (second >= 16 && second <= 31) return true;
  }
  const m100 = /^100\.(\d+)\./.exec(s);
  if (m100) {
    const second = Number(m100[1]);
    if (second >= 64 && second <= 127) return true;
  }
  return false;
}

function directPanelUrl(node) {
  if (!node.panelPort) return '';
  const publicV4 = (node.ipv4 || []).find(ip => !isLoopbackOrPrivateIP(ip));
  if (publicV4) {
    return `http://${publicV4}:${node.panelPort}`;
  }
  if (node.endpointIp && !isLoopbackOrPrivateIP(node.endpointIp)) {
    return node.endpointIp.includes(':')
      ? `http://[${node.endpointIp}]:${node.panelPort}`
      : `http://${node.endpointIp}:${node.panelPort}`;
  }
  const publicV6 = (node.ipv6 || []).find(ip => !isLoopbackOrPrivateIP(ip));
  if (publicV6) {
    return `http://[${publicV6}]:${node.panelPort}`;
  }
  const fallbackV4 = (node.ipv4 || []).find(ip => ip && !ip.startsWith('127.'));
  if (fallbackV4) {
    return `http://${fallbackV4}:${node.panelPort}`;
  }
  return '';
}

function handleOpenAddModal() {
  if (!props.authenticated) {
    emit('require-auth');
    return;
  }
  addError.value = '';
  createdJoinResult.value = null;
  addForm.hubUrl = props.publicHubUrl || window.location.origin;
  addForm.name = '';
  addForm.groupName = '';
  addForm.remark = '';
  addForm.useHubMirror = true;
  resultUseHubMirror.value = true;
  showAddModal.value = true;
}

function resetAddModalForAnother() {
  createdJoinResult.value = null;
  addForm.name = '';
  addForm.remark = '';
  copiedHint.value = '';
}

async function submitCreateNode() {
  addError.value = '';
  creatingNode.value = true;
  try {
    const res = await apiRequest('/api/v1/admin/cluster/nodes', {
      method: 'POST',
      body: addForm
    });
    createdJoinResult.value = res;
    resultUseHubMirror.value = res.useHubMirror !== false;
    emit('refresh');
  } catch (err) {
    addError.value = err.message;
  } finally {
    creatingNode.value = false;
  }
}

async function copyCommand(cmd) {
  const ok = await copyTextSafe(cmd);
  copiedHint.value = ok ? '✅ 已复制！' : '复制失败';
  window.setTimeout(() => { copiedHint.value = ''; }, 2500);
}

function handleOpenUpgradeModal() {
  if (!props.authenticated) {
    emit('require-auth');
    return;
  }
  upgradeTargetVer.value = props.latestVersion || props.hubVersion;
  selectOutdatedOnlineNodes();
  showUpgradeModal.value = true;
}

function selectOutdatedOnlineNodes() {
  selectedUpgradeIds.value = props.nodes
    .filter(n => n.online && n.canSelfUpgrade && n.upgradeOutdated)
    .map(n => n.id);
}

function selectAllUpgradeableNodes() {
  selectedUpgradeIds.value = props.nodes
    .filter(n => n.online && n.canSelfUpgrade)
    .map(n => n.id);
}

async function checkLatestOnline() {
  checkingLatest.value = true;
  try {
    const res = await apiRequest('/api/v1/admin/cluster/releases/latest');
    if (res.version) upgradeTargetVer.value = res.version;
    emit('refresh');
  } catch (_) {
  } finally {
    checkingLatest.value = false;
  }
}

async function executeBatchUpgrade() {
  triggeringUpgrade.value = true;
  try {
    const res = await apiRequest('/api/v1/admin/cluster/upgrade', {
      method: 'POST',
      body: {
        nodeIds: selectedUpgradeIds.value,
        targetVersion: upgradeTargetVer.value
      }
    });
    Object.assign(upgradeFeedback, res.results || {});
    emit('refresh');
  } catch (err) {
    window.alert(err.message);
  } finally {
    triggeringUpgrade.value = false;
  }
}

function openNodeConfig(node) {
  if (!props.authenticated) {
    emit('require-auth');
    return;
  }
  editingNode.value = node;
}

async function confirmDeleteNode(node) {
  if (!props.authenticated) {
    emit('require-auth');
    return;
  }
  const ok = window.confirm(`确认从主控删除节点「${node.name}」吗？\n\n（仅移除主控面板记录，不会删除目标服务器本地数据）`);
  if (!ok) return;
  try {
    await apiRequest(`/api/v1/admin/cluster/nodes/${encodeURIComponent(node.id)}`, { method: 'DELETE' });
    emit('refresh');
  } catch (err) {
    window.alert(err.message);
  }
}
</script>
