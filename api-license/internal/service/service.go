package service

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/xsp/api-license/internal/config"
	xcrypto "github.com/xsp/api-license/internal/crypto"
	"github.com/xsp/api-license/internal/model"
	"github.com/xsp/api-license/internal/repo"
)

type Service struct {
	cfg    *config.Config
	repo   *repo.Repo
	signer *xcrypto.Signer
}

func New(cfg *config.Config, r *repo.Repo, s *xcrypto.Signer) *Service {
	return &Service{cfg: cfg, repo: r, signer: s}
}

type ActivateInput struct {
	Key              string
	HWID             string
	Hostname         string
	PublicIP         string
	Domain           string
	OS               string
	OSVersion        string
	PanelVersion     string
	InstallerVersion string
	Fingerprint      map[string]any
}

type ActivateOutput struct {
	InstallationID    uuid.UUID
	LicenseToken      string
	MasterKeySealed   string
	MasterKeyNonce    string
	ExpiresAt         time.Time
	HeartbeatInterval int
	Manifest          map[string]any
	RegistryToken     string
}

var (
	ErrLicenseNotFound = errors.New("license_not_found")
	ErrLicenseExpired  = errors.New("license_expired")
	ErrLicenseRevoked  = errors.New("license_revoked")
	ErrMaxInstances    = errors.New("max_instances_reached")
	ErrBlacklisted     = errors.New("blacklisted")
	ErrHWIDMismatch    = errors.New("hwid_mismatch")
)

func (s *Service) Activate(ctx context.Context, in ActivateInput, ip string) (*ActivateOutput, error) {
	hash := xcrypto.HashKey(in.Key)
	lic, err := s.repo.FindLicenseByHash(ctx, hash)
	if err != nil {
		if errors.Is(err, repo.ErrNotFound) {
			return nil, ErrLicenseNotFound
		}
		return nil, err
	}

	switch lic.Status {
	case "revoked":
		return nil, ErrLicenseRevoked
	case "expired", "suspended":
		return nil, ErrLicenseExpired
	}
	if time.Now().After(lic.ExpiresAt.Add(time.Duration(lic.GracePeriodH) * time.Hour)) {
		_ = s.repo.UpdateLicenseStatus(ctx, lic.ID, "expired", "auto-expired")
		return nil, ErrLicenseExpired
	}

	for _, kv := range []struct{ k, v string }{
		{"hwid", in.HWID}, {"ip", ip}, {"key", xcrypto.NormalizeKey(in.Key)},
	} {
		if blk, _ := s.repo.IsBlacklisted(ctx, kv.k, kv.v); blk {
			s.repo.LogFraud(ctx, nil, &lic.ID, "blacklisted",
				map[string]any{"kind": kv.k, "value": kv.v, "ip": ip}, 4)
			return nil, ErrBlacklisted
		}
	}

	inst := &model.Installation{
		LicenseID:        lic.ID,
		HWID:             in.HWID,
		Hostname:         in.Hostname,
		PublicIP:         in.PublicIP,
		Domain:           in.Domain,
		OS:               in.OS,
		OSVersion:        in.OSVersion,
		PanelVersion:     in.PanelVersion,
		InstallerVersion: in.InstallerVersion,
		Fingerprint:      in.Fingerprint,
		ActivationIP:     ip, // vincula ao IP real da conexão HTTP de ativação
	}
	if err := s.repo.UpsertInstallation(ctx, lic, inst); err != nil {
		if errors.Is(err, repo.ErrMaxInstances) {
			return nil, ErrMaxInstances
		}
		return nil, err
	}

	tok := xcrypto.LicenseToken{
		Sub:       inst.ID.String(),
		LicenseID: lic.ID.String(),
		HWID:      in.HWID,
		Plan:      lic.PlanCode,
		Features:  []string{},
		IssuedAt:  time.Now().Unix(),
		ExpiresAt: time.Now().Add(24 * time.Hour).Unix(),
		NotAfter:  lic.ExpiresAt.Unix(),
		Nonce:     xcrypto.RandomNonce(8),
	}
	jwt, err := s.signer.Issue(tok)
	if err != nil {
		return nil, err
	}

	masterKey, manifest, err := s.releaseMaterial(ctx)
	if err != nil {
		return nil, err
	}
	sealed, nonce, err := xcrypto.SealMasterKey(masterKey, in.HWID)
	if err != nil {
		return nil, err
	}

	return &ActivateOutput{
		InstallationID:    inst.ID,
		LicenseToken:      jwt,
		MasterKeySealed:   sealed,
		MasterKeyNonce:    nonce,
		ExpiresAt:         lic.ExpiresAt,
		HeartbeatInterval: 300,
		Manifest:          manifest,
		RegistryToken:     s.cfg.RegistryPass, // simplificação — em prod, robot account JWT
	}, nil
}

type HeartbeatInput struct {
	InstallationID uuid.UUID
	HWID           string
	PanelVersion   string
	SelfChecksum   string
	IP             string
}

type HeartbeatOutput struct {
	Status          string
	Action          string
	LicenseToken    string
	MasterKeySealed string
	MasterKeyNonce  string
	ExpiresAt       time.Time
}

func (s *Service) Heartbeat(ctx context.Context, in HeartbeatInput) (*HeartbeatOutput, error) {
	inst, err := s.repo.GetInstallation(ctx, in.InstallationID)
	if err != nil {
		return nil, ErrLicenseNotFound
	}
	if inst.HWID != in.HWID {
		s.repo.LogFraud(ctx, &inst.ID, &inst.LicenseID, "hwid_mismatch",
			map[string]any{"expected": inst.HWID, "got": in.HWID}, 5)
		return nil, ErrHWIDMismatch
	}
	if inst.Status != "active" {
		return nil, ErrLicenseRevoked
	}

	// Detecção de mudança de IP: loga como suspeito mas não bloqueia.
	// Blacklist automático por IP causava falsos positivos quando o container
	// envia heartbeat por caminho de rede diferente da ativação (proxy/Caddy).
	if in.IP != "" && inst.ActivationIP != "" && inst.ActivationIP != in.IP {
		s.repo.LogFraud(ctx, &inst.ID, &inst.LicenseID, "ip_mismatch",
			map[string]any{"activation_ip": inst.ActivationIP, "request_ip": in.IP,
				"hwid": in.HWID}, 2)
	}

	// Refresh license info — busca direta por ID, sem varrer todas as licenças.
	lic, err := s.repo.FindLicenseByID(ctx, inst.LicenseID)
	if err != nil {
		return nil, ErrLicenseNotFound
	}
	if lic.Status == "revoked" {
		return nil, ErrLicenseRevoked
	}
	if time.Now().After(lic.ExpiresAt.Add(time.Duration(lic.GracePeriodH) * time.Hour)) {
		_ = s.repo.UpdateLicenseStatus(ctx, lic.ID, "expired", "auto-expired")
		return nil, ErrLicenseExpired
	}

	_ = s.repo.HeartbeatInstallation(ctx, inst.ID, in.PanelVersion, in.IP)

	tok := xcrypto.LicenseToken{
		Sub:       inst.ID.String(),
		LicenseID: lic.ID.String(),
		HWID:      in.HWID,
		Plan:      lic.PlanCode,
		Features:  []string{},
		IssuedAt:  time.Now().Unix(),
		ExpiresAt: time.Now().Add(24 * time.Hour).Unix(),
		NotAfter:  lic.ExpiresAt.Unix(),
		Nonce:     xcrypto.RandomNonce(8),
	}
	jwt, err := s.signer.Issue(tok)
	if err != nil {
		return nil, err
	}
	masterKey, _, err := s.releaseMaterial(ctx)
	if err != nil {
		return nil, err
	}
	sealed, nonce, err := xcrypto.SealMasterKey(masterKey, in.HWID)
	if err != nil {
		return nil, err
	}
	return &HeartbeatOutput{
		Status:          "ok",
		Action:          "",
		LicenseToken:    jwt,
		MasterKeySealed: sealed,
		MasterKeyNonce:  nonce,
		ExpiresAt:       lic.ExpiresAt,
	}, nil
}

func (s *Service) releaseMaterial(ctx context.Context) (string, map[string]any, error) {
	masterKey := s.cfg.ReleaseMasterKey
	manifest := defaultManifest(s.cfg.ReleaseVersion, s.cfg.RegistryURL)

	releaseMaster, releaseManifest, err := s.repo.GetRelease(ctx, s.cfg.ReleaseVersion)
	if err == nil {
		if releaseMaster != "" {
			masterKey = releaseMaster
		}
		if releaseManifest != nil {
			manifest = releaseManifest
		}
		return masterKey, manifest, nil
	}
	if errors.Is(err, repo.ErrNotFound) {
		return masterKey, manifest, nil
	}
	return "", nil, err
}


func defaultManifest(version, registry string) map[string]any {
	return map[string]any{
		"version": version,
		"images": []map[string]any{
			{"ref": registry + "/xsp/panel:" + version, "sha256": ""},
			{"ref": registry + "/xsp/nginx-tls:latest", "sha256": ""},
		},
	}
}
