<template>
  <div class="mt-4">
    <!-- 搜索过滤与分页条数工具栏 -->
    <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-2.5 mb-3">
      <div class="relative w-full sm:w-64">
        <input
          v-model.trim="keyword"
          type="text"
          placeholder="搜索时间或日期标签..."
          class="w-full pl-3 pr-8 py-1.5 text-sm rounded-lg border border-slate-200 dark:border-slate-800 bg-white dark:bg-slate-900 focus:outline-none focus:ring-2 focus:ring-blue-500/40"
        />
        <button
          v-if="keyword"
          type="button"
          class="absolute right-2 top-1/2 -translate-y-1/2 text-xs text-slate-400 hover:text-slate-600 dark:hover:text-slate-200"
          @click="keyword = ''"
        >
          清除
        </button>
      </div>

      <div class="flex items-center justify-between sm:justify-end gap-3 text-xs text-slate-500 dark:text-slate-400">
        <span>共 <strong class="font-num text-slate-700 dark:text-slate-200">{{ filteredRows.length }}</strong> 条记录</span>
        <label class="inline-flex items-center gap-1.5">
          <span>每页</span>
          <select
            v-model.number="pageSize"
            class="px-2 py-1 rounded-md border border-slate-200 dark:border-slate-800 bg-white dark:bg-slate-900 text-slate-700 dark:text-slate-200 font-num"
          >
            <option :value="20">20</option>
            <option :value="50">50</option>
            <option :value="100">100</option>
          </select>
          <span>条</span>
        </label>
      </div>
    </div>

    <!-- 数据表主体（带序号列与排序） -->
    <div class="overflow-x-auto rounded-xl border border-slate-200 dark:border-slate-800">
      <table class="w-full text-sm text-left border-collapse">
        <thead class="bg-slate-100/80 dark:bg-slate-900/80 text-xs uppercase text-slate-500 dark:text-slate-400 select-none">
          <tr>
            <th class="py-2.5 px-3 w-14 text-center font-semibold">#</th>
            <th class="py-2.5 px-3 cursor-pointer hover:text-blue-600 dark:hover:text-blue-400" @click="toggleSort('timestamp')">
              时间 / 日期 <span class="ml-0.5">{{ sortIndicator('timestamp') }}</span>
            </th>
            <th class="py-2.5 px-3 text-right cursor-pointer hover:text-blue-600 dark:hover:text-blue-400" @click="toggleSort('rxBytes')">
              下行流量 (RX) <span class="ml-0.5">{{ sortIndicator('rxBytes') }}</span>
            </th>
            <th class="py-2.5 px-3 text-right cursor-pointer hover:text-blue-600 dark:hover:text-blue-400" @click="toggleSort('txBytes')">
              上行流量 (TX) <span class="ml-0.5">{{ sortIndicator('txBytes') }}</span>
            </th>
            <th class="py-2.5 px-3 text-right cursor-pointer hover:text-blue-600 dark:hover:text-blue-400" @click="toggleSort('totalBytes')">
              合计流量 <span class="ml-0.5">{{ sortIndicator('totalBytes') }}</span>
            </th>
            <th class="py-2.5 px-3 text-right cursor-pointer hover:text-blue-600 dark:hover:text-blue-400" @click="toggleSort('avgBps')">
              平均速率 <span class="ml-0.5">{{ sortIndicator('avgBps') }}</span>
            </th>
            <th class="py-2.5 px-3 w-32 hidden md:table-cell">流量占比</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-slate-200/70 dark:divide-slate-800/80">
          <tr v-if="pagedRows.length === 0">
            <td colspan="7" class="py-8 text-center text-slate-400 dark:text-slate-500">
              暂无匹配的流量明细记录
            </td>
          </tr>
          <tr
            v-for="(row, idx) in pagedRows"
            :key="`${row.timestamp}-${row.label}`"
            class="hover:bg-blue-50/40 dark:hover:bg-slate-800/40 transition-colors"
          >
            <td class="py-2 px-3 text-center font-num text-xs text-slate-400 dark:text-slate-500">
              {{ (currentPage - 1) * pageSize + idx + 1 }}
            </td>
            <td class="py-2 px-3 font-num font-medium text-slate-800 dark:text-slate-200 whitespace-nowrap">
              {{ row.label }}
            </td>
            <td class="py-2 px-3 text-right font-num text-blue-600 dark:text-blue-400 whitespace-nowrap">
              {{ formatBytes(row.rxBytes) }}
            </td>
            <td class="py-2 px-3 text-right font-num text-emerald-600 dark:text-emerald-400 whitespace-nowrap">
              {{ formatBytes(row.txBytes) }}
            </td>
            <td class="py-2 px-3 text-right font-num font-semibold text-slate-900 dark:text-slate-100 whitespace-nowrap">
              {{ formatBytes(row.totalBytes) }}
            </td>
            <td class="py-2 px-3 text-right font-num text-slate-500 dark:text-slate-400 whitespace-nowrap">
              {{ formatBps(row.avgBps) }}
            </td>
            <td class="py-2 px-3 hidden md:table-cell">
              <div class="w-full h-2 rounded-full bg-slate-200/70 dark:bg-slate-800 overflow-hidden flex">
                <div
                  class="bg-blue-500 h-full"
                  :style="{ width: sharePercent(row.rxBytes) + '%' }"
                  :title="`下行: ${formatBytes(row.rxBytes)}`"
                ></div>
                <div
                  class="bg-emerald-500 h-full"
                  :style="{ width: sharePercent(row.txBytes) + '%' }"
                  :title="`上行: ${formatBytes(row.txBytes)}`"
                ></div>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>

    <!-- 增强分页栏 -->
    <div v-if="totalPages > 1" class="flex flex-wrap items-center justify-between gap-2 mt-3 text-xs text-slate-500 dark:text-slate-400">
      <div class="font-num">
        显示第 {{ (currentPage - 1) * pageSize + 1 }} – {{ Math.min(currentPage * pageSize, filteredRows.length) }} 条
      </div>
      <div class="flex items-center gap-1">
        <button
          type="button"
          class="px-2.5 py-1 rounded border border-slate-200 dark:border-slate-800 disabled:opacity-40 hover:bg-slate-100 dark:hover:bg-slate-800"
          :disabled="currentPage <= 1"
          @click="currentPage = 1"
        >
          首页
        </button>
        <button
          type="button"
          class="px-2.5 py-1 rounded border border-slate-200 dark:border-slate-800 disabled:opacity-40 hover:bg-slate-100 dark:hover:bg-slate-800"
          :disabled="currentPage <= 1"
          @click="currentPage--"
        >
          上一页
        </button>
        <span class="px-2.5 py-1 font-num text-slate-700 dark:text-slate-200">
          {{ currentPage }} / {{ totalPages }}
        </span>
        <button
          type="button"
          class="px-2.5 py-1 rounded border border-slate-200 dark:border-slate-800 disabled:opacity-40 hover:bg-slate-100 dark:hover:bg-slate-800"
          :disabled="currentPage >= totalPages"
          @click="currentPage++"
        >
          下一页
        </button>
        <button
          type="button"
          class="px-2.5 py-1 rounded border border-slate-200 dark:border-slate-800 disabled:opacity-40 hover:bg-slate-100 dark:hover:bg-slate-800"
          :disabled="currentPage >= totalPages"
          @click="currentPage = totalPages"
        >
          末页
        </button>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, computed, watch } from 'vue';
import { formatBytes, formatBps } from '../utils/format';

const props = defineProps({
  rows: { type: Array, default: () => [] }
});

const keyword = ref('');
const pageSize = ref(20);
const currentPage = ref(1);
// 默认按时间倒序排列，让最新时间桶排在表格第一行便于即时核对
const sortKey = ref('timestamp');
const sortOrder = ref('desc');

watch([keyword, pageSize, () => props.rows], () => {
  currentPage.value = 1;
});

function toggleSort(key) {
  if (sortKey.value === key) {
    sortOrder.value = sortOrder.value === 'desc' ? 'asc' : 'desc';
  } else {
    sortKey.value = key;
    sortOrder.value = 'desc';
  }
}

function sortIndicator(key) {
  if (sortKey.value !== key) return '↕';
  return sortOrder.value === 'desc' ? '↓' : '↑';
}

const maxTotal = computed(() => {
  let m = 0;
  for (const r of props.rows) {
    if ((r.totalBytes || 0) > m) m = r.totalBytes;
  }
  return m || 1;
});

function sharePercent(val) {
  return Math.min(100, Math.max(0, ((val || 0) / maxTotal.value) * 100)).toFixed(1);
}

const filteredRows = computed(() => {
  const q = keyword.value.toLowerCase();
  const base = q
    ? props.rows.filter(item => String(item.label || '').toLowerCase().includes(q))
    : [...props.rows];

  const key = sortKey.value;
  const factor = sortOrder.value === 'asc' ? 1 : -1;
  base.sort((a, b) => {
    const va = a[key] ?? 0;
    const vb = b[key] ?? 0;
    if (va < vb) return -1 * factor;
    if (va > vb) return 1 * factor;
    return String(a.label || '').localeCompare(String(b.label || '')) * factor;
  });
  return base;
});

const totalPages = computed(() => Math.max(1, Math.ceil(filteredRows.value.length / pageSize.value)));

const pagedRows = computed(() => {
  const start = (currentPage.value - 1) * pageSize.value;
  return filteredRows.value.slice(start, start + pageSize.value);
});
</script>
