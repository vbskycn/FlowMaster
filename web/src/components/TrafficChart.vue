<template>
  <div class="relative w-full" :style="{ height: height + 'px' }">
    <canvas ref="canvasRef"></canvas>
  </div>
</template>

<script setup>
import { ref, watch, onMounted, onBeforeUnmount } from 'vue';
import {
  Chart,
  LineController,
  BarController,
  LineElement,
  BarElement,
  PointElement,
  LinearScale,
  CategoryScale,
  Filler,
  Tooltip,
  Legend
} from 'chart.js';

Chart.register(
  LineController,
  BarController,
  LineElement,
  BarElement,
  PointElement,
  LinearScale,
  CategoryScale,
  Filler,
  Tooltip,
  Legend
);

const props = defineProps({
  type: { type: String, default: 'line' },
  labels: { type: Array, default: () => [] },
  rxData: { type: Array, default: () => [] },
  txData: { type: Array, default: () => [] },
  rxLabel: { type: String, default: '下行 (RX)' },
  txLabel: { type: String, default: '上行 (TX)' },
  unit: { type: String, default: '' },
  dark: { type: Boolean, default: false },
  height: { type: Number, default: 280 },
  animate: { type: Boolean, default: true }
});

const canvasRef = ref(null);
let chartInstance = null;

function buildConfig() {
  const textColor = props.dark ? '#cbd5e1' : '#475569';
  const gridColor = props.dark ? 'rgba(148, 163, 184, 0.12)' : 'rgba(148, 163, 184, 0.22)';
  const isBar = props.type === 'bar';

  return {
    type: isBar ? 'bar' : 'line',
    data: {
      labels: props.labels,
      datasets: [
        {
          label: props.unit ? `${props.rxLabel} (${props.unit})` : props.rxLabel,
          data: props.rxData,
          borderColor: props.dark ? '#60a5fa' : '#2563eb',
          backgroundColor: isBar
            ? (props.dark ? 'rgba(96, 165, 250, 0.82)' : 'rgba(37, 99, 235, 0.82)')
            : (props.dark ? 'rgba(96, 165, 250, 0.16)' : 'rgba(37, 99, 235, 0.12)'),
          borderWidth: isBar ? 0 : 2,
          borderRadius: isBar ? 6 : 0,
          pointRadius: props.labels.length > 36 ? 0 : 2.5,
          pointHoverRadius: 4,
          tension: 0.32,
          fill: !isBar
        },
        {
          label: props.unit ? `${props.txLabel} (${props.unit})` : props.txLabel,
          data: props.txData,
          borderColor: props.dark ? '#34d399' : '#059669',
          backgroundColor: isBar
            ? (props.dark ? 'rgba(52, 211, 153, 0.82)' : 'rgba(5, 150, 105, 0.82)')
            : (props.dark ? 'rgba(52, 211, 153, 0.14)' : 'rgba(5, 150, 105, 0.10)'),
          borderWidth: isBar ? 0 : 2,
          borderRadius: isBar ? 6 : 0,
          pointRadius: props.labels.length > 36 ? 0 : 2.5,
          pointHoverRadius: 4,
          tension: 0.32,
          fill: !isBar
        }
      ]
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      animation: props.animate ? { duration: 220 } : false,
      interaction: {
        mode: 'index',
        intersect: false
      },
      plugins: {
        legend: {
          position: 'top',
          align: 'end',
          labels: {
            color: textColor,
            boxWidth: 12,
            boxHeight: 12,
            usePointStyle: true,
            font: { size: 12 }
          }
        },
        tooltip: {
          backgroundColor: props.dark ? 'rgba(15, 23, 42, 0.94)' : 'rgba(255, 255, 255, 0.96)',
          titleColor: props.dark ? '#f8fafc' : '#0f172a',
          bodyColor: props.dark ? '#e2e8f0' : '#334155',
          borderColor: props.dark ? 'rgba(148, 163, 184, 0.24)' : 'rgba(148, 163, 184, 0.35)',
          borderWidth: 1,
          padding: 10
        }
      },
      scales: {
        x: {
          ticks: {
            color: textColor,
            maxRotation: 0,
            autoSkip: true,
            maxTicksLimit: 10,
            font: { size: 11 }
          },
          grid: {
            display: false
          }
        },
        y: {
          beginAtZero: true,
          ticks: {
            color: textColor,
            font: { size: 11 }
          },
          grid: {
            color: gridColor
          },
          title: {
            display: Boolean(props.unit),
            text: props.unit,
            color: textColor,
            font: { size: 11 }
          }
        }
      }
    }
  };
}

function renderOrUpdate(rebuild = false) {
  if (!canvasRef.value) return;
  if (!chartInstance || rebuild) {
    if (chartInstance) {
      chartInstance.destroy();
      chartInstance = null;
    }
    chartInstance = new Chart(canvasRef.value, buildConfig());
    return;
  }
  chartInstance.data.labels = props.labels;
  chartInstance.data.datasets[0].data = props.rxData;
  chartInstance.data.datasets[1].data = props.txData;
  chartInstance.data.datasets[0].label = props.unit ? `${props.rxLabel} (${props.unit})` : props.rxLabel;
  chartInstance.data.datasets[1].label = props.unit ? `${props.txLabel} (${props.unit})` : props.txLabel;
  chartInstance.options.scales.y.title.text = props.unit;
  chartInstance.update(props.animate ? undefined : 'none');
}

watch(
  () => [props.type, props.dark],
  () => renderOrUpdate(true)
);

watch(
  () => [props.labels, props.rxData, props.txData, props.unit],
  () => renderOrUpdate(false),
  { deep: true }
);

onMounted(() => renderOrUpdate(true));
onBeforeUnmount(() => {
  if (chartInstance) {
    chartInstance.destroy();
    chartInstance = null;
  }
});
</script>
