package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	flowmaster "github.com/vbskycn/flowmaster"
	"github.com/vbskycn/flowmaster/internal/collector"
	"github.com/vbskycn/flowmaster/internal/config"
	"github.com/vbskycn/flowmaster/internal/logger"
	"github.com/vbskycn/flowmaster/internal/quota"
	"github.com/vbskycn/flowmaster/internal/store"
	"github.com/vbskycn/flowmaster/internal/web"
)

func main() {
	var (
		showVersion bool
		healthcheck bool
		envFile     string
	)
	flag.BoolVar(&showVersion, "version", false, "显示版本号并退出")
	flag.BoolVar(&showVersion, "v", false, "显示版本号并退出 (简写)")
	flag.BoolVar(&healthcheck, "healthcheck", false, "执行本机 HTTP 健康检查并退出")
	flag.StringVar(&envFile, "env-file", ".env", "可选的环境变量配置文件路径")
	flag.Usage = func() {
		fmt.Fprintf(os.Stdout, "%s v%s - 轻量级主机网络流量实时监控与管理服务\n\n用法:\n  flowmaster [选项]\n\n选项:\n",
			flowmaster.AppName(), flowmaster.AppVersion())
		flag.PrintDefaults()
	}
	flag.Parse()

	if showVersion {
		fmt.Printf("%s v%s\n", flowmaster.AppName(), flowmaster.AppVersion())
		return
	}

	config.LoadDotEnv(envFile)
	if healthcheck {
		port := config.ParseIntInRange(os.Getenv("PORT"), 10089, 1, 65535)
		hcClient := &http.Client{Timeout: 3 * time.Second}
		resp, err := hcClient.Get(fmt.Sprintf("http://127.0.0.1:%d/api/version", port))
		if err != nil {
			os.Exit(1)
		}
		_ = resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			os.Exit(1)
		}
		return
	}
	cfg, err := config.Load()
	if err != nil {
		fmt.Fprintf(os.Stderr, "加载配置失败: %v\n", err)
		os.Exit(1)
	}

	logMgr, err := logger.NewManager(cfg.DataDir, true)
	if err != nil {
		fmt.Fprintf(os.Stderr, "初始化日志失败: %v\n", err)
		os.Exit(1)
	}

	st, err := store.Open(cfg.DataDir)
	if err != nil {
		logMgr.Error("初始化 SQLite 数据库失败: %v", err)
		os.Exit(1)
	}
	defer func() { _ = st.Close() }()

	bm, err := store.NewBackupManager(st, cfg.DataDir)
	if err != nil {
		logMgr.Error("初始化备份管理器失败: %v", err)
		os.Exit(1)
	}

	vnClient := collector.NewVnstatClient(
		cfg.VnstatBin,
		cfg.VnstatDBDir,
		time.Duration(cfg.VnstatTimeoutMs)*time.Millisecond,
		cfg.VnstatMaxConcurrency,
		nil,
	)
	engine := collector.NewEngine(cfg, st, vnClient, logMgr)
	quotaSvc := quota.NewService(st, engine, logMgr)

	srv, err := web.NewServer(cfg, st, bm, engine, vnClient, quotaSvc, logMgr)
	if err != nil {
		logMgr.Error("初始化 Web 服务失败: %v", err)
		os.Exit(1)
	}

	engine.Start(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		quotaSvc.CheckAndNotify(ctx)
	})

	addr := fmt.Sprintf("%s:%d", cfg.Host, cfg.Port)
	httpServer := &http.Server{
		Addr:              addr,
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      60 * time.Second,
		IdleTimeout:       120 * time.Second,
	}

	vnAvail, vnVer := engine.VnstatStatus(context.Background())
	if vnAvail {
		logMgr.Info("%s v%s 已启动，监听 http://%s (数据目录: %s, vnstat: %s)", flowmaster.AppName(), flowmaster.AppVersion(), addr, cfg.DataDir, vnVer)
	} else {
		logMgr.Info("%s v%s 已启动，监听 http://%s (数据目录: %s, 内核直采 SQLite 模式)", flowmaster.AppName(), flowmaster.AppVersion(), addr, cfg.DataDir)
	}

	errCh := make(chan error, 1)
	go func() {
		if serveErr := httpServer.ListenAndServe(); serveErr != nil && !errors.Is(serveErr, http.ErrServerClosed) {
			errCh <- serveErr
		}
		close(errCh)
	}()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	select {
	case sig := <-sigCh:
		logMgr.Info("收到信号 %s，正在刷写缓冲流量并优雅停止服务...", sig.String())
	case serveErr := <-errCh:
		if serveErr != nil {
			logMgr.Error("HTTP 服务启动失败: %v", serveErr)
			engine.Stop()
			os.Exit(1)
		}
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = httpServer.Shutdown(shutdownCtx)
	engine.Stop()
	logMgr.Info("服务已安全退出")
}
