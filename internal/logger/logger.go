package logger

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

// 日志通道常量：系统主日志与外部集成告警推送日志物理隔离。
const (
	ChannelSystem = "system"
	ChannelAlert  = "alert"
)

// 日志级别常量。
const (
	LevelInfo  = "INFO"
	LevelWarn  = "WARN"
	LevelError = "ERROR"
)

// Entry 表示单条结构化日志记录。
type Entry struct {
	Timestamp string `json:"timestamp"`
	Level     string `json:"level"`
	Channel   string `json:"channel"`
	Message   string `json:"message"`
}

var (
	telegramTokenRegex = regexp.MustCompile(`bot\d{5,}:[A-Za-z0-9_-]{20,}`)
	bearerTokenRegex   = regexp.MustCompile(`(?i)(bearer\s+)[A-Za-z0-9._~+/=-]{8,}`)
	querySecretRegex   = regexp.MustCompile(`(?i)([?&](?:token|secret|key|password|sign|sig)=)[^&\s]+`)
)

// Redact 对进入日志的消息执行敏感凭据脱敏。
func Redact(message string) string {
	out := telegramTokenRegex.ReplaceAllString(message, "bot***:***")
	out = bearerTokenRegex.ReplaceAllString(out, "${1}***")
	out = querySecretRegex.ReplaceAllString(out, "${1}***")
	return out
}

type channelBuffer struct {
	filePath   string
	maxBytes   int64
	maxBackups int
	ring       []Entry
	maxRing    int
}

// Manager 提供带文件大小轮转与内存快速检索的多通道日志器。
type Manager struct {
	mu       sync.Mutex
	logDir   string
	channels map[string]*channelBuffer
	echoStd  bool
}

// NewManager 初始化日志目录与各通道缓冲，并预热加载最近日志行。
func NewManager(dataDir string, echoStdout bool) (*Manager, error) {
	logDir := filepath.Join(dataDir, "logs")
	if err := os.MkdirAll(logDir, 0o750); err != nil {
		return nil, fmt.Errorf("创建日志目录失败: %w", err)
	}

	mgr := &Manager{
		logDir:   logDir,
		channels: make(map[string]*channelBuffer),
		echoStd:  echoStdout,
	}
	for _, ch := range []string{ChannelSystem, ChannelAlert} {
		cb := &channelBuffer{
			filePath:   filepath.Join(logDir, ch+".log"),
			maxBytes:   2 * 1024 * 1024, // 单文件上限 2 MiB
			maxBackups: 3,               // 最多保留 3 个轮转文件，严防爆盘
			maxRing:    500,
		}
		cb.preloadFromDisk()
		mgr.channels[ch] = cb
	}
	return mgr, nil
}

func (cb *channelBuffer) preloadFromDisk() {
	file, err := os.Open(cb.filePath)
	if err != nil {
		return
	}
	defer file.Close()

	var loaded []Entry
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		var entry Entry
		if err := json.Unmarshal(scanner.Bytes(), &entry); err == nil && entry.Timestamp != "" {
			loaded = append(loaded, entry)
			if len(loaded) > cb.maxRing {
				loaded = loaded[len(loaded)-cb.maxRing:]
			}
		}
	}
	cb.ring = loaded
}

func (cb *channelBuffer) appendEntry(entry Entry) {
	cb.ring = append(cb.ring, entry)
	if len(cb.ring) > cb.maxRing {
		cb.ring = cb.ring[len(cb.ring)-cb.maxRing:]
	}

	if info, err := os.Stat(cb.filePath); err == nil && info.Size() >= cb.maxBytes {
		cb.rotate()
	}

	encoded, err := json.Marshal(entry)
	if err != nil {
		return
	}
	f, err := os.OpenFile(cb.filePath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o640)
	if err != nil {
		return
	}
	_, _ = f.Write(append(encoded, '\n'))
	_ = f.Close()
}

func (cb *channelBuffer) rotate() {
	oldest := fmt.Sprintf("%s.%d", cb.filePath, cb.maxBackups)
	_ = os.Remove(oldest)
	for i := cb.maxBackups - 1; i >= 1; i-- {
		src := fmt.Sprintf("%s.%d", cb.filePath, i)
		dst := fmt.Sprintf("%s.%d", cb.filePath, i+1)
		if _, err := os.Stat(src); err == nil {
			_ = os.Rename(src, dst)
		}
	}
	_ = os.Rename(cb.filePath, cb.filePath+".1")
}

// Log 记录一条脱敏后的日志。
func (m *Manager) Log(channel, level, format string, args ...any) {
	msg := Redact(fmt.Sprintf(format, args...))
	entry := Entry{
		Timestamp: time.Now().Format(time.RFC3339),
		Level:     strings.ToUpper(level),
		Channel:   channel,
		Message:   msg,
	}

	m.mu.Lock()
	cb, ok := m.channels[channel]
	if !ok {
		cb = m.channels[ChannelSystem]
		entry.Channel = ChannelSystem
	}
	cb.appendEntry(entry)
	echo := m.echoStd
	m.mu.Unlock()

	if echo {
		fmt.Fprintf(os.Stdout, "[%s] [%s] [%s] %s\n", entry.Timestamp, entry.Channel, entry.Level, entry.Message)
	}
}

func (m *Manager) Info(format string, args ...any) {
	m.Log(ChannelSystem, LevelInfo, format, args...)
}

func (m *Manager) Warn(format string, args ...any) {
	m.Log(ChannelSystem, LevelWarn, format, args...)
}

func (m *Manager) Error(format string, args ...any) {
	m.Log(ChannelSystem, LevelError, format, args...)
}

func (m *Manager) AlertInfo(format string, args ...any) {
	m.Log(ChannelAlert, LevelInfo, format, args...)
}

func (m *Manager) AlertWarn(format string, args ...any) {
	m.Log(ChannelAlert, LevelWarn, format, args...)
}

func (m *Manager) AlertError(format string, args ...any) {
	m.Log(ChannelAlert, LevelError, format, args...)
}

// Query 按通道、级别和关键字过滤日志，严格按时间倒序返回（最新记录排在最前）。
func (m *Manager) Query(channel, level, keyword string, limit int) []Entry {
	if channel == "" {
		channel = ChannelSystem
	}
	if limit <= 0 || limit > 500 {
		limit = 200
	}
	upperLevel := strings.ToUpper(strings.TrimSpace(level))
	lowerKeyword := strings.ToLower(strings.TrimSpace(keyword))

	m.mu.Lock()
	cb, ok := m.channels[channel]
	if !ok {
		m.mu.Unlock()
		return []Entry{}
	}
	snapshot := make([]Entry, len(cb.ring))
	copy(snapshot, cb.ring)
	m.mu.Unlock()

	result := make([]Entry, 0, min(limit, len(snapshot)))
	for i := len(snapshot) - 1; i >= 0; i-- {
		item := snapshot[i]
		if upperLevel != "" && upperLevel != "ALL" && item.Level != upperLevel {
			continue
		}
		if lowerKeyword != "" && !strings.Contains(strings.ToLower(item.Message), lowerKeyword) {
			continue
		}
		result = append(result, item)
		if len(result) >= limit {
			break
		}
	}
	return result
}
