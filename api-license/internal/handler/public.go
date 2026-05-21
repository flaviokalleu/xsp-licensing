package handler

import (
	"errors"
	"time"

	"github.com/gofiber/fiber/v2"
	"github.com/google/uuid"
	"github.com/xsp/api-license/internal/repo"
	"github.com/xsp/api-license/internal/service"
)

type Public struct {
	svc  *service.Service
	repo *repo.Repo
}

func NewPublic(svc *service.Service, r *repo.Repo) *Public {
	return &Public{svc: svc, repo: r}
}

type activateReq struct {
	Key              string         `json:"key"`
	HWID             string         `json:"hwid"`
	Hostname         string         `json:"hostname"`
	PublicIP         string         `json:"public_ip"`
	Domain           string         `json:"domain"`
	Email            string         `json:"email"`
	OS               string         `json:"os"`
	OSVersion        string         `json:"os_version"`
	PanelVersion     string         `json:"panel_version"`
	InstallerVersion string         `json:"installer_version"`
	Fingerprint      map[string]any `json:"fingerprint"`
}

type activateResp struct {
	InstallationID    string         `json:"installation_id"`
	LicenseToken      string         `json:"license_token"`
	MasterKeySealed   string         `json:"master_key_sealed"`
	MasterKeyNonce    string         `json:"master_key_nonce"`
	ExpiresAt         time.Time      `json:"expires_at"`
	HeartbeatInterval int            `json:"heartbeat_interval_s"`
	Manifest          map[string]any `json:"manifest"`
	RegistryToken     string         `json:"registry_token"`
}

func (h *Public) Activate(c *fiber.Ctx) error {
	t0 := time.Now()
	var req activateReq
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(400, "bad_request")
	}
	if req.Key == "" || req.HWID == "" {
		return fiber.NewError(400, "missing_fields")
	}
	out, err := h.svc.Activate(c.Context(), service.ActivateInput{
		Key: req.Key, HWID: req.HWID, Hostname: req.Hostname,
		PublicIP: req.PublicIP, Domain: req.Domain, OS: req.OS,
		OSVersion: req.OSVersion, PanelVersion: req.PanelVersion,
		InstallerVersion: req.InstallerVersion, Fingerprint: req.Fingerprint,
	}, c.IP())
	latency := int(time.Since(t0).Milliseconds())
	if err != nil {
		h.repo.LogValidation(c.Context(), nil, nil, c.IP(), c.Get("User-Agent"),
			mapErr(err), latency, true)
		return mapErrToHTTP(err)
	}
	h.repo.LogValidation(c.Context(), &out.InstallationID, nil, c.IP(),
		c.Get("User-Agent"), "ok", latency, true)
	return c.JSON(activateResp{
		InstallationID:    out.InstallationID.String(),
		LicenseToken:      out.LicenseToken,
		MasterKeySealed:   out.MasterKeySealed,
		MasterKeyNonce:    out.MasterKeyNonce,
		ExpiresAt:         out.ExpiresAt,
		HeartbeatInterval: out.HeartbeatInterval,
		Manifest:          out.Manifest,
		RegistryToken:     out.RegistryToken,
	})
}

type heartbeatReq struct {
	HWID         string `json:"hwid"`
	PanelVersion string `json:"panel_version"`
	SelfChecksum string `json:"checksum_self"`
}

type heartbeatResp struct {
	Status          string    `json:"status"`
	Action          string    `json:"action,omitempty"`
	LicenseToken    string    `json:"license_token"`
	MasterKeySealed string    `json:"master_key_sealed"`
	MasterKeyNonce  string    `json:"master_key_nonce"`
	ExpiresAt       time.Time `json:"expires_at"`
}

func (h *Public) Heartbeat(c *fiber.Ctx) error {
	instIDStr := c.Get("X-Installation-ID")
	instID, err := uuid.Parse(instIDStr)
	if err != nil {
		return fiber.NewError(400, "bad_installation_id")
	}
	var req heartbeatReq
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(400, "bad_request")
	}
	t0 := time.Now()
	out, err := h.svc.Heartbeat(c.Context(), service.HeartbeatInput{
		InstallationID: instID,
		HWID:           req.HWID,
		PanelVersion:   req.PanelVersion,
		SelfChecksum:   req.SelfChecksum,
		IP:             c.IP(),
	})
	latency := int(time.Since(t0).Milliseconds())
	if err != nil {
		h.repo.LogValidation(c.Context(), &instID, nil, c.IP(), c.Get("User-Agent"),
			mapErr(err), latency, true)
		return mapErrToHTTP(err)
	}
	h.repo.LogValidation(c.Context(), &instID, nil, c.IP(), c.Get("User-Agent"),
		"ok", latency, true)
	return c.JSON(heartbeatResp{
		Status: out.Status, Action: out.Action,
		LicenseToken: out.LicenseToken,
		MasterKeySealed: out.MasterKeySealed, MasterKeyNonce: out.MasterKeyNonce,
		ExpiresAt: out.ExpiresAt,
	})
}

func (h *Public) Deactivate(c *fiber.Ctx) error {
	instIDStr := c.Get("X-Installation-ID")
	id, err := uuid.Parse(instIDStr)
	if err != nil {
		return fiber.NewError(400, "bad_installation_id")
	}
	if err := h.repo.DeactivateInstallation(c.Context(), id); err != nil {
		return fiber.NewError(500, "internal")
	}
	return c.JSON(fiber.Map{"status": "deactivated"})
}

type fraudReq struct {
	Kind     string         `json:"kind"`
	Payload  map[string]any `json:"payload"`
	Severity int            `json:"severity"`
}

func (h *Public) ReportFraud(c *fiber.Ctx) error {
	instIDStr := c.Get("X-Installation-ID")
	id, _ := uuid.Parse(instIDStr)
	var req fraudReq
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(400, "bad_request")
	}
	if req.Severity < 1 {
		req.Severity = 1
	}
	if req.Severity > 5 {
		req.Severity = 5
	}
	h.repo.LogFraud(c.Context(), &id, nil, req.Kind, req.Payload, req.Severity)
	return c.JSON(fiber.Map{"status": "ok"})
}

func mapErr(err error) string {
	switch {
	case errors.Is(err, service.ErrLicenseNotFound):
		return "license_not_found"
	case errors.Is(err, service.ErrLicenseExpired):
		return "license_expired"
	case errors.Is(err, service.ErrLicenseRevoked):
		return "license_revoked"
	case errors.Is(err, service.ErrMaxInstances):
		return "max_instances_reached"
	case errors.Is(err, service.ErrBlacklisted):
		return "blacklisted"
	case errors.Is(err, service.ErrHWIDMismatch):
		return "hwid_mismatch"
	}
	return "internal"
}

func mapErrToHTTP(err error) error {
	switch {
	case errors.Is(err, service.ErrLicenseNotFound):
		return fiber.NewError(404, "license_not_found")
	case errors.Is(err, service.ErrLicenseExpired):
		return fiber.NewError(402, "license_expired")
	case errors.Is(err, service.ErrLicenseRevoked):
		return fiber.NewError(410, "license_revoked")
	case errors.Is(err, service.ErrMaxInstances):
		return fiber.NewError(409, "max_instances_reached")
	case errors.Is(err, service.ErrBlacklisted):
		return fiber.NewError(403, "blacklisted")
	case errors.Is(err, service.ErrHWIDMismatch):
		return fiber.NewError(403, "hwid_mismatch")
	}
	return fiber.NewError(500, "internal")
}
