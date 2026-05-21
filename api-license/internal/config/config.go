package config

import (
	"encoding/base64"
	"errors"
	"os"
	"strings"

	"github.com/joho/godotenv"
)

type Config struct {
	Env              string
	ListenAddr       string
	DatabaseURL      string
	RedisURL         string
	HMACSecret       []byte
	JWTSecret        []byte
	AdminToken       string
	Ed25519PrivB64   string
	Ed25519PubB64    string
	ReleaseVersion   string
	ReleaseMasterKey string
	RegistryURL      string
	RegistryUser     string
	RegistryPass     string
	StripeSecret     string
	StripeWHSecret   string
	MPAccessToken    string
	MPWebhookSecret  string
	MPDefaultPlan    string
	MPPeriodDays     int
	TLSCertFile      string
	TLSKeyFile       string
}

func Load() (*Config, error) {
	_ = godotenv.Load()

	c := &Config{
		Env:              getEnv("APP_ENV", "development"),
		ListenAddr:       getEnv("LISTEN_ADDR", ":8443"),
		DatabaseURL:      os.Getenv("DATABASE_URL"),
		RedisURL:         getEnv("REDIS_URL", "redis://localhost:6379/0"),
		AdminToken:       os.Getenv("ADMIN_TOKEN"),
		Ed25519PrivB64:   os.Getenv("ED25519_PRIVATE_KEY_B64"),
		Ed25519PubB64:    os.Getenv("ED25519_PUBLIC_KEY_B64"),
		ReleaseVersion:   getEnv("RELEASE_VERSION", "10.0.3"),
		ReleaseMasterKey: os.Getenv("RELEASE_MASTER_KEY"),
		RegistryURL:      os.Getenv("REGISTRY_URL"),
		RegistryUser:     os.Getenv("REGISTRY_USER"),
		RegistryPass:     os.Getenv("REGISTRY_PASSWORD"),
		StripeSecret:     os.Getenv("STRIPE_SECRET"),
		StripeWHSecret:   os.Getenv("STRIPE_WEBHOOK_SECRET"),
		MPAccessToken:    os.Getenv("MP_ACCESS_TOKEN"),
		MPWebhookSecret:  os.Getenv("MP_WEBHOOK_SECRET"),
		MPDefaultPlan:    getEnv("MP_DEFAULT_PLAN", "pro"),
		MPPeriodDays:     parseInt(os.Getenv("MP_PERIOD_DAYS"), 30),
		TLSCertFile:      os.Getenv("TLS_CERT_FILE"),
		TLSKeyFile:       os.Getenv("TLS_KEY_FILE"),
	}

	if c.DatabaseURL == "" {
		return nil, errors.New("DATABASE_URL not set")
	}
	if c.AdminToken == "" || len(c.AdminToken) < 16 {
		return nil, errors.New("ADMIN_TOKEN missing or too short")
	}

	var err error
	c.HMACSecret, err = decodeHex(os.Getenv("HMAC_PUBLIC_SECRET"))
	if err != nil {
		return nil, errors.New("HMAC_PUBLIC_SECRET invalid hex")
	}
	c.JWTSecret, err = decodeHex(os.Getenv("JWT_SECRET"))
	if err != nil {
		return nil, errors.New("JWT_SECRET invalid hex")
	}
	if len(c.HMACSecret) < 32 || len(c.JWTSecret) < 32 {
		return nil, errors.New("HMAC/JWT secrets must be >= 32 bytes")
	}
	if c.ReleaseMasterKey == "" || len(c.ReleaseMasterKey) != 64 {
		return nil, errors.New("RELEASE_MASTER_KEY must be 64 hex chars (32 bytes)")
	}
	if c.Ed25519PrivB64 == "" || c.Ed25519PubB64 == "" {
		return nil, errors.New("Ed25519 keys missing")
	}
	if _, err := base64.StdEncoding.DecodeString(c.Ed25519PrivB64); err != nil {
		return nil, errors.New("Ed25519 private key invalid base64")
	}
	return c, nil
}

func getEnv(k, def string) string {
	if v := strings.TrimSpace(os.Getenv(k)); v != "" {
		return v
	}
	return def
}

func decodeHex(s string) ([]byte, error) {
	if s == "" {
		return nil, errors.New("empty")
	}
	b := make([]byte, len(s)/2)
	_, err := hexDecode(b, s)
	return b, err
}

func hexDecode(dst []byte, src string) (int, error) {
	if len(src)%2 != 0 {
		return 0, errors.New("odd length")
	}
	for i := 0; i < len(src)/2; i++ {
		hi, err := unhex(src[2*i])
		if err != nil {
			return 0, err
		}
		lo, err := unhex(src[2*i+1])
		if err != nil {
			return 0, err
		}
		dst[i] = hi<<4 | lo
	}
	return len(src) / 2, nil
}

func parseInt(s string, def int) int {
	if s == "" {
		return def
	}
	n := 0
	for _, c := range s {
		if c < '0' || c > '9' {
			return def
		}
		n = n*10 + int(c-'0')
	}
	if n == 0 {
		return def
	}
	return n
}

func unhex(c byte) (byte, error) {
	switch {
	case '0' <= c && c <= '9':
		return c - '0', nil
	case 'a' <= c && c <= 'f':
		return c - 'a' + 10, nil
	case 'A' <= c && c <= 'F':
		return c - 'A' + 10, nil
	}
	return 0, errors.New("invalid hex char")
}
