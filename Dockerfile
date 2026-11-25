# syntax=docker/dockerfile:1

# ==============================================================================
# Stage 1: 构建现代化前端静态产物（在宿主构建架构原生执行，跨架构零模拟损耗）
# ==============================================================================
FROM --platform=$BUILDPLATFORM node:22-alpine AS web-builder
ARG NPM_REGISTRY=https://registry.npmjs.org
WORKDIR /src/web
COPY web/package.json web/package-lock.json ./
RUN npm config set registry "${NPM_REGISTRY}" && npm ci --no-audit --no-fund
COPY web/ ./
RUN npm run build

# ==============================================================================
# Stage 2: 原生交叉编译零 CGO 纯静态 Go 二进制（内嵌 VERSION 与前端静态资源）
# ==============================================================================
FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS go-builder
ARG GOPROXY=https://proxy.golang.org,direct
ARG TARGETOS
ARG TARGETARCH
ENV GOPROXY=${GOPROXY} CGO_ENABLED=0
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY VERSION embed.go install.sh ./
COPY cmd/ ./cmd/
COPY internal/ ./internal/
COPY --from=web-builder /src/web/dist ./web/dist
RUN GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH:-amd64} go build -trimpath -ldflags="-s -w" -o /out/flowmaster ./cmd/flowmaster

# ==============================================================================
# Stage 3: 极简安全多架构运行镜像（含轻量 vnstat CLI 支持容器混合/导入模式）
# ==============================================================================
FROM alpine:3.21
LABEL org.opencontainers.image.title="FlowMaster" \
      org.opencontainers.image.description="Lightweight Linux Host Network Traffic Monitor & Admin Panel" \
      org.opencontainers.image.source="https://github.com/vbskycn/FlowMaster" \
      org.opencontainers.image.licenses="MIT"

RUN apk add --no-cache ca-certificates tzdata vnstat && \
    mkdir -p /data && \
    chmod 0750 /data

COPY --from=go-builder /out/flowmaster /usr/local/bin/flowmaster

ENV HOST=:: \
    PORT=10089 \
    DATA_DIR=/data \
    TZ=Asia/Shanghai

EXPOSE 10089
VOLUME ["/data"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD ["/usr/local/bin/flowmaster", "-healthcheck"]

ENTRYPOINT ["/usr/local/bin/flowmaster"]
