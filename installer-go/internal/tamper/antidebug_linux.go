//go:build linux

package tamper

import (
	"errors"
	"os"
	"strings"
)

// AntiDebug detecta debugger anexado lendo /proc/self/status (TracerPid != 0).
// Não tenta auto-ptrace para manter portabilidade entre toolchains Go;
// se quiser hardening adicional, faça em CGO ou no painel-binario.
func AntiDebug() error {
	b, err := os.ReadFile("/proc/self/status")
	if err != nil {
		return nil
	}
	for _, line := range strings.Split(string(b), "\n") {
		if strings.HasPrefix(line, "TracerPid:") {
			val := strings.TrimSpace(strings.TrimPrefix(line, "TracerPid:"))
			if val != "0" {
				return errors.New("debugger detected (TracerPid=" + val + ")")
			}
			return nil
		}
	}
	return nil
}
