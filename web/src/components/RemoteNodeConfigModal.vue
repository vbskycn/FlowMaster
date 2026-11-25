<template>
  <div class="fixed inset-0 z-50 flex items-center justify-center p-3 sm:p-4 bg-slate-950/60 backdrop-blur-xs">
    <div class="w-full max-w-3xl max-h-[90vh] flex flex-col rounded-2xl bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-800 shadow-2xl overflow-hidden">
      <header class="flex items-center justify-between px-5 py-3.5 border-b border-slate-200 dark:border-slate-800 bg-slate-50/80 dark:bg-slate-950/60">
        <div>
          <h3 class="text-base font-bold text-slate-900 dark:text-white">
            远程节点配置：{{ node.name }}
          </h3>
          <p class="text-xs text-slate-500 font-num mt-0.5">
            ID: {{ node.id }} · 版本: v{{ node.version || '未知' }} · {{ node.os }}/{{ node.arch }} ({{ node.deployMode || 'binary' }})
          </p>
        </div>
        <button
          type="button"
          class="px-3 py-1.5 text-xs rounded-lg border border-slate-200 dark:border-slate-700 hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer"
          @click="$emit('close')"
        >
          关闭
        </button>
      </header>

      <div v-if="notice.text" class="px-5 py-2 text-xs flex items-center justify-between border-b"
        :class="notice.type === 'error'
          ? 'bg-red-50 dark:bg-red-950/50 text-red-700 dark:text-red-300 border-red-200 dark:border-red-900'
          : 'bg-emerald-50 dark:bg-emerald-950/50 text-emerald-700 dark:text-emerald-300 border-emerald-200 dark:border-emerald-900'">
        <span>{{ notice.text }}</span>
        <button type="button" class="underline ml-2" @click="notice.text = ''">关闭</button>
      </div>

      <div class="flex-1 overflow-y-auto p-5 space-y-5">
        <!-- 1. 主控侧节点标识与分组 -->
        <div class="p-4 rounded-xl border border-slate-200 dark:border-slate-800 space-y-3">
          <h4 class="text-xs font-semibold uppercase tracking-wider text-slate-500">节点名称与分组标识</h4>
          <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
            <div>
              <label class="block text-xs text-slate-500 mb-1">显示名称</label>
              <input v-model.trim="metaForm.name" type="text" maxlength="48" class="w-full px-3 py-1.5 text-xs rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950" />
            </div>
            <div>
              <label class="block text-xs text-slate-500 mb-1">分组标签</label>
              <input v-model.trim="metaForm.groupName" type="text" maxlength="32" placeholder="例如：美国甲骨文 / 香港" class="w-full px-3 py-1.5 text-xs rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950" />
            </div>
            <div>
              <label class="block text-xs text-slate-500 mb-1">备注说明</label>
              <input v-model.trim="metaForm.remark" type="text" maxlength="80" placeholder="可选到期日或用途备注" class="w-full px-3 py-1.5 text-xs rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950" />
            </div>
          </div>
          <div class="flex flex-wrap items-center justify-between gap-2">
            <button type="button" class="px-3.5 py-1.5 text-xs font-medium rounded-lg bg-blue-600 hover:bg-blue-700 text-white cursor-pointer" @click="saveMeta">
              保存节点标识
            </button>
            <div class="flex flex-wrap items-center gap-2">
              <button
                v-if="node.online"
                type="button"
                class="px-3 py-1.5 text-xs rounded-lg bg-amber-50 text-amber-700 dark:bg-amber-950 dark:text-amber-300 hover:opacity-85 cursor-pointer"
                @click="restartSingleNode"
              >
                🔄 平滑重启
              </button>
              <button
                v-if="node.online"
                type="button"
                :disabled="downloadingBackup"
                class="px-3 py-1.5 text-xs rounded-lg bg-emerald-50 text-emerald-700 dark:bg-emerald-950 dark:text-emerald-300 hover:opacity-85 cursor-pointer disabled:opacity-50"
                @click="downloadRemoteBackup"
              >
                {{ downloadingBackup ? '备份中…' : '💾 远程备份下载' }}
              </button>
              <button
                v-if="node.online"
                type="button"
                class="px-3 py-1.5 text-xs rounded-lg bg-indigo-50 text-indigo-700 dark:bg-indigo-950 dark:text-indigo-300 hover:opacity-85 cursor-pointer"
                @click="upgradeSingleNode"
              >
                🚀 远程升级
              </button>
              <button
                type="button"
                class="px-3 py-1.5 text-xs rounded-lg bg-red-50 text-red-600 dark:bg-red-950 dark:text-red-400 hover:opacity-85 cursor-pointer"
                @click="removeNode"
              >
                移除节点
              </button>
            </div>
          </div>
        </div>

        <!-- 2. 在线远程节点业务配置（仅在线时可通过反向隧道实时读写） -->
        <div v-if="!node.online" class="p-6 text-center text-xs text-slate-400 border border-dashed border-slate-200 dark:border-slate-800 rounded-xl">
          该节点当前处于离线状态，上线后可在此直接远程调整其月度流量包配额与网卡显隐规则。
        </div>

        <template v-else-if="remoteLoaded">
          <div class="p-4 rounded-xl border border-slate-200 dark:border-slate-800 space-y-3.5">
            <div class="flex items-center justify-between">
              <h4 class="text-xs font-semibold uppercase tracking-wider text-slate-500">远程节点月度流量配额与引擎设置</h4>
              <label class="inline-flex items-center gap-1.5 text-xs font-medium cursor-pointer">
                <input v-model="quotaForm.enabled" type="checkbox" class="accent-blue-600" />
                <span>启用月度流量包监控</span>
              </label>
            </div>

            <div class="grid grid-cols-1 sm:grid-cols-3 gap-3 text-xs">
              <div>
                <label class="block text-slate-500 mb-1">数据源引擎</label>
                <select v-model="systemForm.dataSourceMode" class="w-full px-2.5 py-1.5 rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950">
                  <option value="hybrid">Hybrid 智能融合</option>
                  <option value="sqlite">纯内置 SQLite</option>
                  <option value="vnstat">系统 vnstat 直读</option>
                </select>
              </div>
              <div>
                <label class="block text-slate-500 mb-1">配额绑定网卡</label>
                <select v-model="quotaForm.interface" class="w-full px-2.5 py-1.5 rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950">
                  <option value="">跟随默认主网卡</option>
                  <option value="__all__">汇总全部可见网卡</option>
                  <option v-for="nic in remoteInterfaces" :key="nic.name" :value="nic.name">{{ nic.name }}</option>
                </select>
              </div>
              <div>
                <label class="block text-slate-500 mb-1">每月重置日 (1–31)</label>
                <input v-model.number="quotaForm.resetDay" type="number" min="1" max="31" class="w-full px-2.5 py-1.5 font-num rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950" />
              </div>
              <div>
                <label class="block text-slate-500 mb-1">计费统计方向</label>
                <select v-model="quotaForm.direction" class="w-full px-2.5 py-1.5 rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950">
                  <option value="both">双向合计 (RX+TX)</option>
                  <option value="tx">仅计出站上行 (TX)</option>
                  <option value="rx">仅计入站下行 (RX)</option>
                  <option value="max">单向取大 max(RX,TX)</option>
                </select>
              </div>
              <div>
                <label class="block text-slate-500 mb-1">月度限额 (GiB)</label>
                <input v-model.number="quotaLimitGiB" type="number" min="1" class="w-full px-2.5 py-1.5 font-num rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950" />
              </div>
              <div>
                <label class="block text-slate-500 mb-1">预警阈值 (%)</label>
                <input v-model.number="quotaForm.warnPercent" type="number" min="1" max="99" class="w-full px-2.5 py-1.5 font-num rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950" />
              </div>
            </div>

            <div class="flex flex-wrap items-center gap-2.5">
              <button type="button" class="px-3.5 py-1.5 text-xs font-medium rounded-lg bg-blue-600 hover:bg-blue-700 text-white cursor-pointer" @click="saveRemoteConfig">
                下发保存配额与引擎配置
              </button>
              <button type="button" class="px-3 py-1.5 text-xs rounded-lg border border-slate-300 dark:border-slate-700 hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer" @click="remoteImportVnstat">
                远程合并 vnstat 历史数据
              </button>
            </div>
          </div>

          <!-- 3. 远程网卡显隐管理 -->
          <div class="p-4 rounded-xl border border-slate-200 dark:border-slate-800 space-y-2.5">
            <h4 class="text-xs font-semibold uppercase tracking-wider text-slate-500">远程网卡显隐与备注</h4>
            <div class="overflow-x-auto">
              <table class="w-full text-xs text-left border-collapse">
                <thead class="text-slate-500 border-b border-slate-200 dark:border-slate-800">
                  <tr>
                    <th class="py-2 pr-2">#</th>
                    <th class="py-2 pr-2">网卡</th>
                    <th class="py-2 pr-2">IP 地址</th>
                    <th class="py-2 pr-2">备注</th>
                    <th class="py-2 pr-2">显隐</th>
                    <th class="py-2 text-right">操作</th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-slate-200/60 dark:divide-slate-800">
                  <tr v-for="(nic, i) in remoteInterfaces" :key="nic.name">
                    <td class="py-2 pr-2 font-num text-slate-400">{{ i + 1 }}</td>
                    <td class="py-2 pr-2 font-num font-semibold">{{ nic.name }}</td>
                    <td class="py-2 pr-2 font-num text-[11px] text-slate-500">
                      <div v-if="nic.ipv4?.length">{{ nic.ipv4[0] }}</div>
                      <div v-if="nic.ipv6?.length" class="truncate max-w-44" :title="nic.ipv6[0]">{{ nic.ipv6[0] }}</div>
                    </td>
                    <td class="py-2 pr-2">
                      <input v-model="nic._editAlias" type="text" maxlength="32" class="w-28 px-2 py-1 rounded border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950" />
                    </td>
                    <td class="py-2 pr-2">
                      <select v-model="nic._editVisible" class="px-2 py-1 rounded border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950">
                        <option value="show">显示</option>
                        <option value="hide">隐藏</option>
                      </select>
                    </td>
                    <td class="py-2 text-right">
                      <button type="button" class="px-2.5 py-1 rounded bg-slate-900 text-white dark:bg-slate-100 dark:text-slate-900 cursor-pointer" @click="saveRemoteNic(nic)">
                        保存
                      </button>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
          <!-- 4. 远程节点实时脱敏日志查看器（免 SSH 排错） -->
          <div class="p-4 rounded-xl border border-slate-200 dark:border-slate-800 space-y-2.5">
            <div class="flex flex-wrap items-center justify-between gap-2">
              <h4 class="text-xs font-semibold uppercase tracking-wider text-slate-500">远程节点脱敏运行日志（最新在顶部）</h4>
              <div class="flex items-center gap-2 text-xs">
                <select v-model="remoteLogChannel" class="px-2 py-1 rounded border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950" @change="loadRemoteLogs">
                  <option value="system">系统日志 (system)</option>
                  <option value="alert">告警日志 (alert)</option>
                </select>
                <button type="button" class="px-2.5 py-1 rounded border border-slate-200 dark:border-slate-700 hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer" @click="loadRemoteLogs">
                  {{ loadingLogs ? '读取中…' : '刷新日志' }}
                </button>
              </div>
            </div>
            <div class="max-h-48 overflow-y-auto rounded-lg bg-slate-950 text-slate-200 p-2.5 font-num text-[11px] space-y-1">
              <div v-if="remoteLogs.length === 0" class="text-slate-500 py-3 text-center">点击“刷新日志”读取该节点最近日志</div>
              <div v-for="(item, idx) in remoteLogs" :key="idx" class="break-all leading-relaxed">
                <span class="text-slate-500">[{{ item.timestamp }}]</span>
                <span class="ml-1 font-semibold" :class="item.level === 'ERROR' ? 'text-red-400' : (item.level === 'WARN' ? 'text-amber-400' : 'text-emerald-400')">[{{ item.level }}]</span>
                <span class="ml-1">{{ item.message }}</span>
              </div>
            </div>
          </div>
        </template>
        <div v-else class="py-8 text-center text-xs text-slate-400">正在通过加密通道读取远程节点配置…</div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, reactive, computed, onMounted } from 'vue';
import { apiRequest } from '../utils/format';

const props = defineProps({
  node: { type: Object, required: true },
  latestVersion: { type: String, default: '' }
});

const emit = defineEmits(['close', 'updated', 'deleted']);

const notice = reactive({ type: 'ok', text: '' });
const remoteLoaded = ref(false);

const metaForm = reactive({
  name: props.node.name || '',
  groupName: props.node.groupName || '',
  remark: props.node.remark || ''
});

const systemForm = reactive({
  siteTitle: 'FlowMaster 流量监控',
  requireLoginForView: false,
  dataSourceMode: 'hybrid',
  hideVirtualInterfaces: true,
  defaultInterface: '',
  retention5mDays: 7,
  retentionHourlyDays: 90,
  retentionDailyDays: 3660,
  maxBackups: 20,
  maxProtectSnapshots: 10
});

const quotaForm = reactive({
  enabled: false,
  interface: '',
  resetDay: 1,
  direction: 'both',
  monthlyLimitBytes: 1000 * 1024 * 1024 * 1024,
  warnPercent: 80
});

const quotaLimitGiB = computed({
  get: () => Math.max(1, Math.round((quotaForm.monthlyLimitBytes || 0) / (1024 * 1024 * 1024))),
  set: val => {
    quotaForm.monthlyLimitBytes = Math.max(1, Number(val || 1)) * 1024 * 1024 * 1024;
  }
});

const remoteInterfaces = ref([]);
const remoteLogChannel = ref('system');
const remoteLogs = ref([]);
const loadingLogs = ref(false);
const downloadingBackup = ref(false);

function showMsg(text, type = 'ok') {
  notice.type = type;
  notice.text = text;
}

async function loadRemoteNodeConfig() {
  if (!props.node.online) return;
  try {
    const data = await apiRequest(`/api/v1/admin/cluster/nodes/${encodeURIComponent(props.node.id)}/config`);
    if (data.system) Object.assign(systemForm, data.system);
    if (data.quota) Object.assign(quotaForm, data.quota);
    remoteInterfaces.value = (data.interfaces || []).map(item => ({
      ...item,
      _editAlias: item.alias || '',
      _editVisible: item.visible ? 'show' : 'hide'
    }));
    remoteLoaded.value = true;
  } catch (err) {
    showMsg(`读取远程节点配置失败: ${err.message}`, 'error');
  }
}

async function saveMeta() {
  try {
    await apiRequest(`/api/v1/admin/cluster/nodes/${encodeURIComponent(props.node.id)}`, {
      method: 'PUT',
      body: metaForm
    });
    showMsg('节点标识已保存');
    emit('updated');
  } catch (err) {
    showMsg(err.message, 'error');
  }
}

async function saveRemoteConfig() {
  try {
    await apiRequest(`/api/v1/admin/cluster/nodes/${encodeURIComponent(props.node.id)}/config`, {
      method: 'PUT',
      body: { system: systemForm, quota: quotaForm }
    });
    showMsg('远程节点配额与引擎设置已生效');
    emit('updated');
  } catch (err) {
    showMsg(err.message, 'error');
  }
}

async function saveRemoteNic(nic) {
  try {
    await apiRequest(`/api/v1/admin/cluster/nodes/${encodeURIComponent(props.node.id)}/interfaces/${encodeURIComponent(nic.name)}`, {
      method: 'PUT',
      body: {
        alias: nic._editAlias,
        visible: nic._editVisible === 'show'
      }
    });
    showMsg(`远程网卡 ${nic.name} 设置已保存`);
    emit('updated');
  } catch (err) {
    showMsg(err.message, 'error');
  }
}

async function remoteImportVnstat() {
  try {
    const res = await apiRequest(`/api/v1/admin/cluster/nodes/${encodeURIComponent(props.node.id)}/vnstat/import`, {
      method: 'POST',
      body: {}
    });
    showMsg(res.message || '远程导入成功');
    emit('updated');
  } catch (err) {
    showMsg(err.message, 'error');
  }
}

async function upgradeSingleNode() {
  try {
    const res = await apiRequest('/api/v1/admin/cluster/upgrade', {
      method: 'POST',
      body: {
        nodeIds: [props.node.id],
        targetVersion: props.latestVersion || ''
      }
    });
    const detail = res.results?.[props.node.id] || '已发送升级指令';
    showMsg(`目标版本 v${res.targetVersion}: ${detail}`, detail.startsWith('失败') ? 'error' : 'ok');
    emit('updated');
  } catch (err) {
    showMsg(err.message, 'error');
  }
}

async function restartSingleNode() {
  if (!window.confirm(`确认平滑重启节点「${props.node.name}」的 FlowMaster 服务吗？（约 2 秒自动恢复，不会重启操作系统）`)) return;
  try {
    const res = await apiRequest('/api/v1/admin/cluster/batch/restart', {
      method: 'POST',
      body: { nodeIds: [props.node.id], confirm: true }
    });
    const detail = res.results?.[props.node.id] || '已发送平滑重启指令';
    showMsg(detail, detail.startsWith('失败') ? 'error' : 'ok');
    emit('updated');
  } catch (err) {
    showMsg(err.message, 'error');
  }
}

async function loadRemoteLogs() {
  loadingLogs.value = true;
  try {
    const res = await apiRequest(`/api/v1/admin/cluster/nodes/${encodeURIComponent(props.node.id)}/logs?channel=${remoteLogChannel.value}&limit=100`);
    remoteLogs.value = res.entries || [];
  } catch (err) {
    showMsg(`读取远程日志失败: ${err.message}`, 'error');
  } finally {
    loadingLogs.value = false;
  }
}

async function downloadRemoteBackup() {
  downloadingBackup.value = true;
  try {
    const resp = await fetch(`/api/v1/admin/cluster/nodes/${encodeURIComponent(props.node.id)}/backup/download`, {
      method: 'POST',
      credentials: 'same-origin',
      headers: { 'X-Requested-With': 'FlowMaster' }
    });
    if (!resp.ok) {
      const errData = await resp.json().catch(() => ({}));
      throw new Error(errData.error || `HTTP ${resp.status}`);
    }
    const blob = await resp.blob();
    const cd = resp.headers.get('Content-Disposition') || '';
    const match = /filename="([^"]+)"/.exec(cd);
    const filename = match ? match[1] : `${props.node.name || props.node.id}-backup.tar.gz`;
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    a.remove();
    URL.revokeObjectURL(url);
    showMsg(`远程备份 ${filename} 已创建并开始下载到本地`);
  } catch (err) {
    showMsg(`远程备份失败: ${err.message}`, 'error');
  } finally {
    downloadingBackup.value = false;
  }
}

async function removeNode() {
  if (!window.confirm(`确定要从主控移除节点「${props.node.name}」吗？（不会删除被控机上的历史流量数据）`)) return;
  try {
    await apiRequest(`/api/v1/admin/cluster/nodes/${encodeURIComponent(props.node.id)}`, { method: 'DELETE' });
    emit('deleted', props.node.id);
  } catch (err) {
    showMsg(err.message, 'error');
  }
}

onMounted(() => {
  loadRemoteNodeConfig();
});
</script>
