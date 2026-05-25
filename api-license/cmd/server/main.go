package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/gofiber/fiber/v2"
	"github.com/gofiber/fiber/v2/middleware/cors"
	"github.com/gofiber/fiber/v2/middleware/logger"
	"github.com/gofiber/fiber/v2/middleware/recover"

	"github.com/xsp/api-license/internal/cache"
	"github.com/xsp/api-license/internal/config"
	xcrypto "github.com/xsp/api-license/internal/crypto"
	"github.com/xsp/api-license/internal/handler"
	"github.com/xsp/api-license/internal/middleware"
	"github.com/xsp/api-license/internal/repo"
	"github.com/xsp/api-license/internal/service"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		log.Fatalf("config: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	r, err := repo.New(ctx, cfg.DatabaseURL)
	if err != nil {
		log.Fatalf("db: %v", err)
	}
	defer r.Close()

	cch, err := cache.New(cfg.RedisURL)
	if err != nil {
		log.Fatalf("redis: %v", err)
	}

	signer, err := xcrypto.NewSignerFromB64(cfg.Ed25519PrivB64, cfg.Ed25519PubB64)
	if err != nil {
		log.Fatalf("signer: %v", err)
	}

	svc := service.New(cfg, r, signer)
	pub := handler.NewPublic(svc, r)
	adm := handler.NewAdmin(r)
	mp  := handler.NewMP(r, cfg.MPAccessToken, cfg.MPWebhookSecret,
	                     cfg.MPDefaultPlan, cfg.MPPeriodDays)

	app := fiber.New(fiber.Config{
		AppName:               "xsp-api-license",
		DisableStartupMessage: cfg.Env == "production",
		ReadTimeout:           15 * time.Second,
		WriteTimeout:          15 * time.Second,
		BodyLimit:             1 << 20, // 1 MiB
	})
	app.Use(recover.New())
	app.Use(logger.New(logger.Config{
		Format: "${time} ${status} ${method} ${path} ${latency} ${ip}\n",
	}))
	app.Use(cors.New(cors.Config{AllowOrigins: "*", AllowHeaders: "*"}))

	app.Get("/healthz", func(c *fiber.Ctx) error { return c.SendString("ok") })
	app.Get("/v1/release/pubkey", func(c *fiber.Ctx) error {
		return c.JSON(fiber.Map{"ed25519_pub_b64": cfg.Ed25519PubB64})
	})

	// Public, HMAC-signed
	// Rate limits separados por endpoint para evitar 429 em ambientes com muitos workers PHP.
	// Heartbeat: limite alto (workers PHP-FPM batem a cada 5 min; 200/min cobre ~1000 workers).
	// Activate/deactivate: limite baixo pois só ocorrem no boot/desativação.
	v1 := app.Group("/v1",
		middleware.HMACVerify(cfg.HMACSecret, cch, 60*time.Second),
	)
	v1.Post("/activate",
		middleware.RateLimitByIP(cch, "activate", 20, 1*time.Minute),
		pub.Activate)
	v1.Post("/heartbeat",
		middleware.RateLimitByIP(cch, "heartbeat", 200, 1*time.Minute),
		pub.Heartbeat)
	v1.Post("/deactivate",
		middleware.RateLimitByIP(cch, "deactivate", 10, 1*time.Minute),
		pub.Deactivate)
	v1.Post("/fraud/report",
		middleware.RateLimitByIP(cch, "fraud", 30, 1*time.Minute),
		pub.ReportFraud)

	// Webhooks (sem HMAC nosso — eles têm assinatura própria)
	app.Post("/webhooks/mp", mp.Handle)

	// Portal do cliente (auth via KEY no body)
	portal := handler.NewPortal(r)
	pg := app.Group("/portal", middleware.RateLimitByIP(cch, "portal", 20, time.Minute))
	pg.Post("/status",        portal.Status)
	pg.Post("/installations", portal.Installations)
	pg.Post("/reset-hwid",    portal.ResetHWID)

	// Admin
	a := app.Group("/admin", middleware.AdminAuth(cfg.AdminToken))
	a.Post("/keys", adm.CreateKey)
	a.Get("/keys", adm.ListKeys)
	a.Patch("/keys/:id", adm.UpdateKey)
	a.Post("/blacklist", adm.AddBlacklist)
	a.Post("/releases", adm.PutRelease)
	a.Get("/keys/:id/installations", adm.GetKeyInstallations)
	a.Delete("/installations/:id", adm.DeactivateInstallation)

	// Graceful shutdown
	go func() {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
		<-sig
		log.Println("shutting down...")
		_ = app.ShutdownWithTimeout(10 * time.Second)
	}()

	log.Printf("xsp-api-license listening on %s", cfg.ListenAddr)
	if cfg.TLSCertFile != "" && cfg.TLSKeyFile != "" {
		if err := app.ListenTLS(cfg.ListenAddr, cfg.TLSCertFile, cfg.TLSKeyFile); err != nil {
			log.Fatal(err)
		}
	} else {
		if err := app.Listen(cfg.ListenAddr); err != nil {
			log.Fatal(err)
		}
	}
}
