package middleware

import (
	"context"
	"crypto/subtle"
	"strconv"
	"time"

	"github.com/gofiber/fiber/v2"
	"github.com/xsp/api-license/internal/cache"
	"github.com/xsp/api-license/internal/crypto"
)

// HMACVerify checks X-Signature, X-Timestamp, X-Nonce against shared public HMAC.
// Body+ts+nonce is the signed payload.
func HMACVerify(secret []byte, c *cache.Cache, maxSkew time.Duration) fiber.Handler {
	return func(ctx *fiber.Ctx) error {
		sig := ctx.Get("X-Signature")
		ts := ctx.Get("X-Timestamp")
		nonce := ctx.Get("X-Nonce")
		if sig == "" || ts == "" || nonce == "" {
			return fiber.NewError(401, "missing_signature")
		}
		tsInt, err := strconv.ParseInt(ts, 10, 64)
		if err != nil || !crypto.WithinClockSkew(tsInt, maxSkew) {
			return fiber.NewError(401, "clock_skew")
		}
		// payload = method+path+body+ts+nonce
		payload := append([]byte(ctx.Method()+ctx.Path()), ctx.Body()...)
		payload = append(payload, []byte(ts+nonce)...)
		if !crypto.VerifyHMAC(secret, payload, sig) {
			return fiber.NewError(401, "signature_invalid")
		}
		// anti-replay
		cctx, cancel := context.WithTimeout(ctx.Context(), 1*time.Second)
		defer cancel()
		if err := c.RememberNonce(cctx, nonce, 5*time.Minute); err != nil {
			return fiber.NewError(401, "replay")
		}
		return ctx.Next()
	}
}

// RateLimitByIP simple per-route limiter.
func RateLimitByIP(c *cache.Cache, route string, max int, window time.Duration) fiber.Handler {
	return func(ctx *fiber.Ctx) error {
		key := route + ":" + ctx.IP()
		cctx, cancel := context.WithTimeout(ctx.Context(), 1*time.Second)
		defer cancel()
		ok, err := c.RateLimit(cctx, key, max, window)
		if err != nil {
			return ctx.Next()
		}
		if !ok {
			return fiber.NewError(429, "rate_limited")
		}
		return ctx.Next()
	}
}

// RateLimitByInstallation limita por X-Installation-ID em vez de IP.
// Quando o limite é atingido, retorna 200 OK silencioso em vez de 429,
// para que o cliente use o cache local sem ver nenhum erro.
func RateLimitByInstallation(c *cache.Cache, route string, max int, window time.Duration) fiber.Handler {
	return func(ctx *fiber.Ctx) error {
		id := ctx.Get("X-Installation-ID")
		if id == "" {
			id = ctx.IP()
		}
		key := route + ":inst:" + id
		cctx, cancel := context.WithTimeout(ctx.Context(), 1*time.Second)
		defer cancel()
		ok, err := c.RateLimit(cctx, key, max, window)
		if err != nil {
			return ctx.Next()
		}
		if !ok {
			// Silencioso: devolve 200 ok para o cliente usar o cache local.
			// Nunca retorna 429 — o painel nunca é bloqueado por rate limit.
			return ctx.JSON(fiber.Map{
				"status":     "ok",
				"cached":     true,
				"expires_at": nil,
			})
		}
		return ctx.Next()
	}
}

// AdminAuth constant-time bearer token check.
func AdminAuth(token string) fiber.Handler {
	return func(ctx *fiber.Ctx) error {
		auth := ctx.Get("Authorization")
		const prefix = "Bearer "
		if len(auth) <= len(prefix) || auth[:len(prefix)] != prefix {
			return fiber.NewError(401, "unauthorized")
		}
		got := auth[len(prefix):]
		if subtle.ConstantTimeCompare([]byte(got), []byte(token)) != 1 {
			return fiber.NewError(401, "unauthorized")
		}
		return ctx.Next()
	}
}
