// 格式化字节数为人类可读 IEC 单位 (B / KiB / MiB / GiB / TiB)
export function formatBytes(bytes, decimals = 2) {
  const num = Number(bytes || 0);
  if (!Number.isFinite(num) || num <= 0) return '0.00 B';
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB'];
  const idx = Math.min(units.length - 1, Math.floor(Math.log(num) / Math.log(1024)));
  const val = num / Math.pow(1024, idx);
  if (idx === 0) return `${Math.round(val)} B`;
  if (val < 0.01) return `${val.toFixed(3)} ${units[idx]}`;
  return `${val.toFixed(decimals)} ${units[idx]}`;
}

// 格式化实时速率（支持十进制比特率 Mbps 与字节率 MB/s 切换）
export function formatRate(bytesPerSec, mode = 'bits') {
  const bps = Math.max(0, Number(bytesPerSec || 0));
  if (mode === 'bytes') {
    if (bps < 1024) return `${bps.toFixed(0)} B/s`;
    if (bps < 1024 * 1024) return `${(bps / 1024).toFixed(2)} KiB/s`;
    if (bps < 1024 * 1024 * 1024) return `${(bps / (1024 * 1024)).toFixed(2)} MiB/s`;
    return `${(bps / (1024 * 1024 * 1024)).toFixed(2)} GiB/s`;
  }
  const bits = bps * 8;
  if (bits < 1000) return `${bits.toFixed(0)} bps`;
  if (bits < 1_000_000) return `${(bits / 1000).toFixed(2)} Kbps`;
  if (bits < 1_000_000_000) return `${(bits / 1_000_000).toFixed(2)} Mbps`;
  return `${(bits / 1_000_000_000).toFixed(2)} Gbps`;
}

// 格式化比特率数值 (平均速率 bps)
export function formatBps(bitsPerSec) {
  const bits = Math.max(0, Number(bitsPerSec || 0));
  if (bits < 1000) return `${bits.toFixed(0)} bps`;
  if (bits < 1_000_000) return `${(bits / 1000).toFixed(2)} Kbps`;
  if (bits < 1_000_000_000) return `${(bits / 1_000_000).toFixed(2)} Mbps`;
  return `${(bits / 1_000_000_000).toFixed(2)} Gbps`;
}

// 格式化运行时长
export function formatUptime(seconds) {
  const s = Math.max(0, Math.floor(Number(seconds || 0)));
  const days = Math.floor(s / 86400);
  const hours = Math.floor((s % 86400) / 3600);
  const mins = Math.floor((s % 3600) / 60);
  if (days > 0) return `${days}天 ${hours}小时 ${mins}分`;
  if (hours > 0) return `${hours}小时 ${mins}分`;
  return `${mins}分 ${s % 60}秒`;
}

// 兼容内网非安全 HTTP 与公网 HTTPS 的剪贴板复制函数
export async function copyTextSafe(text) {
  const content = String(text ?? '');
  if (navigator.clipboard && window.isSecureContext) {
    try {
      await navigator.clipboard.writeText(content);
      return true;
    } catch (_) {
      // 继续走 textarea 回退路径
    }
  }
  const textarea = document.createElement('textarea');
  textarea.value = content;
  textarea.setAttribute('readonly', '');
  textarea.style.position = 'fixed';
  textarea.style.top = '-9999px';
  textarea.style.opacity = '0';
  document.body.appendChild(textarea);
  textarea.focus();
  textarea.select();
  let ok = false;
  try {
    ok = document.execCommand('copy');
  } catch (_) {
    ok = false;
  } finally {
    document.body.removeChild(textarea);
  }
  return ok;
}

// 统一封装带 CSRF 防护头 (X-Requested-With) 的 JSON API 请求
export async function apiRequest(url, options = {}) {
  const headers = {
    'X-Requested-With': 'FlowMaster',
    ...(options.headers || {})
  };
  let body = options.body;
  if (body && typeof body === 'object' && !(body instanceof FormData)) {
    headers['Content-Type'] = 'application/json';
    body = JSON.stringify(body);
  }
  const response = await fetch(url, {
    credentials: 'same-origin',
    ...options,
    headers,
    body
  });
  const contentType = response.headers.get('content-type') || '';
  const data = contentType.includes('application/json') ? await response.json() : await response.text();
  if (!response.ok) {
    const msg = (data && typeof data === 'object' && data.error) ? data.error : `请求失败 (${response.status})`;
    const err = new Error(msg);
    err.status = response.status;
    err.payload = data;
    throw err;
  }
  return data;
}
