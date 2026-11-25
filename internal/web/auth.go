package web

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	sessionCookieName = "fm_session"
	sessionTTL        = 7 * 24 * time.Hour
	pbkdf2Iterations  = 120000
	loginWindow       = 5 * time.Minute
	loginMaxFailures  = 5
	loginLockDuration = 15 * time.Minute
)

type loginAttempt struct {
	failures    int
	firstFailAt time.Time
	lockedUntil time.Time
}

// LoginProtector 实现基于客户端 IP 的登录防爆破限流器。
type LoginProtector struct {
	mu       sync.Mutex
	attempts map[string]*loginAttempt
}

func NewLoginProtector() *LoginProtector {
	return &LoginProtector{
		attempts: make(map[string]*loginAttempt),
	}
}

func (p *LoginProtector) CheckLocked(ip string, now time.Time) (bool, int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	rec, ok := p.attempts[ip]
	if !ok {
		return false, 0
	}
	if now.Before(rec.lockedUntil) {
		rem := max(1, int(rec.lockedUntil.Sub(now).Seconds()))
		return true, rem
	}
	if now.Sub(rec.firstFailAt) > loginWindow {
		delete(p.attempts, ip)
	}
	return false, 0
}

func (p *LoginProtector) RecordFailure(ip string, now time.Time) (locked bool, retryAfterSec int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if len(p.attempts) > 5000 {
		for k, v := range p.attempts {
			if now.After(v.lockedUntil) && now.Sub(v.firstFailAt) > loginWindow {
				delete(p.attempts, k)
			}
		}
	}
	rec, ok := p.attempts[ip]
	if !ok || now.Sub(rec.firstFailAt) > loginWindow {
		rec = &loginAttempt{failures: 1, firstFailAt: now}
		p.attempts[ip] = rec
		return false, 0
	}
	rec.failures++
	if rec.failures >= loginMaxFailures {
		rec.lockedUntil = now.Add(loginLockDuration)
		return true, int(loginLockDuration.Seconds())
	}
	return false, 0
}

func (p *LoginProtector) Reset(ip string) {
	p.mu.Lock()
	delete(p.attempts, ip)
	p.mu.Unlock()
}

// HashPassword 使用标准库实现的 PBKDF2-HMAC-SHA256 生成慢哈希口令摘要。
func HashPassword(password string) (string, error) {
	if len(password) < 6 {
		return "", errors.New("密码长度至少需要 6 个字符")
	}
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}
	dk := pbkdf2SHA256([]byte(password), salt, pbkdf2Iterations, 32)
	return fmt.Sprintf("pbkdf2$%d$%s$%s", pbkdf2Iterations, hex.EncodeToString(salt), hex.EncodeToString(dk)), nil
}

// VerifyPassword 常量时间校验明文密码与存储哈希。
func VerifyPassword(password, encodedHash string) bool {
	parts := strings.Split(encodedHash, "$")
	if len(parts) != 4 || parts[0] != "pbkdf2" {
		return false
	}
	iter, err := strconv.Atoi(parts[1])
	if err != nil || iter < 10000 || iter > 1000000 {
		return false
	}
	salt, err1 := hex.DecodeString(parts[2])
	expected, err2 := hex.DecodeString(parts[3])
	if err1 != nil || err2 != nil || len(expected) == 0 {
		return false
	}
	actual := pbkdf2SHA256([]byte(password), salt, iter, len(expected))
	return subtle.ConstantTimeCompare(actual, expected) == 1
}

// pbkdf2SHA256 纯标准库实现 RFC 2898 PBKDF2-HMAC-SHA256，避免引入额外第三方密码库。
func pbkdf2SHA256(password, salt []byte, iter, keyLen int) []byte {
	prf := func(key, data []byte) []byte {
		h := hmac.New(sha256.New, key)
		_, _ = h.Write(data)
		return h.Sum(nil)
	}
	numBlocks := (keyLen + sha256.Size - 1) / sha256.Size
	out := make([]byte, 0, numBlocks*sha256.Size)
	blockBuf := make([]byte, len(salt)+4)
	copy(blockBuf, salt)

	for block := 1; block <= numBlocks; block++ {
		blockBuf[len(salt)] = byte(block >> 24)
		blockBuf[len(salt)+1] = byte(block >> 16)
		blockBuf[len(salt)+2] = byte(block >> 8)
		blockBuf[len(salt)+3] = byte(block)

		u := prf(password, blockBuf)
		t := make([]byte, len(u))
		copy(t, u)
		for i := 1; i < iter; i++ {
			u = prf(password, u)
			for j := range t {
				t[j] ^= u[j]
			}
		}
		out = append(out, t...)
	}
	return out[:keyLen]
}

func passwordTag(passHash string) string {
	if passHash == "" {
		return "none"
	}
	sum := sha256.Sum256([]byte(passHash))
	return hex.EncodeToString(sum[:6])
}

func signSessionToken(secret []byte, passHash string, expiresAt int64) string {
	payload := fmt.Sprintf("admin|%d|%s", expiresAt, passwordTag(passHash))
	mac := hmac.New(sha256.New, secret)
	_, _ = mac.Write([]byte(payload))
	sig := hex.EncodeToString(mac.Sum(nil))
	raw := payload + "|" + sig
	return base64.RawURLEncoding.EncodeToString([]byte(raw))
}

func verifySessionToken(token string, secret []byte, currentPassHash string, now time.Time) bool {
	decoded, err := base64.RawURLEncoding.DecodeString(token)
	if err != nil {
		return false
	}
	parts := strings.Split(string(decoded), "|")
	if len(parts) != 4 || parts[0] != "admin" {
		return false
	}
	exp, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil || now.Unix() > exp {
		return false
	}
	if parts[2] != passwordTag(currentPassHash) {
		return false
	}
	payload := strings.Join(parts[:3], "|")
	mac := hmac.New(sha256.New, secret)
	_, _ = mac.Write([]byte(payload))
	expectedSig := hex.EncodeToString(mac.Sum(nil))
	return subtle.ConstantTimeCompare([]byte(expectedSig), []byte(parts[3])) == 1
}

func isRequestHTTPS(r *http.Request, trustProxy bool) bool {
	if r.TLS != nil {
		return true
	}
	if trustProxy {
		proto := strings.TrimSpace(strings.Split(r.Header.Get("X-Forwarded-Proto"), ",")[0])
		if strings.EqualFold(proto, "https") {
			return true
		}
	}
	return false
}

func writeSessionCookie(w http.ResponseWriter, r *http.Request, token string, maxAge int, trustProxy bool) {
	http.SetCookie(w, &http.Cookie{
		Name:     sessionCookieName,
		Value:    token,
		Path:     "/",
		MaxAge:   maxAge,
		HttpOnly: true,
		Secure:   isRequestHTTPS(r, trustProxy),
		SameSite: http.SameSiteLaxMode,
	})
}

func extractClientIP(r *http.Request, trustProxy bool) string {
	if trustProxy {
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			first := strings.TrimSpace(strings.Split(xff, ",")[0])
			if first != "" {
				return first
			}
		}
		if xri := strings.TrimSpace(r.Header.Get("X-Real-IP")); xri != "" {
			return xri
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err == nil && host != "" {
		return host
	}
	return r.RemoteAddr
}

func timingSafeEqualStr(expected, provided string) bool {
	if expected == "" || len(expected) != len(provided) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(expected), []byte(provided)) == 1
}

// checkSameOriginForCookieStateChange 对基于 Cookie 的写请求执行同源 / 自定义请求头双重校验，防御跨站伪造。
func checkSameOriginForCookieStateChange(r *http.Request) bool {
	if r.Method == http.MethodGet || r.Method == http.MethodHead || r.Method == http.MethodOptions {
		return true
	}
	if origin := r.Header.Get("Origin"); origin != "" {
		u, err := url.Parse(origin)
		if err != nil || !strings.EqualFold(u.Host, r.Host) {
			return false
		}
		return true
	}
	return strings.EqualFold(r.Header.Get("X-Requested-With"), "FlowMaster")
}
