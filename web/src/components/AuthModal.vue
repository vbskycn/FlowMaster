<template>
  <div
    class="fixed inset-0 z-50 flex items-center justify-center p-4 bg-slate-950/60 backdrop-blur-xs"
    @click.self="!blocking && $emit('close')"
  >
    <div class="w-full max-w-md rounded-2xl bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-800 shadow-2xl p-6">
      <!-- 品牌标识 + 版本号徽章 -->
      <div class="flex items-center justify-between mb-5">
        <div class="flex items-center gap-2.5">
          <img src="/favicon.svg" alt="FlowMaster" class="w-8 h-8 rounded-lg" />
          <div class="flex items-baseline gap-2">
            <span class="text-lg font-bold tracking-tight text-slate-900 dark:text-white">{{ siteTitle || 'FlowMaster' }}</span>
            <span
              v-if="version"
              class="font-num text-xs px-2 py-0.5 rounded-full bg-blue-50 text-blue-700 dark:bg-blue-950/80 dark:text-blue-300 border border-blue-200/70 dark:border-blue-800/70"
            >
              v{{ version }}
            </span>
          </div>
        </div>
        <button
          v-if="!blocking"
          type="button"
          class="text-slate-400 hover:text-slate-600 dark:hover:text-slate-200 text-sm"
          @click="$emit('close')"
        >
          关闭
        </button>
      </div>

      <h3 class="text-base font-semibold text-slate-800 dark:text-slate-100 mb-1">
        {{ needsSetup ? '首次初始化管理员密码' : '管理员身份验证' }}
      </h3>
      <p class="text-xs text-slate-500 dark:text-slate-400 mb-4">
        {{ needsSetup ? '首次进入管理后台，请设置至少 6 位的管理员登录密码（服务端使用 PBKDF2 慢哈希加密保存）。' : '请输入管理员密码以访问系统配置、流量配额与备份恢复中心。' }}
      </p>

      <div v-if="errorMsg" class="mb-4 p-3 rounded-lg bg-red-50 dark:bg-red-950/50 border border-red-200 dark:border-red-900 text-xs text-red-700 dark:text-red-300">
        {{ errorMsg }}
      </div>

      <form class="space-y-3.5" @submit.prevent="submitForm">
        <div>
          <label class="block text-xs font-medium text-slate-600 dark:text-slate-300 mb-1">
            {{ needsSetup ? '设置新密码' : '管理员密码' }}
          </label>
          <input
            v-model="password"
            type="password"
            required
            minlength="6"
            autocomplete="current-password"
            placeholder="请输入密码"
            class="w-full px-3.5 py-2 text-sm rounded-xl border border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-950 focus:outline-none focus:ring-2 focus:ring-blue-500/50"
          />
        </div>

        <div v-if="needsSetup">
          <label class="block text-xs font-medium text-slate-600 dark:text-slate-300 mb-1">
            确认新密码
          </label>
          <input
            v-model="confirmPassword"
            type="password"
            required
            minlength="6"
            autocomplete="new-password"
            placeholder="请再次输入密码"
            class="w-full px-3.5 py-2 text-sm rounded-xl border border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-950 focus:outline-none focus:ring-2 focus:ring-blue-500/50"
          />
        </div>

        <button
          type="submit"
          :disabled="submitting"
          class="w-full py-2.5 px-4 rounded-xl bg-blue-600 hover:bg-blue-700 disabled:opacity-50 text-white text-sm font-medium transition-colors cursor-pointer"
        >
          {{ submitting ? '验证中…' : (needsSetup ? '保存密码并进入' : '立即登录') }}
        </button>
      </form>
    </div>
  </div>
</template>

<script setup>
import { ref } from 'vue';
import { apiRequest } from '../utils/format';

const props = defineProps({
  needsSetup: { type: Boolean, default: false },
  blocking: { type: Boolean, default: false },
  version: { type: String, default: '' },
  siteTitle: { type: String, default: '' }
});

const emit = defineEmits(['close', 'success']);

const password = ref('');
const confirmPassword = ref('');
const submitting = ref(false);
const errorMsg = ref('');

async function submitForm() {
  errorMsg.value = '';
  if (props.needsSetup && password.value !== confirmPassword.value) {
    errorMsg.value = '两次输入的密码不一致';
    return;
  }
  submitting.value = true;
  try {
    const endpoint = props.needsSetup ? '/api/v1/auth/setup' : '/api/v1/auth/login';
    await apiRequest(endpoint, {
      method: 'POST',
      body: { password: password.value }
    });
    password.value = '';
    confirmPassword.value = '';
    emit('success');
  } catch (err) {
    errorMsg.value = err.message || '操作失败';
  } finally {
    submitting.value = false;
  }
}
</script>
