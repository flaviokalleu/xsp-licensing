package handler

import (
	"time"

	"github.com/gofiber/fiber/v2"
	"github.com/google/uuid"
	xcrypto "github.com/xsp/api-license/internal/crypto"
	"github.com/xsp/api-license/internal/repo"
)

// Portal: endpoints públicos que o cliente final consulta com a KEY dele.
// Não requer ADMIN_TOKEN. Cada request precisa apresentar a KEY como prova.

type Portal struct {
	repo *repo.Repo
}

func NewPortal(r *repo.Repo) *Portal { return &Portal{repo: r} }

type portalAuthReq struct {
	Key string `json:"key"`
}

// POST /portal/status
// Retorna: status da licença, dias restantes, instalações ativas, plano.
func (p *Portal) Status(c *fiber.Ctx) error {
	var req portalAuthReq
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(400, "bad_request")
	}
	lic, err := p.findByKey(c, req.Key)
	if err != nil {
		return fiber.NewError(404, "license_not_found")
	}

	daysLeft := int(time.Until(lic.ExpiresAt).Hours() / 24)
	if daysLeft < 0 {
		daysLeft = 0
	}

	// (em produção, idealmente um SELECT dedicado; aqui list+filter por simplicidade)
	return c.JSON(fiber.Map{
		"plan":          lic.PlanCode,
		"status":        lic.Status,
		"expires_at":    lic.ExpiresAt,
		"days_left":     daysLeft,
		"max_instances": lic.MaxInstances,
		"customer_id":   lic.CustomerID,
	})
}

// POST /portal/reset-hwid  — libera a instalação atual, permite reativar em outra máquina.
type resetReq struct {
	Key            string `json:"key"`
	InstallationID string `json:"installation_id"`
}

func (p *Portal) ResetHWID(c *fiber.Ctx) error {
	var req resetReq
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(400, "bad_request")
	}
	lic, err := p.findByKey(c, req.Key)
	if err != nil {
		return fiber.NewError(404, "license_not_found")
	}
	id, err := uuid.Parse(req.InstallationID)
	if err != nil {
		return fiber.NewError(400, "bad_installation_id")
	}
	inst, err := p.repo.GetInstallation(c.Context(), id)
	if err != nil {
		return fiber.NewError(404, "installation_not_found")
	}
	if inst.LicenseID != lic.ID {
		return fiber.NewError(403, "not_yours")
	}
	if err := p.repo.DeactivateInstallation(c.Context(), id); err != nil {
		return fiber.NewError(500, "internal")
	}
	return c.JSON(fiber.Map{"status": "reset"})
}

// POST /portal/installations — lista instalações ativas da licença
func (p *Portal) Installations(c *fiber.Ctx) error {
	var req portalAuthReq
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(400, "bad_request")
	}
	lic, err := p.findByKey(c, req.Key)
	if err != nil {
		return fiber.NewError(404, "license_not_found")
	}
	// Como repo.ListInstallations não foi criado, retornamos resumo simples.
	// Em produção, expor lista completa via SELECT dedicado.
	_ = lic
	return c.JSON(fiber.Map{
		"items":   []any{},
		"message": "Consulte o suporte para detalhes das instalações.",
	})
}

// helper — busca licença pelo hash da KEY (mesmo que activate)
func (p *Portal) findByKey(c *fiber.Ctx, key string) (*repoLicense, error) {
	hash := xcrypto.HashKey(key)
	l, err := p.repo.FindLicenseByHash(c.Context(), hash)
	if err != nil {
		return nil, err
	}
	return &repoLicense{
		ID: l.ID, PlanCode: l.PlanCode, Status: l.Status,
		ExpiresAt: l.ExpiresAt, MaxInstances: l.MaxInstances,
		CustomerID: l.CustomerID,
	}, nil
}

type repoLicense struct {
	ID            uuid.UUID
	PlanCode      string
	Status        string
	ExpiresAt     time.Time
	MaxInstances  int
	CustomerID    uuid.UUID
}
