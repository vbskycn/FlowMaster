# syntax=docker/dockerfile:1

# ==============================================================================
# Stage 1: 构建现代化前端静态产物
# ==============================================================================
FROM node:22-alpine AS web-builder
ARG NPM_REGISTRY=https://registry.npmjs.org
WORKDIR /src/web
COPY web/package.json web/package-lock.json ./
RUN npm config set registry "${NPM_REGISTRY}" && npm ci --no-audit --no-fund
COPY web/ ./
RUN npm run build

# ==============================================================================
# Stage 2: 编译零 CGO 纯静态 Go 二进制（内嵌 VERSION 与前端静态资源）
# ==============================================================================
FROM golang:1.26-alpine AS go-builder
ARG GOPROXY=https://proxy.golang.org,direct
ENV GOPROXY=${GOPROXY} CGO_ENABLED=0
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY VERSION embed.go ./
COPY cmd/ ./cmd/
COPY internal/ ./internal/
COPY --from=web-builder /src/web/dist ./web/dist
RUN go build -trimpath -ldflags="-s -w" -o /out/flowmaster ./cmd/flowmaster && \
    /out/flowmaster --version

# ==============================================================================
# Stage 3: 极简安全运行镜像（含轻量 vnstat CLI 以支持容器内混合/导入模式）
# ==============================================================================
FROM alpine:3.21
RUN apk add --no-cache ca-certificates tzdata vnstat wget && \
    mkdir -p /data && \
    chmod 0750 /data

COPY --from=go-builder /out/flowmaster /usr/local/bin/flowmaster

ENV HOST=0.0.0.0 \
    PORT=10089 \
    DATA_DIR=/data \
    TZ=Asia/Shanghai

EXPOSE 10089
VOLUME ["/data"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD wget -q -O /dev/null "http://127.0.0.1:${PORT}/api/version" || exit 1

ENTRYPOINT ["/usr/local/bin/flowmaster"]
