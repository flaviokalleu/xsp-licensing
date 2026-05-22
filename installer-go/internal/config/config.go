package config

// These constants are baked into the binary at build time via -ldflags
// e.g. -X 'github.com/xsp/installer/internal/config.APIBaseURL=https://license.seudominio.com'
var (
	Version            = "10.0.3"
	APIBaseURL         = "https://license.seudominio.com"
	HMACPublicSecret   = "REPLACE_AT_BUILD"
	RegistryURL        = "registry.seudominio.com"
	InstallPath        = "/opt/xsp"
	Ed25519PublicKeyB64 = "REPLACE_AT_BUILD"
)
