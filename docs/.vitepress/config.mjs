import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitepress';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

function readAppVersion() {
  try {
    const versionFile = path.resolve(__dirname, '../../VERSION');
    const raw = fs.readFileSync(versionFile, 'utf-8');
    const match = raw.match(/^APP_VERSION\s*=\s*(.+)$/m);
    if (match) return match[1].trim().replace(/^['"]|['"]$/g, '');
  } catch {
    // 忽略异常回退默认显示
  }
  return '2.5.1';
}

const appVersion = readAppVersion();

export default defineConfig({
  lang: 'zh-CN',
  title: 'FlowMaster',
  description: '轻量级 Linux 网络流量实时监控与多机统一管理中枢官方文档',
  cleanUrls: true,
  lastUpdated: true,

  sitemap: {
    hostname: 'https://flowmaster-docs.168668518.com'
  },

  head: [
    ['link', { rel: 'icon', type: 'image/svg+xml', href: '/favicon.svg' }],
    ['meta', { name: 'theme-color', content: '#2563eb' }],
    ['meta', { property: 'og:type', content: 'website' }],
    ['meta', { property: 'og:title', content: 'FlowMaster 官方文档' }],
    ['meta', { property: 'og:description', content: 'Go 单二进制 + SQLite + Vue 3 构建的轻量级 Linux 流量监控与多机集群管理中枢' }],
    ['meta', { property: 'og:url', content: 'https://flowmaster-docs.168668518.com/' }]
  ],

  themeConfig: {
    logo: '/favicon.svg',
    siteTitle: `FlowMaster v${appVersion}`,

    nav: [
      { text: '快速开始', link: '/guide/getting-started' },
      { text: '多机集群', link: '/guide/cluster' },
      { text: '告警与配额', link: '/guide/alerts' },
      { text: '反代与 CDN', link: '/guide/reverse-proxy' },
      {
        text: '运维与参考',
        items: [
          { text: '安全与灾难恢复', link: '/operations' },
          { text: '环境变量参考', link: '/reference/env' },
          { text: 'HTTP API 文档', link: '/api' },
          { text: '系统架构说明', link: '/architecture' },
          { text: '版本更新记录', link: '/reference/changelog' },
          { text: '文档站部署 (CF Pages)', link: '/reference/docs-deploy' }
        ]
      },
      {
        text: `v${appVersion}`,
        items: [
          { text: '更新记录', link: '/reference/changelog' },
          { text: 'GitHub Releases', link: 'https://github.com/vbskycn/FlowMaster/releases' },
          { text: 'Docker Hub', link: 'https://hub.docker.com/r/zhoujie218/flowmaster' }
        ]
      }
    ],

    sidebar: [
      {
        text: '使用指南',
        items: [
          { text: '项目简介与快速开始', link: '/guide/getting-started' },
          { text: '安装、升级与安全卸载', link: '/guide/install' },
          { text: '多机集群与主控分发', link: '/guide/cluster' },
          { text: '月度配额与多通道告警', link: '/guide/alerts' },
          { text: '反向代理与 Cloudflare CDN', link: '/guide/reverse-proxy' }
        ]
      },
      {
        text: '运维、安全与参考',
        items: [
          { text: '安全加固、备份还原与排错', link: '/operations' },
          { text: '系统架构与数据流', link: '/architecture' },
          { text: 'HTTP API 接口文档', link: '/api' },
          { text: '环境变量与配置参考', link: '/reference/env' },
          { text: '版本更新记录', link: '/reference/changelog' },
          { text: '文档站 CF Pages 部署说明', link: '/reference/docs-deploy' }
        ]
      }
    ],

    socialLinks: [
      { icon: 'github', link: 'https://github.com/vbskycn/FlowMaster' }
    ],

    editLink: {
      pattern: 'https://github.com/vbskycn/FlowMaster/edit/main/docs/:path',
      text: '在 GitHub 上编辑此页'
    },

    footer: {
      message: '基于 MIT 协议开源发布',
      copyright: 'Copyright © 2025-present vbskycn · FlowMaster'
    },

    docFooter: {
      prev: '上一页',
      next: '下一页'
    },

    outline: {
      label: '本页目录',
      level: [2, 3]
    },

    lastUpdated: {
      text: '最后更新于',
      formatOptions: {
        dateStyle: 'short',
        timeStyle: 'short'
      }
    },

    search: {
      provider: 'local',
      options: {
        translations: {
          button: {
            buttonText: '搜索文档',
            buttonAriaLabel: '搜索文档'
          },
          modal: {
            noResultsText: '未找到相关内容',
            resetButtonTitle: '清除搜索条件',
            footer: {
              selectText: '选择',
              navigateText: '切换',
              closeText: '关闭'
            }
          }
        }
      }
    },

    returnToTopLabel: '返回顶部',
    sidebarMenuLabel: '菜单',
    darkModeSwitchLabel: '主题',
    lightModeSwitchTitle: '切换浅色模式',
    darkModeSwitchTitle: '切换深色模式'
  }
});
