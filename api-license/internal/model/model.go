package model

import (
	"time"

	"github.com/google/uuid"
)

type Customer struct {
	ID        uuid.UUID `json:"id"`
	Email     string    `json:"email"`
	Name      string    `json:"name"`
	Phone     string    `json:"phone,omitempty"`
	Status    string    `json:"status"`
	CreatedAt time.Time `json:"created_at"`
}

type Plan struct {
	ID            int            `json:"id"`
	Code          string         `json:"code"`
	Name          string         `json:"name"`
	PriceCents    int            `json:"price_cents"`
	MaxInstances  int            `json:"max_instances"`
	Features      map[string]any `json:"features"`
	PeriodDays    int            `json:"period_days"`
}

type License struct {
	ID            uuid.UUID  `json:"id"`
	CustomerID    uuid.UUID  `json:"customer_id"`
	PlanID        int        `json:"plan_id"`
	PlanCode      string     `json:"plan_code"`
	Key           string     `json:"key,omitempty"`
	KeyHash       string     `json:"-"`
	Status        string     `json:"status"`
	ExpiresAt     time.Time  `json:"expires_at"`
	MaxInstances  int        `json:"max_instances"`
	GracePeriodH  int        `json:"grace_period_h"`
	Notes         string     `json:"notes,omitempty"`
	CreatedAt     time.Time  `json:"created_at"`
	UpdatedAt     time.Time  `json:"updated_at"`
	RevokedAt     *time.Time `json:"revoked_at,omitempty"`
	RevokedReason string     `json:"revoked_reason,omitempty"`
}

type Installation struct {
	ID               uuid.UUID      `json:"id"`
	LicenseID        uuid.UUID      `json:"license_id"`
	HWID             string         `json:"hwid"`
	Hostname         string         `json:"hostname,omitempty"`
	PublicIP         string         `json:"public_ip,omitempty"`
	Domain           string         `json:"domain,omitempty"`
	OS               string         `json:"os,omitempty"`
	OSVersion        string         `json:"os_version,omitempty"`
	PanelVersion     string         `json:"panel_version,omitempty"`
	InstallerVersion string         `json:"installer_version,omitempty"`
	Fingerprint      map[string]any `json:"fingerprint,omitempty"`
	Status           string         `json:"status"`
	ActivatedAt      time.Time      `json:"activated_at"`
	LastSeenAt       time.Time      `json:"last_seen_at"`
	ActivationIP     string         `json:"activation_ip,omitempty"`
	LastIP           string         `json:"last_ip,omitempty"`
	LastIPAt         time.Time      `json:"last_ip_at,omitempty"`
}

type Release struct {
	Version       string         `json:"version"`
	Manifest      map[string]any `json:"manifest"`
	PublishedAt   time.Time      `json:"published_at"`
	CanaryPct     int            `json:"canary_pct"`
}
