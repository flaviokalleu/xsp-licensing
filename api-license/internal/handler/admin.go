package handler

import (
	"time"

	"github.com/gofiber/fiber/v2"
	"github.com/google/uuid"
	xcrypto "github.com/xsp/api-license/internal/crypto"
	"github.com/xsp/api-license/internal/model"
	"github.com/xsp/api-license/internal/repo"
)

type Admin struct {
	repo *repo.Repo
}

func NewAdmin(r *repo.Repo) *Admin { return &Admin{repo: r} }

type createKeyReq struct {
	Email      string `json:"email"`
	Name       string `json:"name"`
	Phone      string `json:"phone"`
	PlanCode   string `json:"plan_code"`
	PeriodDays int    `json:"period_days"`
	MaxInst    int    `json:"max_instances"`
	Notes      string `json:"notes"`
}

type createKeyResp struct {
	License model.License `json:"license"`
	Key     string        `json:"key"`
}

func (a *Admin) CreateKey(c *fiber.Ctx) error {
	var req createKeyReq
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(400, "bad_request")
	}
	if req.Email == "" || req.PlanCode == "" {
		return fiber.NewError(400, "email_and_plan_required")
	}
	plan, err := a.repo.GetPlanByCode(c.Context(), req.PlanCode)
	if err != nil {
		return fiber.NewError(404, "plan_not_found")
	}
	cust, err := a.repo.UpsertCustomer(c.Context(), req.Email, req.Name, req.Phone)
	if err != nil {
		return fiber.NewError(500, "customer_failed")
	}
	key, err := xcrypto.GenerateLicenseKey()
	if err != nil {
		return fiber.NewError(500, "key_gen")
	}
	period := plan.PeriodDays
	if req.PeriodDays > 0 {
		period = req.PeriodDays
	}
	maxInst := plan.MaxInstances
	if req.MaxInst > 0 {
		maxInst = req.MaxInst
	}
	lic := &model.License{
		CustomerID:   cust.ID,
		PlanID:       plan.ID,
		Key:          key,
		KeyHash:      xcrypto.HashKey(key),
		Status:       "active",
		ExpiresAt:    time.Now().Add(time.Duration(period) * 24 * time.Hour),
		MaxInstances: maxInst,
		GracePeriodH: 24,
		Notes:        req.Notes,
	}
	if err := a.repo.CreateLicense(c.Context(), lic); err != nil {
		return fiber.NewError(500, "create_failed")
	}
	lic.PlanCode = plan.Code
	return c.Status(201).JSON(createKeyResp{License: *lic, Key: key})
}

func (a *Admin) ListKeys(c *fiber.Ctx) error {
	limit := c.QueryInt("limit", 50)
	offset := c.QueryInt("offset", 0)
	if limit > 200 {
		limit = 200
	}
	list, err := a.repo.ListLicenses(c.Context(), limit, offset)
	if err != nil {
		return fiber.NewError(500, "internal")
	}
	// don't echo back key_hash to admin clients
	for i := range list {
		list[i].KeyHash = ""
	}
	return c.JSON(fiber.Map{"items": list, "limit": limit, "offset": offset})
}

type updateKeyReq struct {
	Status       string     `json:"status,omitempty"`
	ExpiresAt    *time.Time `json:"expires_at,omitempty"`
	ExtendDays   int        `json:"extend_days,omitempty"`
	MaxInstances int        `json:"max_instances,omitempty"`
	Reason       string     `json:"reason,omitempty"`
}

func (a *Admin) UpdateKey(c *fiber.Ctx) error {
	id, err := uuid.Parse(c.Params("id"))
	if err != nil {
		return fiber.NewError(400, "bad_id")
	}
	var req updateKeyReq
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(400, "bad_request")
	}
	if req.Status != "" {
		if err := a.repo.UpdateLicenseStatus(c.Context(), id, req.Status, req.Reason); err != nil {
			return fiber.NewError(500, "internal")
		}
	}
	if req.ExtendDays > 0 || req.ExpiresAt != nil {
		var until time.Time
		if req.ExpiresAt != nil {
			until = *req.ExpiresAt
		} else {
			until = time.Now().Add(time.Duration(req.ExtendDays) * 24 * time.Hour)
		}
		if err := a.repo.ExtendLicense(c.Context(), id, until); err != nil {
			return fiber.NewError(500, "internal")
		}
	}
	return c.JSON(fiber.Map{"status": "ok"})
}

type blacklistReq struct {
	Kind   string `json:"kind"`
	Value  string `json:"value"`
	Reason string `json:"reason"`
}

func (a *Admin) AddBlacklist(c *fiber.Ctx) error {
	var req blacklistReq
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(400, "bad_request")
	}
	if err := a.repo.AddBlacklist(c.Context(), req.Kind, req.Value, req.Reason); err != nil {
		return fiber.NewError(500, "internal")
	}
	return c.Status(201).JSON(fiber.Map{"status": "ok"})
}

func (a *Admin) GetKeyInstallations(c *fiber.Ctx) error {
	id, err := uuid.Parse(c.Params("id"))
	if err != nil {
		return fiber.NewError(400, "bad_id")
	}
	items, err := a.repo.ListInstallationsByLicense(c.Context(), id)
	if err != nil {
		return fiber.NewError(500, "internal")
	}
	type instItem struct {
		ID              string    `json:"id"`
		Status          string    `json:"status"`
		Hostname        string    `json:"hostname"`
		Domain          string    `json:"domain"`
		PublicIP        string    `json:"public_ip"`
		OS              string    `json:"os"`
		PanelVersion    string    `json:"panel_version"`
		InstallerVersion string   `json:"installer_version"`
		ActivatedAt     time.Time `json:"activated_at"`
		LastSeenAt      time.Time `json:"last_seen_at"`
		ActivationIP    string    `json:"activation_ip"`
		LastIP          string    `json:"last_ip"`
	}
	out := make([]instItem, 0, len(items))
	for _, in := range items {
		out = append(out, instItem{
			ID: in.ID.String(), Status: in.Status,
			Hostname: in.Hostname, Domain: in.Domain, PublicIP: in.PublicIP,
			OS: in.OS, PanelVersion: in.PanelVersion, InstallerVersion: in.InstallerVersion,
			ActivatedAt: in.ActivatedAt, LastSeenAt: in.LastSeenAt,
			ActivationIP: in.ActivationIP, LastIP: in.LastIP,
		})
	}
	return c.JSON(fiber.Map{"items": out, "total": len(out)})
}

func (a *Admin) DeactivateInstallation(c *fiber.Ctx) error {
	id, err := uuid.Parse(c.Params("id"))
	if err != nil {
		return fiber.NewError(400, "bad_id")
	}
	if err := a.repo.DeactivateInstallation(c.Context(), id); err != nil {
		return fiber.NewError(500, "internal")
	}
	return c.JSON(fiber.Map{"status": "deactivated"})
}

type releaseReq struct {
	Version   string         `json:"version"`
	MasterKey string         `json:"master_key"`
	Manifest  map[string]any `json:"manifest"`
}

func (a *Admin) PutRelease(c *fiber.Ctx) error {
	var req releaseReq
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(400, "bad_request")
	}
	if req.Version == "" || len(req.MasterKey) != 64 {
		return fiber.NewError(400, "bad_version_or_key")
	}
	if err := a.repo.PutRelease(c.Context(), req.Version, req.MasterKey, req.Manifest); err != nil {
		return fiber.NewError(500, "internal")
	}
	return c.JSON(fiber.Map{"status": "ok"})
}
