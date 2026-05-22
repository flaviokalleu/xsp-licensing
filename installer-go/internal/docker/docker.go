package docker

import (
	"fmt"
	"os/exec"
	"strings"

	"github.com/xsp/installer/internal/system"
)

func EnsureInstalled() error {
	if _, err := exec.LookPath("docker"); err == nil {
		return ensureCompose()
	}
	// Install via official convenience script
	cmds := [][]string{
		{"apt-get", "update", "-y"},
		{"apt-get", "install", "-y", "ca-certificates", "curl", "gnupg"},
		{"sh", "-c",
			"install -m 0755 -d /etc/apt/keyrings && " +
				"curl -fsSL https://download.docker.com/linux/ubuntu/gpg " +
				"| gpg --dearmor -o /etc/apt/keyrings/docker.gpg && " +
				"chmod a+r /etc/apt/keyrings/docker.gpg"},
		{"sh", "-c",
			`echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] ` +
				`https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" ` +
				`| tee /etc/apt/sources.list.d/docker.list > /dev/null`},
		{"apt-get", "update", "-y"},
		{"apt-get", "install", "-y", "docker-ce", "docker-ce-cli", "containerd.io",
			"docker-buildx-plugin", "docker-compose-plugin"},
		{"systemctl", "enable", "--now", "docker"},
	}
	for _, c := range cmds {
		if err := system.Run(c[0], c[1:]...); err != nil {
			return fmt.Errorf("docker install step %v failed: %w", c, err)
		}
	}
	return ensureCompose()
}

func ensureCompose() error {
	out, err := system.RunOutput("docker", "compose", "version")
	if err != nil || !strings.Contains(out, "Docker Compose") {
		return fmt.Errorf("docker compose plugin missing: %s", out)
	}
	return nil
}

func Login(registry, user, pass string) error {
	cmd := exec.Command("docker", "login", registry, "-u", user, "--password-stdin")
	cmd.Stdin = strings.NewReader(pass)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("docker login: %s: %w", out, err)
	}
	return nil
}

func Pull(ref string) error {
	return system.Run("docker", "pull", ref)
}

// VerifyDigest does `docker image inspect` and compares first RepoDigest sha.
func VerifyDigest(ref, expectedDigest string) error {
	if expectedDigest == "" {
		return nil // skip if not provided
	}
	out, err := system.RunOutput("docker", "image", "inspect",
		"--format={{index .RepoDigests 0}}", ref)
	if err != nil {
		return err
	}
	got := strings.TrimSpace(out)
	if !strings.Contains(got, expectedDigest) {
		return fmt.Errorf("digest mismatch for %s: expected %s got %s", ref, expectedDigest, got)
	}
	return nil
}

func ComposeUp(dir string) error {
	cmd := exec.Command("docker", "compose", "up", "-d")
	cmd.Dir = dir
	cmd.Stdout = nil
	cmd.Stderr = nil
	return system.Run("sh", "-c", "cd "+dir+" && docker compose up -d")
}

func ComposeDown(dir string) error {
	return system.Run("sh", "-c", "cd "+dir+" && docker compose down")
}
