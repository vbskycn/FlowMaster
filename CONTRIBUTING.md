# 参与 FlowMaster 开发

感谢参与 FlowMaster 开发。提交改动前，请先阅读 [AGENTS.md](AGENTS.md) 中的项目边界与数据安全规范。

## 开发环境要求

- Go 1.26 或更高版本（纯 Go 编译，`CGO_ENABLED=0`）。
- Node.js 22+ 与 npm（仅用于 `web/` 前端静态资源编译，生产运行不需要 Node.js）。
- Docker（可选，用于验证多阶段容器镜像构建与冒烟测试）。

## 本地开发与构建

1. 构建前端静态产物：

```bash
cd web
npm ci
npm run build
cd ..
```

2. 启动后端服务：

```bash
cp -n .env.example .env
go run ./cmd/flowmaster
```

默认访问 `http://127.0.0.1:10089`。前端联调时也可在另一个终端运行 `cd web && npm run dev`（Vite 开发服务器已配置将 `/api` 代理至 `127.0.0.1:10089`）。

3. 编译单文件生产二进制：

```bash
CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o flowmaster ./cmd/flowmaster
./flowmaster --version
```

## 测试与检查

提交代码前请确保以下检查全部通过：

```bash
cd web && npm ci && npm run build && cd ..
go vet ./...
go test -race -v ./...
bash -n install.sh
shellcheck --severity=warning install.sh
```

## 提交规范

- `feat:` 新增功能
- `fix:` 缺陷修复
- `docs:` 文档更新
- `refactor:` 重构优化
- `test:` 测试用例补充
- `chore:` 构建或依赖维护
- `release: flowmaster v<version>` 正式版本发布（普通开发阶段请勿提前修改 `VERSION`）
