package flowmaster

import (
	"embed"
	"strings"
	"sync"
)

//go:embed VERSION
var rawVersionFile string

//go:embed install.sh
var embeddedInstallScript []byte

//go:embed all:web/dist
var WebDistFS embed.FS

var (
	versionOnce sync.Once
	appName     = "FlowMaster"
	appVersion  = "0.0.0"
)

func parseVersionOnce() {
	versionOnce.Do(func() {
		for _, line := range strings.Split(rawVersionFile, "\n") {
			line = strings.TrimSpace(line)
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			parts := strings.SplitN(line, "=", 2)
			if len(parts) != 2 {
				continue
			}
			key := strings.TrimSpace(parts[0])
			val := strings.Trim(strings.TrimSpace(parts[1]), `"'`)
			switch key {
			case "APP_NAME":
				if val != "" {
					appName = val
				}
			case "APP_VERSION":
				if val != "" {
					appVersion = strings.TrimPrefix(val, "v")
				}
			}
		}
	})
}

// AppName 返回唯一版本源定义的应用名称。
func AppName() string {
	parseVersionOnce()
	return appName
}

// AppVersion 返回唯一版本源定义的三段式语义化版本号（不含前导 v）。
func AppVersion() string {
	parseVersionOnce()
	return appVersion
}

// InstallScript 返回编译期内嵌的 install.sh 脚本字节内容，供主控节点直接向被控机分发。
func InstallScript() []byte {
	return embeddedInstallScript
}
