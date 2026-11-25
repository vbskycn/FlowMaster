package web

import (
	"compress/gzip"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"path"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	flowmaster "github.com/vbskycn/flowmaster"
	"github.com/vbskycn/flowmaster/internal/cluster"
	"github.com/vbskycn/flowmaster/internal/collector"
	"github.com/vbskycn/flowmaster/internal/config"
	"github.com/vbskycn/flowmaster/internal/logger"
	"github.com/vbskycn/flowmaster/internal/model"
	"github.com/vbskycn/flowmaster/internal/quota"
	"github.com/vbskycn/flowmaster/internal/store"
	"github.com/vbskycn/flowmaster/internal/updater"
)

type rateBucket struct {
	count   int
	resetAt time.Time
}

// Server 承载现代 /api/v1/*、SSE 实时流、多机集群管理、旧版 /api/* 兼容层与内嵌 Web 前端。
type Server struct {
	cfg        *config.Config
	store      *store.Store
	backups    *store.BackupManager
	engine     *collector.Engine
	vnstat     *collector.VnstatClient
	quotaSvc   *quota.Service
	updater    *updater.Manager
	hub        *cluster.Hub
	log        *logger.Manager
	loginGuard *LoginProtector
	startedAt  time.Time

	rlMu      sync.Mutex
	rlBuckets map[string]*rateBucket

	setupMu sync.Mutex
	webSub  fs.FS
}

// NewServer 初始化 HTTP 服务并在配置了 ADMIN_PASSWORD 时引导初始口令。
func NewServer(
	cfg *config.Config,
	st *store.Store,
	bm *store.BackupManager,
	eng *collector.Engine,
	vn *collector.VnstatClient,
	qs *quota.Service,
	log *logger.Manager,
	opts ...any,
) (*Server, error) {
	sub, err := fs.Sub(flowmaster.WebDistFS, "web/dist")
	if err != nil {
		return nil, fmt.Errorf("挂载内嵌前端静态资源失败: %w", err)
	}

	if cfg.AdminPassword != "" && st.GetAdminPasswordHash() == "" {
		hash, hErr := HashPassword(cfg.AdminPassword)
		if hErr != nil {
			return nil, fmt.Errorf("初始化环境变量 ADMIN_PASSWORD 失败: %w", hErr)
		}
		if err := st.SaveAdminPasswordHash(hash); err != nil {
			return nil, err
		}
		log.Info("已从环境变量 ADMIN_PASSWORD 初始化管理员登录密码")
	}

	var up *updater.Manager
	var hb *cluster.Hub
	for _, opt := range opts {
		switch v := opt.(type) {
		case *updater.Manager:
			up = v
		case *cluster.Hub:
			hb = v
		}
	}
	if up == nil {
		up = updater.NewManager(log, nil)
	}
	if hb == nil {
		hb = cluster.NewHub(cfg, st, eng, qs, up, log)
	}

	return &Server{
		cfg:        cfg,
		store:      st,
		backups:    bm,
		engine:     eng,
		vnstat:     vn,
		quotaSvc:   qs,
		updater:    up,
		hub:        hb,
		log:        log,
		loginGuard: NewLoginProtector(),
		startedAt:  time.Now(),
		rlBuckets:  make(map[string]*rateBucket),
		webSub:     sub,
	}, nil
}

// Handler 构建完整的中间件链与路由表。
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()

	// 兼容旧版 /api/* 端点
	s.registerLegacyCompatRoutes(mux)

	// 多机集群总览、被控上报与远程控制端点
	s.registerClusterRoutes(mux)

	// 现代公开与鉴权 /api/v1/* 端点
	mux.HandleFunc("GET /api/v1/bootstrap", s.handleBootstrap)
	mux.HandleFunc("POST /api/v1/auth/setup", s.handleAuthSetup)
	mux.HandleFunc("POST /api/v1/auth/login", s.handleAuthLogin)
	mux.HandleFunc("POST /api/v1/auth/logout", s.handleAuthLogout)
	mux.HandleFunc("POST /api/v1/auth/password", s.requireAdmin(s.handleChangePassword))

	mux.HandleFunc("GET /api/v1/interfaces", s.requireViewAccess(s.handleV1Interfaces))
	mux.HandleFunc("GET /api/v1/realtime/{interface}", s.requireViewAccess(s.handleV1Realtime))
	mux.HandleFunc("GET /api/v1/stream/realtime", s.requireViewAccess(s.handleV1RealtimeStream))
	mux.HandleFunc("GET /api/v1/stats/{interface}/{period}", s.requireViewAccess(s.handleV1Stats))
	mux.HandleFunc("GET /api/v1/stats/{interface}/range/{startDate}/{endDate}", s.requireViewAccess(s.handleV1Range))
	mux.HandleFunc("GET /api/v1/quota/status", s.requireViewAccess(s.handleV1QuotaStatus))

	// 管理员后台端点
	mux.HandleFunc("GET /api/v1/admin/overview", s.requireAdmin(s.handleAdminOverview))
	mux.HandleFunc("GET /api/v1/admin/settings", s.requireAdmin(s.handleAdminGetSettings))
	mux.HandleFunc("PUT /api/v1/admin/settings", s.requireAdmin(s.handleAdminSaveSettings))
	mux.HandleFunc("PUT /api/v1/admin/alerts", s.requireAdmin(s.handleAdminSaveAlerts))
	mux.HandleFunc("POST /api/v1/admin/alerts/test", s.requireAdmin(s.handleAdminTestAlert))

	mux.HandleFunc("GET /api/v1/admin/interfaces", s.requireAdmin(s.handleAdminListInterfaces))
	mux.HandleFunc("PUT /api/v1/admin/interfaces/{name}", s.requireAdmin(s.handleAdminUpdateInterface))

	mux.HandleFunc("GET /api/v1/admin/backups", s.requireAdmin(s.handleAdminListBackups))
	mux.HandleFunc("POST /api/v1/admin/backups", s.requireAdmin(s.handleAdminCreateBackup))
	mux.HandleFunc("GET /api/v1/admin/backups/{name}/download", s.requireAdmin(s.handleAdminDownloadBackup))
	mux.HandleFunc("POST /api/v1/admin/backups/{name}/restore", s.requireAdmin(s.handleAdminRestoreBackup))
	mux.HandleFunc("POST /api/v1/admin/backups/upload-restore", s.requireAdmin(s.handleAdminUploadRestore))
	mux.HandleFunc("DELETE /api/v1/admin/backups/{name}", s.requireAdmin(s.handleAdminDeleteBackup))

	mux.HandleFunc("GET /api/v1/admin/config/export", s.requireAdmin(s.handleAdminExportConfig))
	mux.HandleFunc("POST /api/v1/admin/config/import", s.requireAdmin(s.handleAdminImportConfig))
	mux.HandleFunc("POST /api/v1/admin/vnstat/import", s.requireAdmin(s.handleAdminImportVnstat))
	mux.HandleFunc("POST /api/v1/admin/data/reset", s.requireAdmin(s.handleAdminResetData))
	mux.HandleFunc("GET /api/v1/admin/logs", s.requireAdmin(s.handleAdminLogs))

	// 未匹配的 /api 路径统一返回 JSON 404
	mux.HandleFunc("/api/", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": "API 路径不存在"})
	})

	// 静态资源与 SPA 路由兜底
	mux.HandleFunc("/", s.handleSPAStatic)

	return s.withSecurityHeaders(s.withCORS(s.withRateLimit(mux)))
}

func (s *Server) withSecurityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
		// 生产编译版前端无需 unsafe-eval，彻底收紧脚本执行策略。
		h.Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'none'")
		next.ServeHTTP(w, r)
	})
}

func (s *Server) withCORS(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if len(s.cfg.CORSOrigins) == 0 {
			next.ServeHTTP(w, r)
			return
		}
		origin := r.Header.Get("Origin")
		if origin == "" {
			next.ServeHTTP(w, r)
			return
		}
		if !slices.Contains(s.cfg.CORSOrigins, origin) {
			writeJSON(w, http.StatusForbidden, map[string]any{"error": "请求来源不在 CORS 白名单中"})
			return
		}
		w.Header().Set("Access-Control-Allow-Origin", origin)
		w.Header().Set("Vary", "Origin")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, X-Admin-Token, X-Requested-With")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) withRateLimit(next http.Handler) http.Handler {
	window := time.Duration(s.cfg.RateLimitWindowMs) * time.Millisecond
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.URL.Path, "/api") || strings.HasPrefix(r.URL.Path, "/api/v1/cluster/agent/") || strings.HasPrefix(r.URL.Path, "/api/v1/cluster/dist/") {
			next.ServeHTTP(w, r)
			return
		}
		ip := extractClientIP(r, s.cfg.TrustProxy)
		now := time.Now()

		s.rlMu.Lock()
		b, ok := s.rlBuckets[ip]
		if !ok || !now.Before(b.resetAt) {
			if len(s.rlBuckets) >= s.cfg.RateLimitMaxClients {
				for k, v := range s.rlBuckets {
					if !now.Before(v.resetAt) {
						delete(s.rlBuckets, k)
					}
					if len(s.rlBuckets) < s.cfg.RateLimitMaxClients {
						break
					}
				}
				if len(s.rlBuckets) >= s.cfg.RateLimitMaxClients {
					for k := range s.rlBuckets {
						delete(s.rlBuckets, k)
						break
					}
				}
			}
			s.rlBuckets[ip] = &rateBucket{count: 1, resetAt: now.Add(window)}
			s.rlMu.Unlock()
			next.ServeHTTP(w, r)
			return
		}
		b.count++
		count := b.count
		resetAt := b.resetAt
		s.rlMu.Unlock()

		if count > s.cfg.RateLimitMax {
			retrySec := max(1, int(resetAt.Sub(now).Seconds())+1)
			w.Header().Set("Retry-After", strconv.Itoa(retrySec))
			writeJSON(w, http.StatusTooManyRequests, map[string]any{"error": "请求过于频繁，请稍后重试"})
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) isAuthenticated(r *http.Request) (authed bool, viaCookie bool) {
	if s.cfg.AdminToken != "" {
		if provided := r.Header.Get("X-Admin-Token"); timingSafeEqualStr(s.cfg.AdminToken, provided) {
			return true, false
		}
	}
	passHash := s.store.GetAdminPasswordHash()
	if passHash == "" {
		return false, false
	}
	c, err := r.Cookie(sessionCookieName)
	if err != nil || c.Value == "" {
		return false, false
	}
	if verifySessionToken(c.Value, s.cfg.SessionSecret, passHash, time.Now()) {
		return true, true
	}
	return false, false
}

func (s *Server) requireViewAccess(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		settings := s.store.GetSystemSettings()
		if !settings.RequireLoginForView {
			next(w, r)
			return
		}
		authed, _ := s.isAuthenticated(r)
		if !authed {
			writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "该站点已启用访问保护，请先登录"})
			return
		}
		next(w, r)
	}
}

func (s *Server) requireAdmin(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		authed, viaCookie := s.isAuthenticated(r)
		if !authed {
			if s.store.GetAdminPasswordHash() == "" && s.cfg.AdminToken == "" {
				writeJSON(w, http.StatusForbidden, map[string]any{
					"error":      "尚未设置管理员密码，请先完成首次初始化",
					"needsSetup": true,
				})
				return
			}
			writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "需要管理员登录或有效凭据"})
			return
		}
		if viaCookie && !checkSameOriginForCookieStateChange(r) {
			writeJSON(w, http.StatusForbidden, map[string]any{"error": "拒绝跨站管理请求"})
			return
		}
		next(w, r)
	}
}

// requireLegacyAdmin 兼容旧版 ALLOW_ANONYMOUS_ADMIN 行为与现代会话登录。
func (s *Server) requireLegacyAdmin(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		authed, viaCookie := s.isAuthenticated(r)
		if authed {
			if viaCookie && !checkSameOriginForCookieStateChange(r) {
				writeJSON(w, http.StatusForbidden, map[string]any{"error": "拒绝跨站管理请求"})
				return
			}
			next(w, r)
			return
		}
		if s.cfg.AdminToken == "" && s.cfg.AllowAnonymousAdmin {
			if origin := r.Header.Get("Origin"); origin != "" {
				u, err := url.Parse(origin)
				if err != nil || !strings.EqualFold(u.Host, r.Host) {
					writeJSON(w, http.StatusForbidden, map[string]any{"error": "拒绝跨站管理请求"})
					return
				}
			}
			next(w, r)
			return
		}
		if s.cfg.AdminToken != "" {
			writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "需要管理员凭据"})
			return
		}
		writeJSON(w, http.StatusForbidden, map[string]any{"error": "匿名管理接口已禁用"})
	}
}

func (s *Server) handleBootstrap(w http.ResponseWriter, r *http.Request) {
	settings := s.store.GetSystemSettings()
	authed, _ := s.isAuthenticated(r)
	needsSetup := s.store.GetAdminPasswordHash() == ""
	vnAvail, vnVer := s.engine.VnstatStatus(r.Context())
	nodeRecords, _ := s.store.ListClusterNodes()

	writeJSON(w, http.StatusOK, map[string]any{
		"appName":             flowmaster.AppName(),
		"version":             flowmaster.AppVersion(),
		"siteTitle":           settings.SiteTitle,
		"requireLoginForView": settings.RequireLoginForView,
		"dataSourceMode":      settings.DataSourceMode,
		"authenticated":       authed,
		"needsSetup":          needsSetup,
		"vnstatAvailable":     vnAvail,
		"vnstatVersion":       vnVer,
		"realtimeIntervalMs":  s.cfg.RealtimeIntervalMs,
		"remoteNodeCount":     len(nodeRecords),
		"connectedToHub":      s.cfg.HubURL != "",
	})
}

func (s *Server) handleAuthSetup(w http.ResponseWriter, r *http.Request) {
	if !checkSameOriginForCookieStateChange(r) {
		writeJSON(w, http.StatusForbidden, map[string]any{"error": "拒绝跨站初始化请求"})
		return
	}
	s.setupMu.Lock()
	defer s.setupMu.Unlock()

	if s.store.GetAdminPasswordHash() != "" {
		writeJSON(w, http.StatusConflict, map[string]any{"error": "管理员密码已存在，请直接登录"})
		return
	}
	var req struct {
		Password string `json:"password"`
	}
	if err := readJSONBody(r, &req, 16*1024); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	hash, err := HashPassword(strings.TrimSpace(req.Password))
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	if err := s.store.SaveAdminPasswordHash(hash); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "保存管理员密码失败"})
		return
	}

	exp := time.Now().Add(sessionTTL).Unix()
	token := signSessionToken(s.cfg.SessionSecret, hash, exp)
	writeSessionCookie(w, r, token, int(sessionTTL.Seconds()), s.cfg.TrustProxy)
	s.log.Info("已完成后台管理员初始密码设置 (来源 IP: %s)", extractClientIP(r, s.cfg.TrustProxy))
	writeJSON(w, http.StatusOK, map[string]any{"authenticated": true})
}

func (s *Server) handleAuthLogin(w http.ResponseWriter, r *http.Request) {
	if !checkSameOriginForCookieStateChange(r) {
		writeJSON(w, http.StatusForbidden, map[string]any{"error": "拒绝跨站登录请求"})
		return
	}
	ip := extractClientIP(r, s.cfg.TrustProxy)
	now := time.Now()
	if locked, rem := s.loginGuard.CheckLocked(ip, now); locked {
		w.Header().Set("Retry-After", strconv.Itoa(rem))
		writeJSON(w, http.StatusTooManyRequests, map[string]any{
			"error": fmt.Sprintf("登录尝试过多，请 %d 秒后再试", rem),
		})
		return
	}

	var req struct {
		Password string `json:"password"`
	}
	if err := readJSONBody(r, &req, 16*1024); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}

	passHash := s.store.GetAdminPasswordHash()
	matched := false
	if passHash != "" && VerifyPassword(req.Password, passHash) {
		matched = true
	} else if passHash == "" && s.cfg.AdminToken != "" && timingSafeEqualStr(s.cfg.AdminToken, req.Password) {
		// 仅配置了 ADMIN_TOKEN 尚未初始化独立密码时，支持用 ADMIN_TOKEN 直接登录管理台
		matched = true
	}

	if !matched {
		locked, rem := s.loginGuard.RecordFailure(ip, now)
		s.log.Warn("后台管理员登录失败 (IP: %s)", ip)
		if locked {
			w.Header().Set("Retry-After", strconv.Itoa(rem))
			writeJSON(w, http.StatusTooManyRequests, map[string]any{
				"error": fmt.Sprintf("连续输错次数超限，当前 IP 已锁定 %d 分钟", int(loginLockDuration.Minutes())),
			})
			return
		}
		writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "管理员密码错误"})
		return
	}

	s.loginGuard.Reset(ip)
	// 若使用 ADMIN_TOKEN 登录且数据库无密码哈希，为其写入派生会话
	if passHash == "" && s.cfg.AdminToken != "" {
		if h, err := HashPassword(s.cfg.AdminToken); err == nil {
			_ = s.store.SaveAdminPasswordHash(h)
			passHash = h
		}
	}
	exp := now.Add(sessionTTL).Unix()
	token := signSessionToken(s.cfg.SessionSecret, passHash, exp)
	writeSessionCookie(w, r, token, int(sessionTTL.Seconds()), s.cfg.TrustProxy)
	s.log.Info("管理员登录成功 (IP: %s)", ip)
	writeJSON(w, http.StatusOK, map[string]any{"authenticated": true})
}

func (s *Server) handleAuthLogout(w http.ResponseWriter, r *http.Request) {
	if !checkSameOriginForCookieStateChange(r) {
		writeJSON(w, http.StatusForbidden, map[string]any{"error": "拒绝跨站退出请求"})
		return
	}
	writeSessionCookie(w, r, "", -1, s.cfg.TrustProxy)
	writeJSON(w, http.StatusOK, map[string]any{"authenticated": false})
}

func (s *Server) handleChangePassword(w http.ResponseWriter, r *http.Request) {
	var req struct {
		CurrentPassword string `json:"currentPassword"`
		NewPassword     string `json:"newPassword"`
	}
	if err := readJSONBody(r, &req, 16*1024); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	existing := s.store.GetAdminPasswordHash()
	if existing != "" && !VerifyPassword(req.CurrentPassword, existing) {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "当前密码不正确"})
		return
	}
	newHash, err := HashPassword(strings.TrimSpace(req.NewPassword))
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	if err := s.store.SaveAdminPasswordHash(newHash); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "更新密码失败"})
		return
	}
	exp := time.Now().Add(sessionTTL).Unix()
	token := signSessionToken(s.cfg.SessionSecret, newHash, exp)
	writeSessionCookie(w, r, token, int(sessionTTL.Seconds()), s.cfg.TrustProxy)
	s.log.Info("管理员已修改后台登录密码")
	writeJSON(w, http.StatusOK, map[string]any{"message": "密码已更新"})
}

func (s *Server) handleV1Interfaces(w http.ResponseWriter, r *http.Request) {
	list, err := s.engine.ListInterfaces(r.Context(), false)
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": "无法读取可用网络接口"})
		return
	}
	if authed, _ := s.isAuthenticated(r); !authed {
		for i := range list {
			list[i].IPv4 = nil
			list[i].IPv6 = nil
			list[i].MAC = ""
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"interfaces": list})
}

func (s *Server) handleV1Realtime(w http.ResponseWriter, r *http.Request) {
	iface := r.PathValue("interface")
	hist, latest, err := s.engine.GetRealtimeHistory(r.Context(), iface)
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"interface": iface,
		"latest":    latest,
		"history":   hist,
	})
}

func (s *Server) handleV1RealtimeStream(w http.ResponseWriter, r *http.Request) {
	iface := strings.TrimSpace(r.URL.Query().Get("interface"))
	nodeID := strings.TrimSpace(r.URL.Query().Get("node"))
	if !collector.IsValidInterfaceName(iface) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "无效的接口名称"})
		return
	}
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "不支持流式响应"})
		return
	}
	isRemote := nodeID != "" && nodeID != "local"
	if isRemote {
		if authed, _ := s.isAuthenticated(r); !authed {
			writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "请先登录后查看远程节点实时流"})
			return
		}
	}
	// 长连接 SSE 流取消固定写超时，防止长流正常推送被服务端超时断开。
	rc := http.NewResponseController(w)
	_ = rc.SetWriteDeadline(time.Time{})

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")

	if isRemote {
		if hist, _, err := s.hub.GetRemoteRealtimeHistory(nodeID, iface); err == nil {
			initPayload, _ := json.Marshal(map[string]any{"type": "init", "history": hist})
			fmt.Fprintf(w, "data: %s\n\n", initPayload)
			flusher.Flush()
		}
	} else {
		if hist, _, err := s.engine.GetRealtimeHistory(r.Context(), iface); err == nil {
			initPayload, _ := json.Marshal(map[string]any{"type": "init", "history": hist})
			fmt.Fprintf(w, "data: %s\n\n", initPayload)
			flusher.Flush()
		}
	}

	var sub chan map[string]model.RealtimeSample
	if isRemote {
		sub = s.hub.SubscribeRemoteRealtime(nodeID)
		defer s.hub.UnsubscribeRemoteRealtime(nodeID, sub)
	} else {
		sub = s.engine.SubscribeRealtime()
		defer s.engine.UnsubscribeRealtime(sub)
	}

	keepAlive := time.NewTicker(20 * time.Second)
	defer keepAlive.Stop()

	for {
		select {
		case <-r.Context().Done():
			return
		case <-keepAlive.C:
			fmt.Fprintf(w, ": ping %d\n\n", time.Now().Unix())
			flusher.Flush()
		case batch, open := <-sub:
			if !open {
				return
			}
			sample, exists := batch[iface]
			if !exists {
				continue
			}
			encoded, err := json.Marshal(map[string]any{"type": "sample", "sample": sample})
			if err != nil {
				continue
			}
			if _, err := fmt.Fprintf(w, "data: %s\n\n", encoded); err != nil {
				return
			}
			flusher.Flush()
		}
	}
}

func (s *Server) handleV1Stats(w http.ResponseWriter, r *http.Request) {
	iface := r.PathValue("interface")
	period := r.PathValue("period")
	if !collector.IsValidInterfaceName(iface) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "无效的接口名称"})
		return
	}
	switch period {
	case "5", "h", "d", "m", "y":
	default:
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "无效的时间周期"})
		return
	}
	sourceOverride := strings.TrimSpace(r.URL.Query().Get("source"))
	if sourceOverride != "" && sourceOverride != model.SourceModeHybrid && sourceOverride != model.SourceModeSQLite && sourceOverride != model.SourceModeVnstat {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "无效的数据源参数"})
		return
	}
	limit := config.ParseIntInRange(r.URL.Query().Get("limit"), 0, 1, 5000)

	res, err := s.engine.QueryStats(r.Context(), iface, period, sourceOverride, limit)
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": "暂时无法读取统计数据"})
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (s *Server) handleV1Range(w http.ResponseWriter, r *http.Request) {
	iface := r.PathValue("interface")
	startStr := r.PathValue("startDate")
	endStr := r.PathValue("endDate")
	if !collector.IsValidInterfaceName(iface) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "无效的接口名称"})
		return
	}
	startDate, ok1 := parseStrictISODate(startStr)
	endDate, ok2 := parseStrictISODate(endStr)
	if !ok1 || !ok2 {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "无效的日期格式，请使用 YYYY-MM-DD"})
		return
	}
	if startDate.After(endDate) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "开始日期不能晚于结束日期"})
		return
	}
	days := int(endDate.Sub(startDate).Hours()/24) + 1
	if days > s.cfg.MaxRangeDays {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": fmt.Sprintf("日期范围不能超过 %d 天", s.cfg.MaxRangeDays)})
		return
	}
	sourceOverride := strings.TrimSpace(r.URL.Query().Get("source"))
	res, err := s.engine.QueryRange(r.Context(), iface, startStr, endStr, sourceOverride)
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": "暂时无法读取日期范围数据"})
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (s *Server) handleV1QuotaStatus(w http.ResponseWriter, r *http.Request) {
	st, err := s.quotaSvc.Evaluate(r.Context(), time.Now())
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": "计算月度流量配额失败"})
		return
	}
	writeJSON(w, http.StatusOK, st)
}

func (s *Server) handleAdminOverview(w http.ResponseWriter, r *http.Request) {
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	vnAvail, vnVer := s.engine.VnstatStatus(r.Context())
	hostname, _ := os.Hostname()

	writeJSON(w, http.StatusOK, map[string]any{
		"appVersion":      flowmaster.AppVersion(),
		"goVersion":       runtime.Version(),
		"platform":        runtime.GOOS,
		"arch":            runtime.GOARCH,
		"hostname":        hostname,
		"uptimeSeconds":   int64(time.Since(s.startedAt).Seconds()),
		"goroutines":      runtime.NumGoroutine(),
		"memorySysBytes":  ms.Sys,
		"heapAllocBytes":  ms.HeapAlloc,
		"heapInuseBytes":  ms.HeapInuse,
		"dbSizeBytes":     s.store.DBFileSize(),
		"dataDir":         s.cfg.DataDir,
		"vnstatAvailable": vnAvail,
		"vnstatVersion":   vnVer,
	})
}

func (s *Server) handleAdminGetSettings(w http.ResponseWriter, r *http.Request) {
	sys := s.store.GetSystemSettings()
	qt := s.store.GetQuotaConfig()
	al := s.store.GetAlertConfig()

	offlineGrace := al.OfflineGraceSec
	if offlineGrace < 30 {
		offlineGrace = 60
	}
	alertView := model.AlertConfigView{
		Enabled:               al.Enabled,
		WebhookURL:            al.WebhookURL,
		HasWebhookSecret:      strings.TrimSpace(al.WebhookSecret) != "",
		WebhookSecretMask:     quota.MaskSecret(al.WebhookSecret),
		HasTelegramBotToken:   strings.TrimSpace(al.TelegramBotToken) != "",
		TelegramBotTokenMask:  quota.MaskSecret(al.TelegramBotToken),
		TelegramChatID:        al.TelegramChatID,
		AllowPrivateNetwork:   al.AllowPrivateNetwork,
		NotifyOnWarn:          al.NotifyOnWarn,
		NotifyOnLimit:         al.NotifyOnLimit,
		ClusterMonitorEnabled: al.ClusterMonitorEnabled,
		NotifyNodeOffline:     al.NotifyNodeOffline,
		OfflineGraceSec:       offlineGrace,
		NotifyRemoteQuota:     al.NotifyRemoteQuota,
		DiskWarnPercent:       al.DiskWarnPercent,
		MemWarnPercent:        al.MemWarnPercent,
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"system": sys,
		"quota":  qt,
		"alerts": alertView,
	})
}

func (s *Server) handleAdminSaveSettings(w http.ResponseWriter, r *http.Request) {
	var req struct {
		System *model.SystemSettings `json:"system"`
		Quota  *model.QuotaConfig    `json:"quota"`
	}
	if err := readJSONBody(r, &req, 64*1024); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}

	if req.System != nil {
		sys := *req.System
		sys.SiteTitle = strings.TrimSpace(sys.SiteTitle)
		if sys.SiteTitle == "" {
			sys.SiteTitle = "FlowMaster 流量监控"
		}
		if len([]rune(sys.SiteTitle)) > 48 {
			sys.SiteTitle = string([]rune(sys.SiteTitle)[:48])
		}
		switch sys.DataSourceMode {
		case model.SourceModeHybrid, model.SourceModeSQLite, model.SourceModeVnstat:
		default:
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": "无效的数据源引擎模式"})
			return
		}
		if sys.DefaultInterface != "" && !collector.IsValidInterfaceName(sys.DefaultInterface) {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": "默认网卡名称格式无效"})
			return
		}
		sys.PublicHubURL = strings.TrimRight(strings.TrimSpace(sys.PublicHubURL), "/")
		sys.Retention5mDays = clampInt(sys.Retention5mDays, 1, 90)
		sys.RetentionHourlyDays = clampInt(sys.RetentionHourlyDays, 7, 1095)
		sys.RetentionDailyDays = clampInt(sys.RetentionDailyDays, 30, 36525)
		sys.MaxBackups = clampInt(sys.MaxBackups, 1, 200)
		sys.MaxProtectSnapshots = clampInt(sys.MaxProtectSnapshots, 1, 100)

		if err := s.store.SaveSystemSettings(sys); err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "保存系统设置失败"})
			return
		}
	}

	if req.Quota != nil {
		qt := *req.Quota
		qt.ResetDay = clampInt(qt.ResetDay, 1, 31)
		qt.WarnPercent = clampInt(qt.WarnPercent, 1, 99)
		if qt.MonthlyLimitBytes < 0 {
			qt.MonthlyLimitBytes = 0
		}
		switch qt.Direction {
		case model.QuotaDirBoth, model.QuotaDirTX, model.QuotaDirRX, model.QuotaDirMax:
		default:
			qt.Direction = model.QuotaDirBoth
		}
		if qt.Interface != "" && qt.Interface != "__all__" && !collector.IsValidInterfaceName(qt.Interface) {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": "配额绑定网卡名称无效"})
			return
		}
		if err := s.store.SaveQuotaConfig(qt); err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "保存流量配额配置失败"})
			return
		}
	}

	s.log.Info("管理员已更新系统与流量配额配置")
	s.handleAdminGetSettings(w, r)
}

func (s *Server) handleAdminSaveAlerts(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Enabled               bool   `json:"enabled"`
		WebhookURL            string `json:"webhookUrl"`
		WebhookSecret         string `json:"webhookSecret"`
		ClearWebhookSecret    bool   `json:"clearWebhookSecret"`
		TelegramBotToken      string `json:"telegramBotToken"`
		ClearTelegramBotToken bool   `json:"clearTelegramBotToken"`
		TelegramChatID        string `json:"telegramChatId"`
		AllowPrivateNetwork   bool   `json:"allowPrivateNetwork"`
		NotifyOnWarn          bool   `json:"notifyOnWarn"`
		NotifyOnLimit         bool   `json:"notifyOnLimit"`
		ClusterMonitorEnabled bool   `json:"clusterMonitorEnabled"`
		NotifyNodeOffline     bool   `json:"notifyNodeOffline"`
		OfflineGraceSec       int    `json:"offlineGraceSec"`
		NotifyRemoteQuota     bool   `json:"notifyRemoteQuota"`
		DiskWarnPercent       int    `json:"diskWarnPercent"`
		MemWarnPercent        int    `json:"memWarnPercent"`
	}
	if err := readJSONBody(r, &req, 32*1024); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}

	current := s.store.GetAlertConfig()
	current.Enabled = req.Enabled
	current.WebhookURL = strings.TrimSpace(req.WebhookURL)
	current.TelegramChatID = strings.TrimSpace(req.TelegramChatID)
	current.AllowPrivateNetwork = req.AllowPrivateNetwork
	current.NotifyOnWarn = req.NotifyOnWarn
	current.NotifyOnLimit = req.NotifyOnLimit
	current.ClusterMonitorEnabled = req.ClusterMonitorEnabled
	current.NotifyNodeOffline = req.NotifyNodeOffline
	current.OfflineGraceSec = clampInt(req.OfflineGraceSec, 30, 3600)
	current.NotifyRemoteQuota = req.NotifyRemoteQuota
	current.DiskWarnPercent = clampInt(req.DiskWarnPercent, 0, 99)
	current.MemWarnPercent = clampInt(req.MemWarnPercent, 0, 99)

	if req.ClearWebhookSecret {
		current.WebhookSecret = ""
	} else if strings.TrimSpace(req.WebhookSecret) != "" {
		current.WebhookSecret = strings.TrimSpace(req.WebhookSecret)
	}

	if req.ClearTelegramBotToken {
		current.TelegramBotToken = ""
	} else if strings.TrimSpace(req.TelegramBotToken) != "" {
		current.TelegramBotToken = strings.TrimSpace(req.TelegramBotToken)
	}

	if err := s.store.SaveAlertConfig(current); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "保存告警配置失败"})
		return
	}
	s.log.Info("管理员已更新流量告警推送配置")
	s.handleAdminGetSettings(w, r)
}

func (s *Server) handleAdminTestAlert(w http.ResponseWriter, r *http.Request) {
	if err := s.quotaSvc.SendTestAlert(r.Context()); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"message": "测试通知已发送，请检查接收端"})
}

func (s *Server) handleAdminListInterfaces(w http.ResponseWriter, r *http.Request) {
	list, err := s.engine.ListInterfaces(r.Context(), true)
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": "读取网络接口列表失败"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"interfaces": list})
}

func (s *Server) handleAdminUpdateInterface(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	if !collector.IsValidInterfaceName(name) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "无效的接口名称"})
		return
	}
	var req struct {
		Alias   string `json:"alias"`
		Visible *bool  `json:"visible"`
	}
	if err := readJSONBody(r, &req, 16*1024); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	alias := strings.TrimSpace(req.Alias)
	if len([]rune(alias)) > 32 {
		alias = string([]rune(alias)[:32])
	}
	if err := s.store.SaveInterfaceOverride(model.InterfaceOverride{
		Name:    name,
		Alias:   alias,
		Visible: req.Visible,
	}); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "更新接口设置失败"})
		return
	}
	s.log.Info("管理员已更新网卡 %s 的显隐/备注配置", name)
	s.handleAdminListInterfaces(w, r)
}

func (s *Server) handleAdminListBackups(w http.ResponseWriter, r *http.Request) {
	list, err := s.backups.ListBackups()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "获取备份列表失败"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"backups": list})
}

func (s *Server) handleAdminCreateBackup(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Note string `json:"note"`
	}
	_ = readJSONBody(r, &req, 16*1024)
	note := strings.TrimSpace(req.Note)
	if len([]rune(note)) > 64 {
		note = string([]rune(note)[:64])
	}

	s.engine.FlushPending()
	snap, err := s.backups.CreateSnapshot(store.BackupKindManual, note, flowmaster.AppVersion())
	if err != nil {
		s.log.Error("创建数据备份失败: %v", err)
		writeJSON(w, http.StatusConflict, map[string]any{"error": err.Error()})
		return
	}
	s.log.Info("已创建一致性备份快照: %s (%d bytes)", snap.Name, snap.SizeBytes)
	writeJSON(w, http.StatusOK, map[string]any{"backup": snap})
}

func (s *Server) handleAdminDownloadBackup(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	fullPath, err := s.backups.ResolveBackupPath(name)
	if err != nil {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": err.Error()})
		return
	}
	w.Header().Set("Content-Type", "application/gzip")
	w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename=%q", name))
	http.ServeFile(w, r, fullPath)
}

func (s *Server) handleAdminRestoreBackup(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	var req struct {
		Confirm bool `json:"confirm"`
	}
	if err := readJSONBody(r, &req, 16*1024); err != nil || !req.Confirm {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "还原数据需要显式二次确认"})
		return
	}

	s.engine.FlushPending()
	protectSnap, err := s.backups.RestoreFromExisting(name, flowmaster.AppVersion())
	if err != nil {
		s.log.Error("从快照 %s 还原数据库失败: %v", name, err)
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	s.engine.ClearCaches()
	s.log.Warn("已从备份快照 %s 完成数据库还原（已留存保护快照 %s）", name, protectSnap.Name)
	writeJSON(w, http.StatusOK, map[string]any{
		"message":           "数据库还原成功",
		"protectiveBackup": protectSnap,
	})
}

func (s *Server) handleAdminUploadRestore(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 260*1024*1024)
	if err := r.ParseMultipartForm(32 * 1024 * 1024); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "解析上传备份文件失败或体积超限"})
		return
	}
	if r.FormValue("confirm") != "true" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "上传还原需要显式二次确认"})
		return
	}
	file, hdr, err := r.FormFile("file")
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "请选择要恢复的 .tar.gz 备份文件"})
		return
	}
	defer file.Close()

	s.engine.FlushPending()
	protectSnap, err := s.backups.RestoreFromUpload(file, flowmaster.AppVersion())
	if err != nil {
		s.log.Error("上传备份文件 %s 还原失败: %v", hdr.Filename, err)
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	s.engine.ClearCaches()
	s.log.Warn("已通过上传文件 %s 完成数据库还原（已留存保护快照 %s）", hdr.Filename, protectSnap.Name)
	writeJSON(w, http.StatusOK, map[string]any{
		"message":           "上传备份还原成功",
		"protectiveBackup": protectSnap,
	})
}

func (s *Server) handleAdminDeleteBackup(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	if err := s.backups.DeleteBackup(name); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	s.log.Info("管理员删除了备份文件: %s", name)
	writeJSON(w, http.StatusOK, map[string]any{"message": "备份已删除"})
}

func (s *Server) handleAdminExportConfig(w http.ResponseWriter, r *http.Request) {
	bundle, err := s.store.ExportConfig(flowmaster.AppVersion())
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "导出配置失败"})
		return
	}
	w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename=%q", "flowmaster-config.json"))
	writeJSON(w, http.StatusOK, bundle)
}

func (s *Server) handleAdminImportConfig(w http.ResponseWriter, r *http.Request) {
	var bundle store.ConfigExportBundle
	if err := readJSONBody(r, &bundle, 256*1024); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	if err := s.store.ImportConfig(bundle); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "导入配置失败"})
		return
	}
	s.log.Info("管理员导入了系统配置文件")
	writeJSON(w, http.StatusOK, map[string]any{"message": "配置导入成功"})
}

func (s *Server) handleAdminImportVnstat(w http.ResponseWriter, r *http.Request) {
	summary, err := s.engine.ImportVnstatToSQLite(r.Context())
	if err != nil {
		s.log.Error("导入系统 vnstat 历史数据失败: %v", err)
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	s.log.Info("已从系统 vnstat 幂等导入历史流量数据: %v", summary)
	writeJSON(w, http.StatusOK, map[string]any{
		"message":  "已成功将 vnstat 历史数据合并至内置数据库",
		"imported": summary,
	})
}

func (s *Server) handleAdminResetData(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Interface string `json:"interface"`
		Confirm   string `json:"confirm"`
	}
	if err := readJSONBody(r, &req, 16*1024); err != nil || req.Confirm != "RESET" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "重置流量统计必须输入精确确认词 RESET"})
		return
	}
	if req.Interface != "" && req.Interface != "__all__" && !collector.IsValidInterfaceName(req.Interface) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "无效的接口名称"})
		return
	}

	// 重置前强制留存保护备份，确保遵循“先备份后重置”铁律（且绝不触碰宿主机 /var/lib/vnstat）。
	s.engine.FlushPending()
	snap, err := s.backups.CreateSnapshot(store.BackupKindPreRestore, "重置内置流量统计前自动备份", flowmaster.AppVersion())
	if err != nil {
		writeJSON(w, http.StatusConflict, map[string]any{"error": "重置前自动创建保护备份失败: " + err.Error()})
		return
	}
	if err := s.store.ResetInterfaceTraffic(req.Interface); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "重置统计数据失败"})
		return
	}
	s.log.Warn("管理员重置了内置 SQLite 流量统计 (目标: %s, 保护快照: %s)", req.Interface, snap.Name)
	writeJSON(w, http.StatusOK, map[string]any{
		"message":          "内置流量数据已重置（系统 /var/lib/vnstat 未做任何修改）",
		"protectiveBackup": snap,
	})
}

func (s *Server) handleAdminLogs(w http.ResponseWriter, r *http.Request) {
	ch := strings.TrimSpace(r.URL.Query().Get("channel"))
	lvl := strings.TrimSpace(r.URL.Query().Get("level"))
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	limit := config.ParseIntInRange(r.URL.Query().Get("limit"), 200, 1, 500)

	entries := s.log.Query(ch, lvl, q, limit)
	writeJSON(w, http.StatusOK, map[string]any{
		"channel": ch,
		"entries": entries,
	})
}

func (s *Server) handleSPAStatic(w http.ResponseWriter, r *http.Request) {
	cleanPath := strings.TrimPrefix(path.Clean(r.URL.Path), "/")
	if cleanPath == "" || cleanPath == "." {
		cleanPath = "index.html"
	}

	data, err := fs.ReadFile(s.webSub, cleanPath)
	if err != nil {
		// 前端路由回退到 index.html
		cleanPath = "index.html"
		data, err = fs.ReadFile(s.webSub, "index.html")
		if err != nil {
			http.Error(w, "Frontend bundle missing", http.StatusNotFound)
			return
		}
	}

	switch {
	case strings.HasSuffix(cleanPath, ".html"):
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-cache")
	case strings.HasSuffix(cleanPath, ".js"):
		w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
		w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
	case strings.HasSuffix(cleanPath, ".css"):
		w.Header().Set("Content-Type", "text/css; charset=utf-8")
		w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
	case strings.HasSuffix(cleanPath, ".svg"):
		w.Header().Set("Content-Type", "image/svg+xml")
		w.Header().Set("Cache-Control", "public, max-age=86400")
	case strings.HasSuffix(cleanPath, ".png"):
		w.Header().Set("Content-Type", "image/png")
		w.Header().Set("Cache-Control", "public, max-age=86400")
	}

	if len(data) > 1024 && strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") {
		w.Header().Set("Content-Encoding", "gzip")
		w.Header().Set("Vary", "Accept-Encoding")
		gz := gzip.NewWriter(w)
		_, _ = gz.Write(data)
		_ = gz.Close()
		return
	}
	_, _ = w.Write(data)
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(true)
	_ = enc.Encode(payload)
}

func readJSONBody(r *http.Request, target any, maxBytes int64) error {
	defer r.Body.Close()
	limited := io.LimitReader(r.Body, maxBytes+1)
	raw, err := io.ReadAll(limited)
	if err != nil {
		return errors.New("读取请求体失败")
	}
	if int64(len(raw)) > maxBytes {
		return errors.New("请求体超过允许大小上限")
	}
	if len(strings.TrimSpace(string(raw))) == 0 {
		return errors.New("请求体不能为空")
	}
	dec := json.NewDecoder(strings.NewReader(string(raw)))
	if err := dec.Decode(target); err != nil {
		return errors.New("请求体不是有效的 JSON")
	}
	return nil
}

func parseStrictISODate(val string) (time.Time, bool) {
	if len(val) != 10 || val[4] != '-' || val[7] != '-' {
		return time.Time{}, false
	}
	t, err := time.ParseInLocation("2006-01-02", val, time.UTC)
	if err != nil || t.Format("2006-01-02") != val {
		return time.Time{}, false
	}
	return t, true
}

func clampInt(v, minVal, maxVal int) int {
	if v < minVal {
		return minVal
	}
	if v > maxVal {
		return maxVal
	}
	return v
}
