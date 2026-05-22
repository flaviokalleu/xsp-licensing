package system

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"time"
)

func RequireRoot() error {
	if runtime.GOOS != "linux" {
		return fmt.Errorf("este instalador suporta apenas Linux")
	}
	if os.Geteuid() != 0 {
		return fmt.Errorf("rode como root (use sudo)")
	}
	return nil
}

func DetectOS() (name, version string) {
	f, err := os.Open("/etc/os-release")
	if err != nil {
		return "linux", ""
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		if strings.HasPrefix(line, "ID=") {
			name = strings.Trim(strings.TrimPrefix(line, "ID="), `"`)
		}
		if strings.HasPrefix(line, "VERSION_ID=") {
			version = strings.Trim(strings.TrimPrefix(line, "VERSION_ID="), `"`)
		}
	}
	return
}

func RequireUbuntu(allowed ...string) error {
	name, ver := DetectOS()
	if name != "ubuntu" && name != "debian" {
		return fmt.Errorf("SO não suportado: %s (necessário Ubuntu/Debian)", name)
	}
	if len(allowed) == 0 {
		return nil
	}
	for _, a := range allowed {
		if strings.HasPrefix(ver, a) {
			return nil
		}
	}
	return fmt.Errorf("versão %s não suportada (esperado: %v)", ver, allowed)
}

func ScanPortsBusy(ports ...int) []int {
	var busy []int
	for _, p := range ports {
		ln, err := net.Listen("tcp", fmt.Sprintf(":%d", p))
		if err != nil {
			busy = append(busy, p)
			continue
		}
		ln.Close()
	}
	return busy
}

func Hostname() string {
	h, _ := os.Hostname()
	return h
}

func PublicIP() string {
	cli := &http.Client{Timeout: 4 * time.Second}
	for _, u := range []string{
		"https://api.ipify.org",
		"https://ifconfig.me/ip",
		"https://icanhazip.com",
	} {
		resp, err := cli.Get(u)
		if err == nil {
			b, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			ip := strings.TrimSpace(string(b))
			if net.ParseIP(ip) != nil {
				return ip
			}
		}
	}
	return ""
}

// ComputeHWID returns a stable hash:
// sha256( machine_id || 0x1f || board_uuid || 0x1f || disk_uuid || 0x1f || mac )
// IMPORTANTE: deve bater com xsp_compute_hwid() em license_check.php
// e com a função em install-painel.sh.
func ComputeHWID() (string, map[string]string) {
	parts := map[string]string{
		"machine_id": "",
		"board_uuid": boardUUID(),
		"disk_uuid":  rootDiskUUID(),
		"mac":        primaryMAC(),
		"cpu":        cpuModel(),
	}
	if b, err := os.ReadFile("/etc/machine-id"); err == nil {
		parts["machine_id"] = strings.TrimSpace(string(b))
	}
	sep := []byte{0x1f}
	h := sha256.New()
	h.Write([]byte(parts["machine_id"]))
	h.Write(sep)
	h.Write([]byte(parts["board_uuid"]))
	h.Write(sep)
	h.Write([]byte(parts["disk_uuid"]))
	h.Write(sep)
	h.Write([]byte(parts["mac"]))
	return hex.EncodeToString(h.Sum(nil)), parts
}

func primaryMAC() string {
	ifs, _ := net.Interfaces()
	for _, i := range ifs {
		if i.Flags&net.FlagLoopback != 0 || i.HardwareAddr == nil {
			continue
		}
		if i.Flags&net.FlagUp == 0 {
			continue
		}
		return i.HardwareAddr.String()
	}
	return ""
}

func rootDiskUUID() string {
	out, err := exec.Command("sh", "-c",
		"blkid -s UUID -o value $(findmnt -n -o SOURCE /) 2>/dev/null").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func boardUUID() string {
	b, err := os.ReadFile("/sys/class/dmi/id/product_uuid")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

func cpuModel() string {
	f, err := os.Open("/proc/cpuinfo")
	if err != nil {
		return ""
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		if strings.HasPrefix(line, "model name") {
			parts := strings.SplitN(line, ":", 2)
			if len(parts) == 2 {
				return strings.TrimSpace(parts[1])
			}
		}
	}
	return ""
}

// HealthCheck waits up to timeoutSec for url to return 2xx.
func HealthCheck(url string, timeoutSec int) error {
	cli := &http.Client{Timeout: 5 * time.Second}
	deadline := time.Now().Add(time.Duration(timeoutSec) * time.Second)
	for time.Now().Before(deadline) {
		resp, err := cli.Get(url)
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode >= 200 && resp.StatusCode < 400 {
				return nil
			}
		}
		time.Sleep(3 * time.Second)
	}
	return fmt.Errorf("health check failed for %s", url)
}

// Run executes a command, streaming combined output to stdout.
func Run(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

// RunOutput runs and captures combined output.
func RunOutput(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	out, err := cmd.CombinedOutput()
	return string(out), err
}
