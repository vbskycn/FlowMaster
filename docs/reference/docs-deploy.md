# 文档站 Cloudflare Pages 部署说明

FlowMaster 官方文档站位于仓库的 `docs/` 目录，基于 **VitePress** 构建，输出为纯静态 HTML/JS/CSS 文件，天然适配 **Cloudflare Pages** 全球边缘托管。

---

## 一、Cloudflare Pages 控制台配置

1. 登录 [Cloudflare Dashboard](https://dash.cloudflare.com/) → **Workers & Pages** → **Create** → **Pages** → **Connect to Git**；
2. 选择 GitHub 仓库 `vbskycn/FlowMaster`，生产分支选择 `main`；
3. 按下表填写构建配置：

| 配置项 | 填写值 |
| :--- | :--- |
| **Project name** | `flowmaster-docs`（可自定义） |
| **Production branch** | `main` |
| **Framework preset** | `None`（或 `VitePress`） |
| **Root directory（路径）** | `docs` |
| **Build command** | `npm run build` |
| **Build output directory** | `.vitepress/dist` |
| **Environment variable** | `NODE_VERSION` = `22` |

4. 点击 **Save and Deploy**，约 30 秒即可完成全球发布。后续每次推送 `main` 分支，Cloudflare Pages 会自动增量重编上线。

---

## 二、绑定自定义域名

1. 部署完成后进入该 Pages 项目的 **Custom domains** → **Set up a custom domain**；
2. 输入 `flowmaster-docs.168668518.com`，由于该域名已托管在 Cloudflare DNS，点击激活即可自动创建 CNAME 并签发 HTTPS 证书；
3. 本站点的 `sitemap.xml` 与 OpenGraph 元数据已预设为 `https://flowmaster-docs.168668518.com/`，并已开启 `cleanUrls: true`（Cloudflare Pages 原生支持无 `.html` 后缀的干净 URL）。

---

## 三、本地预览与构建

```bash
cd docs
npm ci
npm run dev      # 启动本地热更新预览 (默认 http://localhost:5173)
npm run build    # 生成生产静态站点至 docs/.vitepress/dist
npm run preview  # 本地预览生产构建产物
```
