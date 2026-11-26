<template>
  <div class="fixed inset-0 z-40 flex items-center justify-center p-2 sm:p-4 bg-slate-950/60 backdrop-blur-xs">
    <div class="w-full max-w-5xl h-[92vh] flex flex-col rounded-2xl bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-800 shadow-2xl overflow-hidden">
      <!-- 后台顶栏（含系统名称与版本号） -->
      <header class="flex items-center justify-between px-5 py-3.5 border-b border-slate-200 dark:border-slate-800 bg-slate-50/80 dark:bg-slate-950/60">
        <div class="flex items-center gap-2.5">
          <img src="/favicon.svg" alt="FlowMaster" class="w-7 h-7 rounded-lg" />
          <div class="flex items-baseline gap-2">
            <h2 class="text-base font-bold text-slate-900 dark:text-white">FlowMaster 管理中心</h2>
            <span
              v-if="version"
              class="font-num text-xs px-2 py-0.5 rounded-full bg-blue-50 text-blue-700 dark:bg-blue-950/80 dark:text-blue-300 border border-blue-200/70 dark:border-blue-800/70"
            >
              v{{ version }}
            </span>
          </div>
        </div>
        <div class="flex items-center gap-2">
          <button
            type="button"
            class="px-3 py-1.5 text-xs rounded-lg border border-slate-200 dark:border-slate-700 text-slate-600 dark:text-slate-300 hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer"
            @click="handleLogout"
          >
            退出登录
          </button>
          <button
            type="button"
            class="px-3 py-1.5 text-xs font-medium rounded-lg bg-slate-900 text-white dark:bg-slate-100 dark:text-slate-900 hover:opacity-90 cursor-pointer"
            @click="$emit('close')"
          >
            返回看板
          </button>
        </div>
      </header>

      <!-- 导航标签栏 -->
      <nav class="flex items-center gap-1 px-4 py-2 border-b border-slate-200 dark:border-slate-800 overflow-x-auto bg-white dark:bg-slate-900">
        <button
          v-for="t in tabs"
          :key="t.key"
          type="button"
          class="px-3.5 py-1.5 text-xs font-medium rounded-lg whitespace-nowrap transition-colors cursor-pointer"
          :class="activeTab === t.key
            ? 'bg-blue-600 text-white'
            : 'text-slate-600 dark:text-slate-400 hover:bg-slate-100 dark:hover:bg-slate-800'"
          @click="switchTab(t.key)"
        >
          {{ t.label }}
        </button>
      </nav>

      <!-- 全局操作反馈条 -->
      <div v-if="notice.text" class="px-5 py-2.5 text-xs flex items-center justify-between border-b"
        :class="notice.type === 'error'
          ? 'bg-red-50 dark:bg-red-950/50 text-red-700 dark:text-red-300 border-red-200 dark:border-red-900'
          : 'bg-emerald-50 dark:bg-emerald-950/50 text-emerald-700 dark:text-emerald-300 border-emerald-200 dark:border-emerald-900'">
        <span>{{ notice.text }}</span>
        <button type="button" class="underline ml-3" @click="notice.text = ''">关闭</button>
      </div>

      <!-- 主内容滚动区 -->
      <div class="flex-1 overflow-y-auto p-5 space-y-6">
        <!-- Tab 1: 概览与数据源引擎 -->
        <section v-if="activeTab === 'overview'" class="space-y-6">
          <div class="grid grid-cols-2 sm:grid-cols-4 gap-3.5">
            <div class="p-4 rounded-xl border border-slate-200 dark:border-slate-800 bg-slate-50/60 dark:bg-slate-950/50">
              <div class="text-xs text-slate-500 dark:text-slate-400">Go 运行时内存 (Sys / Heap)</div>
              <div class="mt-1 text-base font-bold font-num text-slate-900 dark:text-white">
                {{ formatBytes(overview.memorySysBytes) }} / {{ formatBytes(overview.heapAllocBytes) }}
              </div>
              <div class="mt-0.5 text-[11px] text-slate-400 font-num">协程数: {{ overview.goroutines || 0 }}</div>
            </div>
            <div class="p-4 rounded-xl border border-slate-200 dark:border-slate-800 bg-slate-50/60 dark:bg-slate-950/50">
              <div class="text-xs text-slate-500 dark:text-slate-400">SQLite 数据库占用</div>
              <div class="mt-1 text-base font-bold font-num text-slate-900 dark:text-white">
                {{ formatBytes(overview.dbSizeBytes) }}
              </div>
              <div class="mt-0.5 text-[11px] text-slate-400 truncate" :title="overview.dataDir">{{ overview.dataDir }}</div>
            </div>
            <div class="p-4 rounded-xl border border-slate-200 dark:border-slate-800 bg-slate-50/60 dark:bg-slate-950/50">
              <div class="text-xs text-slate-500 dark:text-slate-400">持续运行时长</div>
              <div class="mt-1 text-base font-bold font-num text-slate-900 dark:text-white">
                {{ formatUptime(overview.uptimeSeconds) }}
              </div>
              <div class="mt-0.5 text-[11px] text-slate-400 font-num">{{ overview.platform }}/{{ overview.arch }} · {{ overview.goVersion }}</div>
            </div>
            <div class="p-4 rounded-xl border border-slate-200 dark:border-slate-800 bg-slate-50/60 dark:bg-slate-950/50">
              <div class="text-xs text-slate-500 dark:text-slate-400">系统 vnstat 状态</div>
              <div class="mt-1 text-sm font-bold" :class="overview.vnstatAvailable ? 'text-emerald-600 dark:text-emerald-400' : 'text-slate-500'">
                {{ overview.vnstatAvailable ? '已就绪' : '未安装（使用内核直采）' }}
              </div>
              <div class="mt-0.5 text-[11px] text-slate-400 truncate">{{ overview.vnstatVersion || '无需外部依赖即可独立运行' }}</div>
            </div>
          </div>

          <div class="p-5 rounded-xl border border-slate-200 dark:border-slate-800 space-y-4">
            <div>
              <h3 class="text-sm font-semibold text-slate-900 dark:text-white">流量采集与数据源模式（混合引擎）</h3>
              <p class="text-xs text-slate-500 dark:text-slate-400 mt-0.5">
                实时网速默认通过 Linux 内核 <code class="px-1 py-0.5 rounded bg-slate-100 dark:bg-slate-800">/proc/net/dev</code> 秒级直采（零子进程开销）；历史统计支持以下三种引擎模式自由切换：
              </p>
            </div>

            <div class="grid grid-cols-1 md:grid-cols-3 gap-3">
              <label
                v-for="m in sourceModeOptions"
                :key="m.value"
                class="p-3.5 rounded-xl border cursor-pointer transition-all"
                :class="systemForm.dataSourceMode === m.value
                  ? 'border-blue-500 bg-blue-50/50 dark:bg-blue-950/30'
                  : 'border-slate-200 dark:border-slate-800 hover:border-slate-300 dark:hover:border-slate-700'"
              >
                <div class="flex items-center gap-2">
                  <input v-model="systemForm.dataSourceMode" type="radio" :value="m.value" class="accent-blue-600" />
                  <span class="text-sm font-semibold text-slate-800 dark:text-slate-100">{{ m.title }}</span>
                </div>
                <p class="text-xs text-slate-500 dark:text-slate-400 mt-1.5 leading-relaxed">{{ m.desc }}</p>
              </label>
            </div>

            <div class="flex flex-wrap items-center gap-3 pt-2">
              <button
                type="button"
                class="px-4 py-2 text-xs font-medium rounded-lg bg-blue-600 hover:bg-blue-700 text-white cursor-pointer"
                :disabled="savingSettings"
                @click="saveSystemAndQuota"
              >
                {{ savingSettings ? '保存中…' : '保存数据源设置' }}
              </button>

              <button
                type="button"
                class="px-4 py-2 text-xs font-medium rounded-lg border border-slate-300 dark:border-slate-700 hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer disabled:opacity-40"
                :disabled="!overview.vnstatAvailable || importingVnstat"
                @click="importFromVnstat"
              >
                {{ importingVnstat ? '正在导入…' : '从系统 vnstat 幂等导入历史数据' }}
              </button>
            </div>
          </div>
        </section>

        <!-- Tab 2: 网卡管理 -->
        <section v-if="activeTab === 'interfaces'" class="space-y-5">
          <div class="p-4 rounded-xl border border-slate-200 dark:border-slate-800 flex flex-wrap items-center justify-between gap-4">
            <div class="space-y-1">
              <label class="inline-flex items-center gap-2 text-sm font-medium text-slate-800 dark:text-slate-100 cursor-pointer">
                <input v-model="systemForm.hideVirtualInterfaces" type="checkbox" class="accent-blue-600 w-4 h-4" />
                <span>默认隐藏容器与隧道虚拟网卡（如 <code class="text-xs">veth*</code> / <code class="text-xs">docker*</code> / <code class="text-xs">br-*</code>）</span>
              </label>
              <p class="text-xs text-slate-500 dark:text-slate-400">开启后前台仅展示物理网卡及下方显式设为“始终显示”的接口。</p>
            </div>

            <div class="flex items-center gap-2.5">
              <label class="text-xs text-slate-500">默认首选网卡：</label>
              <select
                v-model="systemForm.defaultInterface"
                class="px-2.5 py-1.5 text-xs rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950"
              >
                <option value="">自动（按物理网卡优先级）</option>
                <option v-for="item in adminInterfaces" :key="item.name" :value="item.name">{{ item.name }}</option>
              </select>
              <button
                type="button"
                class="px-3.5 py-1.5 text-xs font-medium rounded-lg bg-blue-600 hover:bg-blue-700 text-white cursor-pointer"
                @click="saveSystemAndQuota"
              >
                保存全局规则
              </button>
            </div>
          </div>

          <div class="overflow-x-auto rounded-xl border border-slate-200 dark:border-slate-800">
            <table class="w-full text-xs text-left border-collapse">
              <thead class="bg-slate-100/80 dark:bg-slate-900/80 text-slate-500 dark:text-slate-400">
                <tr>
                  <th class="py-2.5 px-3 w-12 text-center">#</th>
                  <th class="py-2.5 px-3">接口名称</th>
                  <th class="py-2.5 px-3">类型 / 状态</th>
                  <th class="py-2.5 px-3">IPv4 / 速率</th>
                  <th class="py-2.5 px-3">备注别名</th>
                  <th class="py-2.5 px-3">前台显隐</th>
                  <th class="py-2.5 px-3 text-right">操作</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-slate-200/70 dark:divide-slate-800">
                <tr v-for="(nic, idx) in adminInterfaces" :key="nic.name">
                  <td class="py-2.5 px-3 text-center font-num text-slate-400">{{ idx + 1 }}</td>
                  <td class="py-2.5 px-3 font-num font-semibold text-slate-800 dark:text-slate-100">{{ nic.name }}</td>
                  <td class="py-2.5 px-3 space-x-1">
                    <span class="px-1.5 py-0.5 rounded text-[11px]"
                      :class="nic.isVirtual ? 'bg-slate-100 text-slate-600 dark:bg-slate-800 dark:text-slate-400' : 'bg-blue-50 text-blue-700 dark:bg-blue-950 dark:text-blue-300'">
                      {{ nic.isVirtual ? '虚拟接口' : '物理网卡' }}
                    </span>
                    <span class="px-1.5 py-0.5 rounded text-[11px]"
                      :class="nic.operState === 'up' ? 'bg-emerald-50 text-emerald-700 dark:bg-emerald-950 dark:text-emerald-300' : 'bg-slate-100 text-slate-500 dark:bg-slate-800'">
                      {{ nic.operState }}
                    </span>
                  </td>
                  <td class="py-2.5 px-3 font-num text-slate-500 dark:text-slate-400">
                    <div v-if="nic.ipv4 && nic.ipv4.length">{{ nic.ipv4.join(', ') }}</div>
                    <div v-if="nic.ipv6 && nic.ipv6.length" class="text-[11px] text-slate-400 truncate max-w-48" :title="nic.ipv6.join(', ')">{{ nic.ipv6[0] }}</div>
                    <div v-if="(!nic.ipv4 || !nic.ipv4.length) && (!nic.ipv6 || !nic.ipv6.length)">—</div>
                    <div v-if="nic.speedMbps > 0" class="text-[11px] text-slate-400">{{ nic.speedMbps }} Mbps</div>
                  </td>
                  <td class="py-2.5 px-3">
                    <input
                      v-model="nic._editAlias"
                      type="text"
                      maxlength="32"
                      placeholder="例如：主公网出口"
                      class="w-36 px-2.5 py-1 rounded border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950"
                    />
                  </td>
                  <td class="py-2.5 px-3">
                    <select
                      v-model="nic._editVisible"
                      class="px-2 py-1 rounded border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950"
                    >
                      <option value="show">始终显示</option>
                      <option value="hide">隐藏</option>
                    </select>
                  </td>
                  <td class="py-2.5 px-3 text-right">
                    <button
                      type="button"
                      class="px-3 py-1 rounded bg-slate-900 text-white dark:bg-slate-100 dark:text-slate-900 hover:opacity-90 cursor-pointer"
                      @click="saveNicRow(nic)"
                    >
                      保存
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <!-- Tab 3: 月度配额与告警推送 -->
        <section v-if="activeTab === 'quota'" class="space-y-6">
          <div class="p-5 rounded-xl border border-slate-200 dark:border-slate-800 space-y-4">
            <div class="flex items-center justify-between">
              <div>
                <h3 class="text-sm font-semibold text-slate-900 dark:text-white">VPS 月度流量包 / 计费周期监控</h3>
                <p class="text-xs text-slate-500 dark:text-slate-400 mt-0.5">自定义账单重置日与计费方向，在首页实时展示当月流量包消耗进度与预计月底用量。</p>
              </div>
              <label class="inline-flex items-center gap-2 text-sm font-medium cursor-pointer">
                <input v-model="quotaForm.enabled" type="checkbox" class="accent-blue-600 w-4 h-4" />
                <span>启用月度配额</span>
              </label>
            </div>

            <div class="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-3 gap-4">
              <div>
                <label class="block text-xs text-slate-500 mb-1">监控目标网卡</label>
                <select v-model="quotaForm.interface" class="w-full px-3 py-2 text-xs rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950">
                  <option value="">跟随默认主网卡</option>
                  <option value="__all__">汇总全部可见网卡</option>
                  <option v-for="nic in adminInterfaces" :key="nic.name" :value="nic.name">{{ nic.name }}</option>
                </select>
              </div>

              <div>
                <label class="block text-xs text-slate-500 mb-1">每月账单重置日 (1–31 号)</label>
                <input v-model.number="quotaForm.resetDay" type="number" min="1" max="31" class="w-full px-3 py-2 text-xs font-num rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950" />
              </div>

              <div>
                <label class="block text-xs text-slate-500 mb-1">流量计费统计方式</label>
                <select v-model="quotaForm.direction" class="w-full px-3 py-2 text-xs rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950">
                  <option value="both">双向合计 (下行 RX + 上行 TX)</option>
                  <option value="tx">仅计出站上行 (TX Only)</option>
                  <option value="rx">仅计入站下行 (RX Only)</option>
                  <option value="max">单向取较大值 max(RX, TX)</option>
                </select>
              </div>

              <div>
                <label class="block text-xs text-slate-500 mb-1">月度总流量限额 (GiB)</label>
                <input v-model.number="quotaLimitGiB" type="number" min="1" step="1" class="w-full px-3 py-2 text-xs font-num rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950" />
              </div>

              <div>
                <label class="block text-xs text-slate-500 mb-1">预警百分比阈值 (%)</label>
                <input v-model.number="quotaForm.warnPercent" type="number" min="1" max="99" class="w-full px-3 py-2 text-xs font-num rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950" />
              </div>
            </div>

            <div>
              <button
                type="button"
                class="px-4 py-2 text-xs font-medium rounded-lg bg-blue-600 hover:bg-blue-700 text-white cursor-pointer"
                :disabled="savingSettings"
                @click="saveSystemAndQuota"
              >
                保存月度配额规则
              </button>
            </div>
          </div>

          <div class="p-5 rounded-xl border border-slate-200 dark:border-slate-800 space-y-4">
            <div class="flex items-center justify-between">
              <div>
                <h3 class="text-sm font-semibold text-slate-900 dark:text-white">超额告警外部推送（密钥脱敏只写不回显）</h3>
                <p class="text-xs text-slate-500 dark:text-slate-400 mt-0.5">支持企业微信机器人、飞书自定义机器人（国内机器首选）、Telegram Bot 与通用 JSON Webhook，自动启用 SSRF 安全校验。</p>
              </div>
              <label class="inline-flex items-center gap-2 text-sm font-medium cursor-pointer">
                <input v-model="alertForm.enabled" type="checkbox" class="accent-blue-600 w-4 h-4" />
                <span>启用告警推送</span>
              </label>
            </div>

            <div class="flex flex-wrap gap-5 text-xs">
              <label class="inline-flex items-center gap-1.5 cursor-pointer">
                <input v-model="alertForm.notifyOnWarn" type="checkbox" class="accent-blue-600" />
                <span>达到预警百分比时通知</span>
              </label>
              <label class="inline-flex items-center gap-1.5 cursor-pointer">
                <input v-model="alertForm.notifyOnLimit" type="checkbox" class="accent-blue-600" />
                <span>达到 100% 限额时通知</span>
              </label>
              <label class="inline-flex items-center gap-1.5 cursor-pointer">
                <input v-model="alertForm.allowPrivateNetwork" type="checkbox" class="accent-blue-600" />
                <span>允许推送至局域网私有 IP Webhook</span>
              </label>
            </div>

            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <!-- 国内首选：企业微信机器人 -->
              <div class="md:col-span-2">
                <label class="block text-xs text-slate-500 mb-1">
                  企业微信群机器人 Webhook URL <span class="text-[11px] text-emerald-600 dark:text-emerald-400">（国内直连推荐）</span>
                  <span v-if="alertMeta.hasWecomWebhook" class="text-emerald-600 dark:text-emerald-400 font-num ml-1">(已存: {{ alertMeta.wecomWebhookMask }})</span>
                </label>
                <div class="flex items-center gap-2">
                  <input v-model="alertForm.wecomWebhookUrl" type="password" :placeholder="alertMeta.hasWecomWebhook ? '留空保持原机器人地址不变' : 'https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=...'" class="flex-1 px-3 py-2 text-xs rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950" />
                  <label v-if="alertMeta.hasWecomWebhook" class="inline-flex items-center gap-1 text-xs text-red-600 whitespace-nowrap cursor-pointer">
                    <input v-model="alertForm.clearWecomWebhook" type="checkbox" /> 清空
                  </label>
                </div>
              </div>

              <!-- 国内首选：飞书自定义机器人 -->
              <div>
                <label class="block text-xs text-slate-500 mb-1">
                  飞书自定义机器人 Webhook URL <span class="text-[11px] text-emerald-600 dark:text-emerald-400">（国内直连推荐）</span>
                  <span v-if="alertMeta.hasFeishuWebhook" class="text-emerald-600 dark:text-emerald-400 font-num ml-1">(已存: {{ alertMeta.feishuWebhookMask }})</span>
                </label>
                <div class="flex items-center gap-2">
                  <input v-model="alertForm.feishuWebhookUrl" type="password" :placeholder="alertMeta.hasFeishuWebhook ? '留空保持原飞书地址不变' : 'https://open.feishu.cn/open-apis/bot/v2/hook/...'" class="flex-1 px-3 py-2 text-xs rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950" />
                  <label v-if="alertMeta.hasFeishuWebhook" class="inline-flex items-center gap-1 text-xs text-red-600 whitespace-nowrap cursor-pointer">
                    <input v-model="alertForm.clearFeishuWebhook" type="checkbox" /> 清空
                  </label>
                </div>
              </div>
              <div>
                <label class="block text-xs text-slate-500 mb-1">
                  飞书机器人签名校验密钥（可选）
                  <span v-if="alertMeta.hasFeishuSecret" class="text-emerald-600 dark:text-emerald-400 font-num ml-1">(已存: {{ alertMeta.feishuSecretMask }})</span>
                </label>
                <div class="flex items-center gap-2">
                  <input v-model="alertForm.feishuSecret" type="password" :placeholder="alertMeta.hasFeishuSecret ? '留空保持原签名密钥不变' : '如飞书机器人开启了签名校验请填入'" class="flex-1 px-3 py-2 text-xs rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950" />
                  <label v-if="alertMeta.hasFeishuSecret" class="inline-flex items-center gap-1 text-xs text-red-600 whitespace-nowrap cursor-pointer">
                    <input v-model="alertForm.clearFeishuSecret" type="checkbox" /> 清空
                  </label>
                </div>
              </div>

              <!-- Telegram Bot -->
              <div>
                <label class="block text-xs text-slate-500 mb-1">
                  Telegram Bot Token
                  <span v-if="alertMeta.hasTelegramBotToken" class="text-emerald-600 dark:text-emerald-400 font-num ml-1">(已存: {{ alertMeta.telegramBotTokenMask }})</span>
                </label>
                <div class="flex items-center gap-2">
                  <input v-model="alertForm.telegramBotToken" type="password" :placeholder="alertMeta.hasTelegramBotToken ? '留空保持原 Token 不变' : '123456:ABC-DEF...'" class="flex-1 px-3 py-2 text-xs rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950" />
                  <label v-if="alertMeta.hasTelegramBotToken" class="inline-flex items-center gap-1 text-xs text-red-600 whitespace-nowrap cursor-pointer">
                    <input v-model="alertForm.clearTelegramBotToken" type="checkbox" /> 清空
                  </label>
                </div>
              </div>
              <div>
                <label class="block text-xs text-slate-500 mb-1">Telegram Chat ID</label>
                <input v-model.trim="alertForm.telegramChatId" type="text" placeholder="例如 -100123456789" class="w-full px-3 py-2 text-xs font-num rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950" />
              </div>

              <!-- 通用自定义 Webhook -->
              <div>
                <label class="block text-xs text-slate-500 mb-1">通用自定义 Webhook URL</label>
                <input v-model.trim="alertForm.webhookUrl" type="url" placeholder="https://example.com/webhook" class="w-full px-3 py-2 text-xs rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950" />
              </div>
              <div>
                <label class="block text-xs text-slate-500 mb-1">
                  通用 Webhook HMAC 签名密钥
                  <span v-if="alertMeta.hasWebhookSecret" class="text-emerald-600 dark:text-emerald-400 font-num ml-1">(已存: {{ alertMeta.webhookSecretMask }})</span>
                </label>
                <div class="flex items-center gap-2">
                  <input v-model="alertForm.webhookSecret" type="password" :placeholder="alertMeta.hasWebhookSecret ? '留空保持原密钥不变' : '可选签名密钥'" class="flex-1 px-3 py-2 text-xs rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950" />
                  <label v-if="alertMeta.hasWebhookSecret" class="inline-flex items-center gap-1 text-xs text-red-600 whitespace-nowrap cursor-pointer">
                    <input v-model="alertForm.clearWebhookSecret" type="checkbox" /> 清空
                  </label>
                </div>
              </div>
            </div>

            <!-- 多机集群统一告警托管（配置一次即覆盖全集群所有节点） -->
            <div class="p-4 rounded-xl bg-slate-50/80 dark:bg-slate-950/60 border border-slate-200/80 dark:border-slate-800 space-y-3 text-xs">
              <div class="flex flex-wrap items-center justify-between gap-2">
                <div>
                  <div class="font-semibold text-slate-800 dark:text-slate-100">多机集群统一告警托管（免去几十台节点逐一配置）</div>
                  <p class="text-[11px] text-slate-500 mt-0.5">开启后由本主控统一巡检全集群节点掉线/恢复、远程流量配额及硬盘/内存高水位，并复用上方 Telegram / Webhook 通道推送。</p>
                </div>
                <label class="inline-flex items-center gap-1.5 font-medium cursor-pointer">
                  <input v-model="alertForm.clusterMonitorEnabled" type="checkbox" class="accent-blue-600 w-4 h-4" />
                  <span>启用集群统一巡检</span>
                </label>
              </div>

              <div v-if="alertForm.clusterMonitorEnabled" class="space-y-3 pt-1">
                <div class="flex flex-wrap gap-5">
                  <label class="inline-flex items-center gap-1.5 cursor-pointer">
                    <input v-model="alertForm.notifyNodeOffline" type="checkbox" class="accent-blue-600" />
                    <span>节点掉线与恢复上线通知</span>
                  </label>
                  <label class="inline-flex items-center gap-1.5 cursor-pointer">
                    <input v-model="alertForm.notifyRemoteQuota" type="checkbox" class="accent-blue-600" />
                    <span>远程节点月度流量配额预警/超限统一推送</span>
                  </label>
                </div>

                <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
                  <div>
                    <label class="block text-[11px] text-slate-500 mb-1">掉线判定宽限 (秒，默认 60)</label>
                    <input v-model.number="alertForm.offlineGraceSec" type="number" min="30" max="3600" class="w-full px-2.5 py-1.5 font-num rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900" />
                  </div>
                  <div>
                    <label class="block text-[11px] text-slate-500 mb-1">硬盘高水位预警 (% ，0 关闭)</label>
                    <input v-model.number="alertForm.diskWarnPercent" type="number" min="0" max="99" class="w-full px-2.5 py-1.5 font-num rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900" />
                  </div>
                  <div>
                    <label class="block text-[11px] text-slate-500 mb-1">内存高水位预警 (% ，0 关闭)</label>
                    <input v-model.number="alertForm.memWarnPercent" type="number" min="0" max="99" class="w-full px-2.5 py-1.5 font-num rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900" />
                  </div>
                </div>
              </div>
            </div>

            <div class="flex flex-wrap items-center gap-3">
              <button
                type="button"
                class="px-4 py-2 text-xs font-medium rounded-lg bg-blue-600 hover:bg-blue-700 text-white cursor-pointer"
                @click="saveAlerts"
              >
                保存告警配置
              </button>
              <button
                type="button"
                class="px-4 py-2 text-xs font-medium rounded-lg border border-slate-300 dark:border-slate-700 hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer"
                :disabled="testingAlert"
                @click="triggerTestAlert"
              >
                {{ testingAlert ? '正在发送…' : '发送测试通知' }}
              </button>
            </div>
          </div>
        </section>

        <!-- Tab 4: 备份与还原中心 -->
        <section v-if="activeTab === 'backups'" class="space-y-5">
          <div class="p-4 rounded-xl border border-slate-200 dark:border-slate-800 space-y-3">
            <div class="flex flex-wrap items-center justify-between gap-3">
              <div class="flex flex-wrap items-center gap-2">
                <input
                  v-model.trim="backupNote"
                  type="text"
                  maxlength="64"
                  placeholder="可选备份备注（如：升级前快照）"
                  class="w-56 px-3 py-1.5 text-xs rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950"
                />
                <button
                  type="button"
                  class="px-4 py-1.5 text-xs font-medium rounded-lg bg-blue-600 hover:bg-blue-700 text-white cursor-pointer disabled:opacity-50"
                  :disabled="backupBusy"
                  @click="createBackupNow"
                >
                  {{ backupBusy ? '处理中…' : '+ 一键创建备份快照' }}
                </button>
              </div>

              <div class="flex flex-wrap items-center gap-2">
                <label class="px-3.5 py-1.5 text-xs font-medium rounded-lg border border-blue-200 dark:border-blue-800 bg-blue-50/70 dark:bg-blue-950/50 text-blue-700 dark:text-blue-300 hover:opacity-90 cursor-pointer">
                  上传本地备份还原 (.tar.gz)
                  <input type="file" accept=".tar.gz,.tgz,application/gzip" class="hidden" @change="onSelectUploadBackup" />
                </label>
                <a
                  href="/api/v1/admin/config/export"
                  class="px-3 py-1.5 text-xs rounded-lg border border-slate-200 dark:border-slate-700 hover:bg-slate-100 dark:hover:bg-slate-800"
                >
                  导出配置 JSON
                </a>
                <label class="px-3 py-1.5 text-xs rounded-lg border border-slate-200 dark:border-slate-700 hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer">
                  导入配置 JSON
                  <input type="file" accept=".json,application/json" class="hidden" @change="onImportConfigFile" />
                </label>
              </div>
            </div>
            <p class="text-[11px] text-slate-500 dark:text-slate-400">
              安全保障：所有备份均使用 SQLite <code class="font-num">VACUUM INTO</code> 生成一致性快照并附带 SHA-256 校验；执行任何还原前均先验证 <code class="font-num">PRAGMA integrity_check</code>、自动留存保护快照，若还原异常自动无损回滚现网数据。
            </p>
          </div>

          <!-- 二次确认框（快照列表还原或上传文件还原） -->
          <div v-if="pendingRestore" class="p-4 rounded-xl border-2 border-amber-400 dark:border-amber-600 bg-amber-50/80 dark:bg-amber-950/40 space-y-3">
            <div class="text-sm font-semibold text-amber-900 dark:text-amber-200">
              ⚠️ 确认执行数据库还原？
            </div>
            <p class="text-xs text-amber-800 dark:text-amber-300 leading-relaxed">
              即将从 <strong class="font-num">{{ pendingRestore.label }}</strong> 恢复数据。系统会先对目标归档执行完整性与表结构校验，并自动创建一份当前数据的 <code class="font-num">pre-restore</code> 保护快照后原子切换数据库。
            </p>
            <div class="flex items-center gap-2.5">
              <button
                type="button"
                class="px-4 py-1.5 text-xs font-semibold rounded-lg bg-amber-600 hover:bg-amber-700 text-white cursor-pointer"
                :disabled="backupBusy"
                @click="confirmExecuteRestore"
              >
                {{ backupBusy ? '正在校验并还原…' : '确认无误，立即还原' }}
              </button>
              <button
                type="button"
                class="px-3 py-1.5 text-xs rounded-lg border border-amber-300 dark:border-amber-700 text-amber-900 dark:text-amber-200 cursor-pointer"
                :disabled="backupBusy"
                @click="pendingRestore = null"
              >
                取消
              </button>
            </div>
          </div>

          <!-- 历史快照表格（带序号列） -->
          <div class="overflow-x-auto rounded-xl border border-slate-200 dark:border-slate-800">
            <table class="w-full text-xs text-left border-collapse">
              <thead class="bg-slate-100/80 dark:bg-slate-900/80 text-slate-500 dark:text-slate-400">
                <tr>
                  <th class="py-2.5 px-3 w-12 text-center">#</th>
                  <th class="py-2.5 px-3">快照文件名 / 备注</th>
                  <th class="py-2.5 px-3">类型</th>
                  <th class="py-2.5 px-3">创建时间</th>
                  <th class="py-2.5 px-3 text-right">大小</th>
                  <th class="py-2.5 px-3">SHA-256 校验摘要</th>
                  <th class="py-2.5 px-3 text-right">操作</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-slate-200/70 dark:divide-slate-800">
                <tr v-if="backups.length === 0">
                  <td colspan="7" class="py-8 text-center text-slate-400">暂无备份快照，点击上方“一键创建备份快照”立即生成</td>
                </tr>
                <tr v-for="(b, idx) in backups" :key="b.name" class="hover:bg-slate-50 dark:hover:bg-slate-800/40">
                  <td class="py-2.5 px-3 text-center font-num text-slate-400">{{ idx + 1 }}</td>
                  <td class="py-2.5 px-3">
                    <div class="font-num font-medium text-slate-800 dark:text-slate-100">{{ b.name }}</div>
                    <div v-if="b.note" class="text-[11px] text-slate-500 mt-0.5">{{ b.note }}</div>
                  </td>
                  <td class="py-2.5 px-3">
                    <span class="px-2 py-0.5 rounded-full text-[11px]"
                      :class="b.kind === 'pre_restore'
                        ? 'bg-amber-50 text-amber-700 dark:bg-amber-950 dark:text-amber-300'
                        : 'bg-emerald-50 text-emerald-700 dark:bg-emerald-950 dark:text-emerald-300'">
                      {{ b.kind === 'pre_restore' ? '还原前保护快照' : '手动备份' }}
                    </span>
                  </td>
                  <td class="py-2.5 px-3 font-num text-slate-500 whitespace-nowrap">{{ formatISO(b.createdAt) }}</td>
                  <td class="py-2.5 px-3 text-right font-num whitespace-nowrap">{{ formatBytes(b.sizeBytes) }}</td>
                  <td class="py-2.5 px-3 font-num">
                    <button
                      v-if="b.sha256"
                      type="button"
                      class="text-slate-500 hover:text-blue-600 underline decoration-dotted cursor-pointer"
                      title="点击复制完整 SHA-256"
                      @click="copyHash(b.sha256)"
                    >
                      {{ b.sha256.slice(0, 12) }}…
                    </button>
                    <span v-else class="text-slate-400">—</span>
                  </td>
                  <td class="py-2.5 px-3 text-right space-x-2 whitespace-nowrap">
                    <a
                      :href="`/api/v1/admin/backups/${encodeURIComponent(b.name)}/download`"
                      class="px-2.5 py-1 rounded bg-blue-50 text-blue-700 dark:bg-blue-950 dark:text-blue-300 hover:opacity-80 inline-block"
                    >
                      下载到本地
                    </a>
                    <button
                      type="button"
                      class="px-2.5 py-1 rounded bg-amber-50 text-amber-700 dark:bg-amber-950 dark:text-amber-300 hover:opacity-80 cursor-pointer"
                      @click="askRestoreExisting(b.name)"
                    >
                      一键还原
                    </button>
                    <button
                      type="button"
                      class="px-2.5 py-1 rounded bg-red-50 text-red-600 dark:bg-red-950 dark:text-red-400 hover:opacity-80 cursor-pointer"
                      @click="deleteBackupItem(b.name)"
                    >
                      删除
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <!-- 独立确认重置区 -->
          <details class="p-4 rounded-xl border border-red-200/70 dark:border-red-900/60 bg-red-50/20 dark:bg-red-950/10">
            <summary class="text-xs font-semibold text-red-600 dark:text-red-400 cursor-pointer">
              高级维护：重置内置 SQLite 历史流量统计（不影响系统 /var/lib/vnstat）
            </summary>
            <div class="mt-3 flex flex-wrap items-end gap-3 text-xs">
              <div>
                <label class="block text-slate-500 mb-1">选择重置范围</label>
                <select v-model="resetTarget" class="px-2.5 py-1.5 rounded border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950">
                  <option value="__all__">全部内置网卡统计</option>
                  <option v-for="nic in adminInterfaces" :key="nic.name" :value="nic.name">仅网卡 {{ nic.name }}</option>
                </select>
              </div>
              <div>
                <label class="block text-slate-500 mb-1">输入确认词 <code class="font-bold">RESET</code></label>
                <input v-model.trim="resetConfirmWord" type="text" placeholder="RESET" class="w-32 px-2.5 py-1.5 font-num rounded border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950" />
              </div>
              <button
                type="button"
                :disabled="resetConfirmWord !== 'RESET' || backupBusy"
                class="px-3.5 py-1.5 rounded bg-red-600 text-white disabled:opacity-40 cursor-pointer"
                @click="executeResetTraffic"
              >
                先备份并执行重置
              </button>
            </div>
          </details>
        </section>

        <!-- Tab 4.5: 节点与分组管理（分组改名/删除 + 清理重复或未安装节点 + 主控多架构分发包缓存） -->
        <section v-if="activeTab === 'cluster'" class="space-y-6">
          <div class="p-5 rounded-xl border border-slate-200 dark:border-slate-800 space-y-3">
            <div class="flex flex-wrap items-center justify-between gap-2">
              <div>
                <h3 class="text-sm font-semibold text-slate-900 dark:text-white">主控多架构安装包分发缓存（v{{ distCacheVersion || '—' }}）</h3>
                <p class="text-xs text-slate-500 dark:text-slate-400 mt-0.5">主控自动在本地保留 <code class="font-num">linux/amd64</code> 与 <code class="font-num">linux/arm64</code> 静态二进制安装包，方便不同架构的国内节点直接从主控满速安装与升级。</p>
              </div>
              <button
                type="button"
                class="px-3.5 py-1.5 text-xs font-medium rounded-lg bg-blue-600 hover:bg-blue-700 text-white disabled:opacity-50 cursor-pointer"
                :disabled="distPrewarming"
                @click="prewarmDistCacheNow"
              >
                {{ distPrewarming ? '正在同步全架构包…' : '同步全架构安装包' }}
              </button>
            </div>
            <div class="flex flex-wrap gap-3 text-xs">
              <div
                v-for="item in distCacheItems"
                :key="item.arch"
                class="px-3 py-2 rounded-lg border flex items-center gap-2.5"
                :class="item.cached
                  ? 'border-emerald-200 bg-emerald-50/60 dark:border-emerald-900/60 dark:bg-emerald-950/30'
                  : 'border-amber-200 bg-amber-50/60 dark:border-amber-900/60 dark:bg-amber-950/30'"
              >
                <span class="w-2 h-2 rounded-full" :class="item.cached ? 'bg-emerald-500' : 'bg-amber-500'" />
                <span class="font-num font-semibold text-slate-800 dark:text-slate-100">linux/{{ item.arch }}</span>
                <span class="text-[11px] text-slate-500 dark:text-slate-400">
                  {{ item.cached ? `已就绪 · ${(item.sizeBytes / 1024 / 1024).toFixed(2)} MiB` : '未缓存（点击右侧同步）' }}
                </span>
              </div>
            </div>
          </div>

          <div class="p-5 rounded-xl border border-slate-200 dark:border-slate-800 space-y-3.5">
            <div class="flex items-center justify-between gap-2">
              <div>
                <h3 class="text-sm font-semibold text-slate-900 dark:text-white">节点分组管理</h3>
                <p class="text-xs text-slate-500 dark:text-slate-400 mt-0.5">支持批量重命名分组或删除分组（删除分组仅清空节点分组归属，不会删除服务器节点）。</p>
              </div>
              <button type="button" class="px-3 py-1.5 text-xs rounded-lg border border-slate-200 dark:border-slate-700 hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer" @click="loadClusterAdminNodes">
                刷新列表
              </button>
            </div>

            <div v-if="clusterGroups.length === 0" class="text-xs text-slate-400 py-3">
              当前暂无自定义被控节点分组（可在下方节点列表中为节点指定分组标签）。
            </div>
            <div v-else class="overflow-x-auto rounded-xl border border-slate-200 dark:border-slate-800">
              <table class="w-full text-xs text-left border-collapse">
                <thead class="bg-slate-100/80 dark:bg-slate-900/80 text-slate-500 dark:text-slate-400">
                  <tr>
                    <th class="py-2 px-3 w-12 text-center">#</th>
                    <th class="py-2 px-3">当前分组名</th>
                    <th class="py-2 px-3">机器数量</th>
                    <th class="py-2 px-3">修改为新名称</th>
                    <th class="py-2 px-3 text-right">操作</th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-slate-200/70 dark:divide-slate-800">
                  <tr v-for="(grp, idx) in clusterGroups" :key="grp.name">
                    <td class="py-2 px-3 text-center font-num text-slate-400">{{ idx + 1 }}</td>
                    <td class="py-2 px-3 font-semibold text-slate-800 dark:text-slate-100">{{ grp.name }}</td>
                    <td class="py-2 px-3 font-num text-slate-600 dark:text-slate-300">{{ grp.count }} 台</td>
                    <td class="py-2 px-3">
                      <input
                        v-model.trim="grp._newName"
                        type="text"
                        maxlength="32"
                        class="w-44 px-2.5 py-1 rounded border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950"
                      />
                    </td>
                    <td class="py-2 px-3 text-right space-x-2 whitespace-nowrap">
                      <button
                        type="button"
                        class="px-3 py-1 rounded bg-blue-600 hover:bg-blue-700 text-white cursor-pointer"
                        @click="renameClusterGroupRow(grp)"
                      >
                        保存修改
                      </button>
                      <button
                        type="button"
                        class="px-3 py-1 rounded bg-red-50 text-red-600 dark:bg-red-950 dark:text-red-400 hover:opacity-80 cursor-pointer"
                        @click="deleteClusterGroupRow(grp)"
                      >
                        删除分组
                      </button>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <div class="p-5 rounded-xl border border-slate-200 dark:border-slate-800 space-y-3.5">
            <div>
              <h3 class="text-sm font-semibold text-slate-900 dark:text-white">已注册被控节点列表（含未安装 / 离线节点）</h3>
              <p class="text-xs text-slate-500 dark:text-slate-400 mt-0.5">可直接修改节点名称、分组与备注，或一键删除重复添加、尚未安装的残留节点。</p>
            </div>

            <div class="overflow-x-auto rounded-xl border border-slate-200 dark:border-slate-800">
              <table class="w-full text-xs text-left border-collapse">
                <thead class="bg-slate-100/80 dark:bg-slate-900/80 text-slate-500 dark:text-slate-400">
                  <tr>
                    <th class="py-2.5 px-3 w-12 text-center">#</th>
                    <th class="py-2.5 px-3">状态 / 版本</th>
                    <th class="py-2.5 px-3">公网 IP / 地址</th>
                    <th class="py-2.5 px-3">显示名称</th>
                    <th class="py-2.5 px-3">所属分组</th>
                    <th class="py-2.5 px-3">备注</th>
                    <th class="py-2.5 px-3 text-right">操作</th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-slate-200/70 dark:divide-slate-800">
                  <tr v-if="clusterNodes.length === 0">
                    <td colspan="7" class="py-8 text-center text-slate-400">当前暂无已注册的远程被控节点</td>
                  </tr>
                  <tr v-for="(node, idx) in clusterNodes" :key="node.id" class="hover:bg-slate-50 dark:hover:bg-slate-800/40">
                    <td class="py-2.5 px-3 text-center font-num text-slate-400">{{ idx + 1 }}</td>
                    <td class="py-2.5 px-3 whitespace-nowrap">
                      <span class="px-2 py-0.5 rounded-full text-[11px]"
                        :class="node.online
                          ? 'bg-emerald-50 text-emerald-700 dark:bg-emerald-950 dark:text-emerald-300'
                          : (node.lastSeen ? 'bg-red-50 text-red-600 dark:bg-red-950 dark:text-red-400' : 'bg-amber-50 text-amber-700 dark:bg-amber-950 dark:text-amber-300')">
                        {{ node.online ? '在线' : (node.lastSeen ? '离线' : '未安装/待接入') }}
                      </span>
                      <div class="font-num text-[11px] text-slate-400 mt-0.5">{{ node.version ? `v${node.version}` : '—' }}</div>
                    </td>
                    <td class="py-2.5 px-3 font-num text-[11px] text-slate-500">
                      {{ node.endpointIp || (node.ipv4 && node.ipv4[0]) || '—' }}
                    </td>
                    <td class="py-2.5 px-3">
                      <input v-model.trim="node._editName" type="text" maxlength="48" class="w-32 px-2 py-1 rounded border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950" />
                    </td>
                    <td class="py-2.5 px-3">
                      <input v-model.trim="node._editGroup" type="text" maxlength="32" placeholder="留空为未分组" class="w-28 px-2 py-1 rounded border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950" />
                    </td>
                    <td class="py-2.5 px-3">
                      <input v-model.trim="node._editRemark" type="text" maxlength="80" class="w-32 px-2 py-1 rounded border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950" />
                    </td>
                    <td class="py-2.5 px-3 text-right space-x-1.5 whitespace-nowrap">
                      <button type="button" class="px-2.5 py-1 rounded bg-slate-900 text-white dark:bg-slate-100 dark:text-slate-900 cursor-pointer" @click="saveClusterNodeRow(node)">
                        保存
                      </button>
                      <button type="button" class="px-2.5 py-1 rounded bg-red-50 text-red-600 dark:bg-red-950 dark:text-red-400 hover:opacity-80 cursor-pointer" @click="deleteClusterNodeRow(node)">
                        删除
                      </button>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </section>

        <!-- Tab 5: 安全参数与倒序系统日志 -->
        <section v-if="activeTab === 'security'" class="space-y-6">
          <div class="grid grid-cols-1 lg:grid-cols-2 gap-5">
            <div class="p-5 rounded-xl border border-slate-200 dark:border-slate-800 space-y-3.5">
              <h3 class="text-sm font-semibold text-slate-900 dark:text-white">站点保护与存储保留上限</h3>

              <div>
                <label class="block text-xs text-slate-500 mb-1">自定义面板标题</label>
                <input v-model.trim="systemForm.siteTitle" type="text" maxlength="48" class="w-full px-3 py-1.5 text-xs rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950" />
              </div>

              <div>
                <label class="block text-xs text-slate-500 mb-1">主控公网接入地址（多机管理生成一键接入命令使用，留空自动识别当前访问域名/IP）</label>
                <input v-model.trim="systemForm.publicHubUrl" type="url" placeholder="https://monitor.example.com 或 http://[IPv6]:10089" class="w-full px-3 py-1.5 text-xs font-num rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950" />
              </div>

              <label class="inline-flex items-center gap-2 text-xs font-medium text-slate-800 dark:text-slate-200 cursor-pointer">
                <input v-model="systemForm.requireLoginForView" type="checkbox" class="accent-blue-600 w-4 h-4" />
                <span>开启全站密码保护（未登录访客禁止查看前台流量看板）</span>
              </label>

              <div class="grid grid-cols-3 gap-2.5 pt-1">
                <div>
                  <label class="block text-[11px] text-slate-500 mb-1">5分钟粒度保留(天)</label>
                  <input v-model.number="systemForm.retention5mDays" type="number" min="1" max="90" class="w-full px-2.5 py-1.5 text-xs font-num rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950" />
                </div>
                <div>
                  <label class="block text-[11px] text-slate-500 mb-1">小时粒度保留(天)</label>
                  <input v-model.number="systemForm.retentionHourlyDays" type="number" min="7" max="1095" class="w-full px-2.5 py-1.5 text-xs font-num rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950" />
                </div>
                <div>
                  <label class="block text-[11px] text-slate-500 mb-1">按日粒度保留(天)</label>
                  <input v-model.number="systemForm.retentionDailyDays" type="number" min="30" max="36525" class="w-full px-2.5 py-1.5 text-xs font-num rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950" />
                </div>
              </div>

              <div class="grid grid-cols-2 gap-2.5">
                <div>
                  <label class="block text-[11px] text-slate-500 mb-1">手动备份保留上限(份)</label>
                  <input v-model.number="systemForm.maxBackups" type="number" min="1" max="200" class="w-full px-2.5 py-1.5 text-xs font-num rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950" />
                </div>
                <div>
                  <label class="block text-[11px] text-slate-500 mb-1">保护快照保留上限(份)</label>
                  <input v-model.number="systemForm.maxProtectSnapshots" type="number" min="1" max="100" class="w-full px-2.5 py-1.5 text-xs font-num rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950" />
                </div>
              </div>

              <button
                type="button"
                class="px-4 py-2 text-xs font-medium rounded-lg bg-blue-600 hover:bg-blue-700 text-white cursor-pointer"
                @click="saveSystemAndQuota"
              >
                保存站点与保留参数
              </button>
            </div>

            <form class="p-5 rounded-xl border border-slate-200 dark:border-slate-800 space-y-3.5" @submit.prevent="changePassword">
              <h3 class="text-sm font-semibold text-slate-900 dark:text-white">修改管理员登录密码</h3>
              <div>
                <label class="block text-xs text-slate-500 mb-1">当前密码</label>
                <input v-model="pwdForm.currentPassword" type="password" required class="w-full px-3 py-1.5 text-xs rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950" />
              </div>
              <div>
                <label class="block text-xs text-slate-500 mb-1">新密码（至少 6 位）</label>
                <input v-model="pwdForm.newPassword" type="password" required minlength="6" class="w-full px-3 py-1.5 text-xs rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950" />
              </div>
              <div>
                <label class="block text-xs text-slate-500 mb-1">确认新密码</label>
                <input v-model="pwdForm.confirmPassword" type="password" required minlength="6" class="w-full px-3 py-1.5 text-xs rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950" />
              </div>
              <button type="submit" class="px-4 py-2 text-xs font-medium rounded-lg bg-slate-900 text-white dark:bg-slate-100 dark:text-slate-900 cursor-pointer">
                更新管理员密码
              </button>
            </form>
          </div>

          <!-- 倒序系统日志与告警日志查看器 -->
          <div class="p-5 rounded-xl border border-slate-200 dark:border-slate-800 space-y-3">
            <div class="flex flex-wrap items-center justify-between gap-2">
              <div class="flex items-center gap-2">
                <h3 class="text-sm font-semibold text-slate-900 dark:text-white">后台运行日志（最新在最顶部）</h3>
                <div class="inline-flex rounded-lg border border-slate-200 dark:border-slate-700 overflow-hidden text-xs">
                  <button
                    type="button"
                    class="px-2.5 py-1 cursor-pointer"
                    :class="logChannel === 'system' ? 'bg-blue-600 text-white' : 'bg-transparent text-slate-600 dark:text-slate-300'"
                    @click="logChannel = 'system'; loadLogs()"
                  >
                    系统通道 (system)
                  </button>
                  <button
                    type="button"
                    class="px-2.5 py-1 cursor-pointer"
                    :class="logChannel === 'alert' ? 'bg-blue-600 text-white' : 'bg-transparent text-slate-600 dark:text-slate-300'"
                    @click="logChannel = 'alert'; loadLogs()"
                  >
                    告警通道 (alert)
                  </button>
                </div>
              </div>

              <div class="flex flex-wrap items-center gap-2 text-xs">
                <select v-model="logLevel" class="px-2 py-1 rounded border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950" @change="loadLogs">
                  <option value="ALL">全部级别</option>
                  <option value="INFO">INFO</option>
                  <option value="WARN">WARN</option>
                  <option value="ERROR">ERROR</option>
                </select>
                <input
                  v-model.trim="logQuery"
                  type="text"
                  placeholder="搜索日志内容..."
                  class="w-44 px-2.5 py-1 rounded border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950"
                  @keyup.enter="loadLogs"
                />
                <button type="button" class="px-2.5 py-1 rounded border border-slate-200 dark:border-slate-700 hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer" @click="loadLogs">
                  刷新
                </button>
                <button type="button" class="px-2.5 py-1 rounded border border-slate-200 dark:border-slate-700 hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer" @click="copyLogs">
                  复制日志
                </button>
              </div>
            </div>

            <div class="max-h-72 overflow-y-auto rounded-lg bg-slate-950 text-slate-200 p-3 font-num text-xs space-y-1">
              <div v-if="logs.length === 0" class="text-slate-500 py-4 text-center">当前筛选条件下暂无日志</div>
              <div v-for="(item, idx) in logs" :key="idx" class="leading-relaxed break-all">
                <span class="text-slate-500">[{{ formatISO(item.timestamp) }}]</span>
                <span class="ml-1.5 font-semibold"
                  :class="item.level === 'ERROR' ? 'text-red-400' : (item.level === 'WARN' ? 'text-amber-400' : 'text-emerald-400')">
                  [{{ item.level }}]
                </span>
                <span class="ml-1.5 text-slate-200">{{ item.message }}</span>
              </div>
            </div>
          </div>
        </section>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, reactive, computed, onMounted } from 'vue';
import { formatBytes, formatUptime, copyTextSafe, apiRequest } from '../utils/format';

defineProps({
  version: { type: String, default: '' }
});

const emit = defineEmits(['close', 'updated', 'logged-out']);

const tabs = [
  { key: 'overview', label: '概览与数据源' },
  { key: 'cluster', label: '节点与分组' },
  { key: 'interfaces', label: '网卡管理' },
  { key: 'quota', label: '月度配额与告警' },
  { key: 'backups', label: '备份与还原' },
  { key: 'security', label: '安全与系统日志' }
];

const sourceModeOptions = [
  {
    value: 'hybrid',
    title: 'Hybrid 智能融合（推荐）',
    desc: '后台持续用内核秒级自采写入 SQLite；若系统安装了 vnstat 则自动融合其历史账本，无 vnstat 时零报错独立运行。'
  },
  {
    value: 'sqlite',
    title: '纯内置 SQLite 自采',
    desc: '100% 脱离外部命令，完全使用内置轻量内核采集与本地 SQLite 数据库，适合全新部署与极简 Docker 环境。'
  },
  {
    value: 'vnstat',
    title: '系统 vnstat 直读',
    desc: '直接读取宿主机或挂载目录的 vnstat 数据库历史记录，适合已有长期 vnstat 守护进程且仅需面板展示的场景。'
  }
];

const activeTab = ref('overview');
const notice = reactive({ type: 'ok', text: '' });

const overview = reactive({
  memorySysBytes: 0,
  heapAllocBytes: 0,
  goroutines: 0,
  dbSizeBytes: 0,
  uptimeSeconds: 0,
  platform: '',
  arch: '',
  goVersion: '',
  dataDir: '',
  vnstatAvailable: false,
  vnstatVersion: ''
});

const systemForm = reactive({
  siteTitle: 'FlowMaster 流量监控',
  requireLoginForView: false,
  dataSourceMode: 'hybrid',
  hideVirtualInterfaces: true,
  defaultInterface: '',
  publicHubUrl: '',
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
    const num = Math.max(1, Number(val || 1));
    quotaForm.monthlyLimitBytes = Math.round(num * 1024 * 1024 * 1024);
  }
});

const alertMeta = reactive({
  hasWebhookSecret: false,
  webhookSecretMask: '',
  hasTelegramBotToken: false,
  telegramBotTokenMask: '',
  hasWecomWebhook: false,
  wecomWebhookMask: '',
  hasFeishuWebhook: false,
  feishuWebhookMask: '',
  hasFeishuSecret: false,
  feishuSecretMask: ''
});

const alertForm = reactive({
  enabled: false,
  webhookUrl: '',
  webhookSecret: '',
  clearWebhookSecret: false,
  telegramBotToken: '',
  clearTelegramBotToken: false,
  telegramChatId: '',
  wecomWebhookUrl: '',
  clearWecomWebhook: false,
  feishuWebhookUrl: '',
  clearFeishuWebhook: false,
  feishuSecret: '',
  clearFeishuSecret: false,
  allowPrivateNetwork: false,
  notifyOnWarn: true,
  notifyOnLimit: true,
  clusterMonitorEnabled: false,
  notifyNodeOffline: true,
  offlineGraceSec: 60,
  notifyRemoteQuota: true,
  diskWarnPercent: 90,
  memWarnPercent: 90
});

const adminInterfaces = ref([]);
const clusterNodes = ref([]);
const clusterGroups = ref([]);
const distCacheVersion = ref('');
const distCacheItems = ref([]);
const distPrewarming = ref(false);
const backups = ref([]);
const backupNote = ref('');
const backupBusy = ref(false);
const pendingRestore = ref(null);
const resetTarget = ref('__all__');
const resetConfirmWord = ref('');

const savingSettings = ref(false);
const importingVnstat = ref(false);
const testingAlert = ref(false);

const pwdForm = reactive({
  currentPassword: '',
  newPassword: '',
  confirmPassword: ''
});

const logChannel = ref('system');
const logLevel = ref('ALL');
const logQuery = ref('');
const logs = ref([]);

function showNotice(text, type = 'ok') {
  notice.type = type;
  notice.text = text;
}

function formatISO(str) {
  if (!str) return '—';
  const d = new Date(str);
  return Number.isNaN(d.getTime()) ? str : d.toLocaleString('zh-CN', { hour12: false });
}

async function loadOverview() {
  const data = await apiRequest('/api/v1/admin/overview');
  Object.assign(overview, data);
}

async function loadSettings() {
  const data = await apiRequest('/api/v1/admin/settings');
  if (data.system) Object.assign(systemForm, data.system);
  if (data.quota) Object.assign(quotaForm, data.quota);
  if (data.alerts) {
    alertForm.enabled = data.alerts.enabled;
    alertForm.webhookUrl = data.alerts.webhookUrl || '';
    alertForm.webhookSecret = '';
    alertForm.clearWebhookSecret = false;
    alertForm.telegramBotToken = '';
    alertForm.clearTelegramBotToken = false;
    alertForm.telegramChatId = data.alerts.telegramChatId || '';
    alertForm.wecomWebhookUrl = '';
    alertForm.clearWecomWebhook = false;
    alertForm.feishuWebhookUrl = '';
    alertForm.clearFeishuWebhook = false;
    alertForm.feishuSecret = '';
    alertForm.clearFeishuSecret = false;
    alertForm.allowPrivateNetwork = data.alerts.allowPrivateNetwork;
    alertForm.notifyOnWarn = data.alerts.notifyOnWarn;
    alertForm.notifyOnLimit = data.alerts.notifyOnLimit;
    alertForm.clusterMonitorEnabled = Boolean(data.alerts.clusterMonitorEnabled);
    alertForm.notifyNodeOffline = data.alerts.notifyNodeOffline !== false;
    alertForm.offlineGraceSec = data.alerts.offlineGraceSec || 60;
    alertForm.notifyRemoteQuota = data.alerts.notifyRemoteQuota !== false;
    alertForm.diskWarnPercent = data.alerts.diskWarnPercent ?? 90;
    alertForm.memWarnPercent = data.alerts.memWarnPercent ?? 90;
    alertMeta.hasWebhookSecret = data.alerts.hasWebhookSecret;
    alertMeta.webhookSecretMask = data.alerts.webhookSecretMask || '';
    alertMeta.hasTelegramBotToken = data.alerts.hasTelegramBotToken;
    alertMeta.telegramBotTokenMask = data.alerts.telegramBotTokenMask || '';
    alertMeta.hasWecomWebhook = data.alerts.hasWecomWebhook;
    alertMeta.wecomWebhookMask = data.alerts.wecomWebhookMask || '';
    alertMeta.hasFeishuWebhook = data.alerts.hasFeishuWebhook;
    alertMeta.feishuWebhookMask = data.alerts.feishuWebhookMask || '';
    alertMeta.hasFeishuSecret = data.alerts.hasFeishuSecret;
    alertMeta.feishuSecretMask = data.alerts.feishuSecretMask || '';
  }
}

async function loadAdminInterfaces() {
  const data = await apiRequest('/api/v1/admin/interfaces');
  adminInterfaces.value = (data.interfaces || []).map(item => ({
    ...item,
    _editAlias: item.alias || '',
    _editVisible: item.visible ? 'show' : 'hide'
  }));
}

async function loadBackups() {
  const data = await apiRequest('/api/v1/admin/backups');
  backups.value = data.backups || [];
}

async function loadLogs() {
  const params = new URLSearchParams({
    channel: logChannel.value,
    level: logLevel.value,
    q: logQuery.value,
    limit: '200'
  });
  const data = await apiRequest(`/api/v1/admin/logs?${params.toString()}`);
  logs.value = data.entries || [];
}

async function loadDistCacheStatus() {
  try {
    const data = await apiRequest('/api/v1/admin/cluster/dist/status');
    distCacheVersion.value = data.version || '';
    distCacheItems.value = data.items || [];
  } catch {
    // 忽略状态读取错误
  }
}

async function prewarmDistCacheNow() {
  distPrewarming.value = true;
  try {
    const res = await apiRequest('/api/v1/admin/cluster/dist/prewarm', { method: 'POST', body: {} });
    distCacheVersion.value = res.version || distCacheVersion.value;
    distCacheItems.value = res.items || distCacheItems.value;
    showNotice(res.message || '多架构安装包已缓存就绪');
  } catch (err) {
    await loadDistCacheStatus();
    showNotice(err.message, 'error');
  } finally {
    distPrewarming.value = false;
  }
}

async function loadClusterAdminNodes() {
  const [data] = await Promise.all([
    apiRequest('/api/v1/cluster/nodes'),
    loadDistCacheStatus()
  ]);
  const remotes = (data.nodes || []).filter(n => !n.isLocal);
  clusterNodes.value = remotes.map(n => ({
    ...n,
    _editName: n.name || '',
    _editGroup: n.groupName || '',
    _editRemark: n.remark || ''
  }));
  const grpMap = new Map();
  for (const n of remotes) {
    const g = String(n.groupName || '').trim();
    if (g) grpMap.set(g, (grpMap.get(g) || 0) + 1);
  }
  clusterGroups.value = [...grpMap.entries()].map(([name, count]) => ({
    name,
    count,
    _newName: name
  }));
}

async function renameClusterGroupRow(grp) {
  const nextName = String(grp._newName || '').trim();
  if (!nextName) {
    showNotice('新分组名不能为空', 'error');
    return;
  }
  if (nextName === grp.name) return;
  try {
    const res = await apiRequest('/api/v1/admin/cluster/groups', {
      method: 'PUT',
      body: { oldName: grp.name, newName: nextName }
    });
    showNotice(res.message || '分组已修改');
    await loadClusterAdminNodes();
    emit('updated');
  } catch (err) {
    showNotice(err.message, 'error');
  }
}

async function deleteClusterGroupRow(grp) {
  if (!window.confirm(`确认删除分组「${grp.name}」吗？\n\n该分组下的 ${grp.count} 台机器将自动变为“未分组”，不会被删除。`)) return;
  try {
    const res = await apiRequest(`/api/v1/admin/cluster/groups/${encodeURIComponent(grp.name)}`, { method: 'DELETE' });
    showNotice(res.message || '分组已删除');
    await loadClusterAdminNodes();
    emit('updated');
  } catch (err) {
    showNotice(err.message, 'error');
  }
}

async function saveClusterNodeRow(node) {
  if (!node._editName) {
    showNotice('节点显示名称不能为空', 'error');
    return;
  }
  try {
    await apiRequest(`/api/v1/admin/cluster/nodes/${encodeURIComponent(node.id)}`, {
      method: 'PUT',
      body: {
        name: node._editName,
        groupName: node._editGroup,
        remark: node._editRemark
      }
    });
    showNotice(`节点「${node._editName}」信息已保存`);
    await loadClusterAdminNodes();
    emit('updated');
  } catch (err) {
    showNotice(err.message, 'error');
  }
}

async function deleteClusterNodeRow(node) {
  if (!window.confirm(`确认从主控删除节点「${node.name}」吗？\n\n（仅移除主控记录，不影响目标机器本地服务）`)) return;
  try {
    await apiRequest(`/api/v1/admin/cluster/nodes/${encodeURIComponent(node.id)}`, { method: 'DELETE' });
    showNotice(`已移除节点「${node.name}」`);
    await loadClusterAdminNodes();
    emit('updated');
  } catch (err) {
    showNotice(err.message, 'error');
  }
}

async function switchTab(key) {
  activeTab.value = key;
  try {
    if (key === 'overview') await loadOverview();
    if (key === 'cluster') await loadClusterAdminNodes();
    if (key === 'interfaces') await loadAdminInterfaces();
    if (key === 'backups') await loadBackups();
    if (key === 'security') await loadLogs();
  } catch (err) {
    showNotice(err.message, 'error');
  }
}

async function saveSystemAndQuota() {
  savingSettings.value = true;
  try {
    await apiRequest('/api/v1/admin/settings', {
      method: 'PUT',
      body: { system: systemForm, quota: quotaForm }
    });
    showNotice('系统与流量配额配置已保存生效');
    emit('updated');
  } catch (err) {
    showNotice(err.message, 'error');
  } finally {
    savingSettings.value = false;
  }
}

async function saveNicRow(nic) {
  try {
    await apiRequest(`/api/v1/admin/interfaces/${encodeURIComponent(nic.name)}`, {
      method: 'PUT',
      body: {
        alias: nic._editAlias,
        visible: nic._editVisible === 'show'
      }
    });
    showNotice(`网卡 ${nic.name} 设置已更新`);
    await loadAdminInterfaces();
    emit('updated');
  } catch (err) {
    showNotice(err.message, 'error');
  }
}

async function importFromVnstat() {
  importingVnstat.value = true;
  try {
    const res = await apiRequest('/api/v1/admin/vnstat/import', { method: 'POST', body: {} });
    const detail = Object.entries(res.imported || {})
      .map(([k, v]) => `${k}: ${v}条`)
      .join(', ');
    showNotice(`${res.message}${detail ? ` (${detail})` : ''}`);
    await loadOverview();
    emit('updated');
  } catch (err) {
    showNotice(err.message, 'error');
  } finally {
    importingVnstat.value = false;
  }
}

async function saveAlerts() {
  try {
    await apiRequest('/api/v1/admin/alerts', {
      method: 'PUT',
      body: alertForm
    });
    await loadSettings();
    showNotice('告警推送配置已保存');
  } catch (err) {
    showNotice(err.message, 'error');
  }
}

async function triggerTestAlert() {
  testingAlert.value = true;
  try {
    const res = await apiRequest('/api/v1/admin/alerts/test', { method: 'POST', body: {} });
    showNotice(res.message || '测试通知已发送');
  } catch (err) {
    showNotice(err.message, 'error');
  } finally {
    testingAlert.value = false;
  }
}

async function createBackupNow() {
  backupBusy.value = true;
  try {
    const res = await apiRequest('/api/v1/admin/backups', {
      method: 'POST',
      body: { note: backupNote.value }
    });
    backupNote.value = '';
    await loadBackups();
    showNotice(`备份已生成：${res.backup?.name || ''}`);
  } catch (err) {
    showNotice(err.message, 'error');
  } finally {
    backupBusy.value = false;
  }
}

function askRestoreExisting(name) {
  pendingRestore.value = { mode: 'existing', name, label: name };
}

function onSelectUploadBackup(event) {
  const file = event.target.files?.[0];
  event.target.value = '';
  if (!file) return;
  pendingRestore.value = { mode: 'upload', file, label: `本地文件 ${file.name}` };
}

async function confirmExecuteRestore() {
  if (!pendingRestore.value) return;
  backupBusy.value = true;
  try {
    if (pendingRestore.value.mode === 'existing') {
      const res = await apiRequest(`/api/v1/admin/backups/${encodeURIComponent(pendingRestore.value.name)}/restore`, {
        method: 'POST',
        body: { confirm: true }
      });
      showNotice(`${res.message}（保护快照：${res.protectiveBackup?.name || ''}）`);
    } else {
      const fd = new FormData();
      fd.append('confirm', 'true');
      fd.append('file', pendingRestore.value.file);
      const res = await apiRequest('/api/v1/admin/backups/upload-restore', {
        method: 'POST',
        body: fd
      });
      showNotice(`${res.message}（保护快照：${res.protectiveBackup?.name || ''}）`);
    }
    pendingRestore.value = null;
    await Promise.all([loadSettings(), loadBackups(), loadOverview()]);
    emit('updated');
  } catch (err) {
    showNotice(err.message, 'error');
  } finally {
    backupBusy.value = false;
  }
}

async function deleteBackupItem(name) {
  if (!window.confirm(`确定要删除备份快照 ${name} 吗？`)) return;
  try {
    await apiRequest(`/api/v1/admin/backups/${encodeURIComponent(name)}`, { method: 'DELETE' });
    await loadBackups();
    showNotice(`已删除备份 ${name}`);
  } catch (err) {
    showNotice(err.message, 'error');
  }
}

async function onImportConfigFile(event) {
  const file = event.target.files?.[0];
  event.target.value = '';
  if (!file) return;
  try {
    const text = await file.text();
    const parsed = JSON.parse(text);
    await apiRequest('/api/v1/admin/config/import', { method: 'POST', body: parsed });
    await Promise.all([loadSettings(), loadAdminInterfaces()]);
    showNotice('系统配置导入成功');
    emit('updated');
  } catch (err) {
    showNotice(`导入配置失败：${err.message}`, 'error');
  }
}

async function executeResetTraffic() {
  backupBusy.value = true;
  try {
    const res = await apiRequest('/api/v1/admin/data/reset', {
      method: 'POST',
      body: { interface: resetTarget.value, confirm: resetConfirmWord.value }
    });
    resetConfirmWord.value = '';
    await loadBackups();
    showNotice(`${res.message}（保护快照：${res.protectiveBackup?.name || ''}）`);
    emit('updated');
  } catch (err) {
    showNotice(err.message, 'error');
  } finally {
    backupBusy.value = false;
  }
}

async function changePassword() {
  if (pwdForm.newPassword !== pwdForm.confirmPassword) {
    showNotice('两次输入的新密码不一致', 'error');
    return;
  }
  try {
    await apiRequest('/api/v1/auth/password', {
      method: 'POST',
      body: {
        currentPassword: pwdForm.currentPassword,
        newPassword: pwdForm.newPassword
      }
    });
    pwdForm.currentPassword = '';
    pwdForm.newPassword = '';
    pwdForm.confirmPassword = '';
    showNotice('管理员登录密码已更新');
  } catch (err) {
    showNotice(err.message, 'error');
  }
}

async function copyHash(hash) {
  const ok = await copyTextSafe(hash);
  showNotice(ok ? '已复制完整 SHA-256 摘要到剪贴板' : '复制失败，请手动复制', ok ? 'ok' : 'error');
}

async function copyLogs() {
  const content = logs.value
    .map(item => `[${item.timestamp}] [${item.level}] ${item.message}`)
    .join('\n');
  const ok = await copyTextSafe(content);
  showNotice(ok ? '已复制当前日志列表到剪贴板' : '复制失败', ok ? 'ok' : 'error');
}

async function handleLogout() {
  try {
    await apiRequest('/api/v1/auth/logout', { method: 'POST', body: {} });
  } catch (_) {
    // 忽略网络异常直接清理前端登录状态
  }
  emit('logged-out');
}

onMounted(async () => {
  try {
    await Promise.all([loadOverview(), loadSettings(), loadAdminInterfaces()]);
  } catch (err) {
    showNotice(err.message, 'error');
  }
});
</script>
