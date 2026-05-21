//go:build !linux

package tamper

// AntiDebug é no-op em plataformas não-Linux (build dev no Windows/macOS).
func AntiDebug() error { return nil }
