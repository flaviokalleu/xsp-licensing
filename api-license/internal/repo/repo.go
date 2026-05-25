package repo

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/xsp/api-license/internal/model"
)

type Repo struct {
	pool *pgxpool.Pool
}

func New(ctx context.Context, dsn string) (*Repo, error) {
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		return nil, err
	}
	if err := pool.Ping(ctx); err != nil {
		return nil, err
	}
	return &Repo{pool: pool}, nil
}

func (r *Repo) Close() { r.pool.Close() }

var (
	ErrNotFound     = errors.New("not found")
	ErrMaxInstances = errors.New("max instances reached")
	ErrBlacklisted  = errors.New("blacklisted")
)

// ===== Licenses =====

func (r *Repo) FindLicenseByHash(ctx context.Context, hash string) (*model.License, error) {
	return r.scanLicense(r.pool.QueryRow(ctx, `
		SELECT l.id, l.customer_id, l.plan_id, p.code, l.key, l.key_hash, l.status,
		       l.expires_at, l.max_instances, l.grace_period_h, COALESCE(l.notes,''),
		       l.created_at, l.updated_at
		FROM licenses l
		JOIN plans p ON p.id = l.plan_id
		WHERE l.key_hash = $1`, hash))
}

func (r *Repo) FindLicenseByID(ctx context.Context, id uuid.UUID) (*model.License, error) {
	return r.scanLicense(r.pool.QueryRow(ctx, `
		SELECT l.id, l.customer_id, l.plan_id, p.code, l.key, l.key_hash, l.status,
		       l.expires_at, l.max_instances, l.grace_period_h, COALESCE(l.notes,''),
		       l.created_at, l.updated_at
		FROM licenses l
		JOIN plans p ON p.id = l.plan_id
		WHERE l.id = $1`, id))
}

func (r *Repo) scanLicense(row pgx.Row) (*model.License, error) {
	var l model.License
	err := row.Scan(&l.ID, &l.CustomerID, &l.PlanID, &l.PlanCode, &l.Key, &l.KeyHash,
		&l.Status, &l.ExpiresAt, &l.MaxInstances, &l.GracePeriodH, &l.Notes,
		&l.CreatedAt, &l.UpdatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return &l, nil
}

func (r *Repo) CreateLicense(ctx context.Context, l *model.License) error {
	row := r.pool.QueryRow(ctx, `
		INSERT INTO licenses (customer_id, plan_id, key, key_hash, status,
		                     expires_at, max_instances, grace_period_h, notes)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
		RETURNING id, created_at, updated_at`,
		l.CustomerID, l.PlanID, l.Key, l.KeyHash, l.Status,
		l.ExpiresAt, l.MaxInstances, l.GracePeriodH, l.Notes)
	return row.Scan(&l.ID, &l.CreatedAt, &l.UpdatedAt)
}

func (r *Repo) UpdateLicenseStatus(ctx context.Context, id uuid.UUID, status, reason string) error {
	_, err := r.pool.Exec(ctx, `
		UPDATE licenses SET status=$2, revoked_at=CASE WHEN $2='revoked' THEN NOW() ELSE revoked_at END,
		                   revoked_reason=$3, updated_at=NOW()
		WHERE id=$1`, id, status, reason)
	return err
}

func (r *Repo) ExtendLicense(ctx context.Context, id uuid.UUID, until time.Time) error {
	_, err := r.pool.Exec(ctx, `
		UPDATE licenses SET expires_at=$2, status=CASE WHEN status='expired' THEN 'active' ELSE status END,
		                   updated_at=NOW()
		WHERE id=$1`, id, until)
	return err
}

func (r *Repo) ListLicenses(ctx context.Context, limit, offset int) ([]model.License, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT l.id, l.customer_id, COALESCE(c.email,''), COALESCE(c.name,''),
		       l.plan_id, p.code, l.key, l.key_hash, l.status,
		       l.expires_at, l.max_instances, l.grace_period_h, COALESCE(l.notes,''),
		       l.created_at, l.updated_at
		FROM licenses l
		JOIN plans p ON p.id = l.plan_id
		LEFT JOIN customers c ON c.id = l.customer_id
		ORDER BY l.created_at DESC LIMIT $1 OFFSET $2`, limit, offset)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []model.License
	for rows.Next() {
		var l model.License
		if err := rows.Scan(&l.ID, &l.CustomerID, &l.CustomerEmail, &l.CustomerName,
			&l.PlanID, &l.PlanCode, &l.Key, &l.KeyHash,
			&l.Status, &l.ExpiresAt, &l.MaxInstances, &l.GracePeriodH, &l.Notes,
			&l.CreatedAt, &l.UpdatedAt); err != nil {
			return nil, err
		}
		out = append(out, l)
	}
	return out, nil
}

// ===== Installations =====

// UpsertInstallation locks license row, enforces max_instances, returns installation.
func (r *Repo) UpsertInstallation(ctx context.Context, lic *model.License, in *model.Installation) error {
	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	// Try to find existing for (license, hwid)
	row := tx.QueryRow(ctx, `
		SELECT id, status, activated_at FROM installations
		WHERE license_id=$1 AND hwid=$2 FOR UPDATE`, lic.ID, in.HWID)
	var existingID uuid.UUID
	var status string
	var activatedAt time.Time
	err = row.Scan(&existingID, &status, &activatedAt)
	if err == nil {
		// existing — update last_seen + metadata
		_, err = tx.Exec(ctx, `
			UPDATE installations SET hostname=$2, public_ip=$3, domain=$4, os=$5, os_version=$6,
			    panel_version=$7, installer_version=$8, fingerprint_v2=$9::jsonb,
			    last_seen_at=NOW(), status='active'
			WHERE id=$1`,
			existingID, in.Hostname, nullable(in.PublicIP), in.Domain, in.OS, in.OSVersion,
			in.PanelVersion, in.InstallerVersion, jsonOrNull(in.Fingerprint))
		if err != nil {
			return err
		}
		in.ID = existingID
		in.Status = "active"
		in.ActivatedAt = activatedAt
		in.LastSeenAt = time.Now()
		return tx.Commit(ctx)
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return err
	}

	// Count active for limit
	var active int
	if err := tx.QueryRow(ctx, `
		SELECT COUNT(*) FROM installations WHERE license_id=$1 AND status='active'`,
		lic.ID).Scan(&active); err != nil {
		return err
	}
	if active >= lic.MaxInstances {
		return ErrMaxInstances
	}

	// Insert new — grava activation_ip (imutável) + last_ip
	if err := tx.QueryRow(ctx, `
		INSERT INTO installations (license_id, hwid, hostname, public_ip, domain, os, os_version,
		    panel_version, installer_version, fingerprint_v2,
		    activation_ip, last_ip, last_ip_at)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10::jsonb,
		    NULLIF($11,'')::inet, NULLIF($11,'')::inet, CASE WHEN $11<>'' THEN NOW() ELSE NULL END)
		RETURNING id, activated_at, last_seen_at, status`,
		lic.ID, in.HWID, in.Hostname, nullable(in.PublicIP), in.Domain, in.OS, in.OSVersion,
		in.PanelVersion, in.InstallerVersion, jsonOrNull(in.Fingerprint),
		in.ActivationIP).
		Scan(&in.ID, &in.ActivatedAt, &in.LastSeenAt, &in.Status); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func (r *Repo) HeartbeatInstallation(ctx context.Context, id uuid.UUID, panelVersion, ip string) error {
	_, err := r.pool.Exec(ctx, `
		UPDATE installations SET last_seen_at=NOW(),
		       panel_version=COALESCE(NULLIF($2,''), panel_version),
		       last_ip=NULLIF($3,'')::inet, last_ip_at=CASE WHEN $3<>'' THEN NOW() ELSE last_ip_at END
		WHERE id=$1`, id, panelVersion, ip)
	return err
}

func (r *Repo) GetInstallation(ctx context.Context, id uuid.UUID) (*model.Installation, error) {
	row := r.pool.QueryRow(ctx, `
		SELECT id, license_id, hwid, COALESCE(hostname,''), COALESCE(public_ip::text,''),
		       COALESCE(domain,''), COALESCE(os,''), COALESCE(os_version,''),
		       COALESCE(panel_version,''), COALESCE(installer_version,''), status,
		       activated_at, last_seen_at,
		       COALESCE(activation_ip::text,''),
		       COALESCE(last_ip::text,''), COALESCE(last_ip_at, '1970-01-01'::timestamptz)
		FROM installations WHERE id=$1`, id)
	var in model.Installation
	if err := row.Scan(&in.ID, &in.LicenseID, &in.HWID, &in.Hostname, &in.PublicIP,
		&in.Domain, &in.OS, &in.OSVersion, &in.PanelVersion, &in.InstallerVersion,
		&in.Status, &in.ActivatedAt, &in.LastSeenAt,
		&in.ActivationIP, &in.LastIP, &in.LastIPAt); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return &in, nil
}

func (r *Repo) DeactivateInstallation(ctx context.Context, id uuid.UUID) error {
	_, err := r.pool.Exec(ctx, `
		UPDATE installations SET status='deactivated', deactivated_at=NOW() WHERE id=$1`, id)
	return err
}

func (r *Repo) ListInstallationsByLicense(ctx context.Context, licenseID uuid.UUID) ([]model.Installation, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT id, license_id, hwid, COALESCE(hostname,''), COALESCE(public_ip::text,''),
		       COALESCE(domain,''), COALESCE(os,''), COALESCE(os_version,''),
		       COALESCE(panel_version,''), COALESCE(installer_version,''), status,
		       activated_at, last_seen_at,
		       COALESCE(activation_ip::text,''),
		       COALESCE(last_ip::text,''), COALESCE(last_ip_at, '1970-01-01'::timestamptz)
		FROM installations WHERE license_id=$1 ORDER BY activated_at DESC`, licenseID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var items []model.Installation
	for rows.Next() {
		var in model.Installation
		if err := rows.Scan(&in.ID, &in.LicenseID, &in.HWID, &in.Hostname, &in.PublicIP,
			&in.Domain, &in.OS, &in.OSVersion, &in.PanelVersion, &in.InstallerVersion,
			&in.Status, &in.ActivatedAt, &in.LastSeenAt,
			&in.ActivationIP, &in.LastIP, &in.LastIPAt); err != nil {
			return nil, err
		}
		items = append(items, in)
	}
	return items, rows.Err()
}

// ===== Blacklist =====

func (r *Repo) IsBlacklisted(ctx context.Context, kind, value string) (bool, error) {
	var n int
	err := r.pool.QueryRow(ctx,
		`SELECT COUNT(*) FROM blacklist WHERE kind=$1 AND value=$2`, kind, value).Scan(&n)
	return n > 0, err
}

func (r *Repo) AddBlacklist(ctx context.Context, kind, value, reason string) error {
	_, err := r.pool.Exec(ctx, `
		INSERT INTO blacklist (kind, value, reason) VALUES ($1,$2,$3)
		ON CONFLICT (kind, value) DO NOTHING`, kind, value, reason)
	return err
}

// ===== Validation logs / fraud =====

func (r *Repo) LogValidation(ctx context.Context, installID *uuid.UUID, licenseID *uuid.UUID,
	ip, ua, result string, latencyMs int, signed bool) {
	_, _ = r.pool.Exec(ctx, `
		INSERT INTO validation_logs (installation_id, license_id, ip, user_agent, result, latency_ms, signed)
		VALUES ($1, $2, NULLIF($3,'')::inet, $4, $5, $6, $7)`,
		installID, licenseID, ip, ua, result, latencyMs, signed)
}

func (r *Repo) LogFraud(ctx context.Context, installID, licenseID *uuid.UUID,
	kind string, payload map[string]any, severity int) {
	_, _ = r.pool.Exec(ctx, `
		INSERT INTO fraud_events (installation_id, license_id, kind, payload, severity)
		VALUES ($1,$2,$3,$4::jsonb,$5)`,
		installID, licenseID, kind, jsonOrNull(payload), severity)
}

// ===== Customers =====

func (r *Repo) UpsertCustomer(ctx context.Context, email, name, phone string) (*model.Customer, error) {
	row := r.pool.QueryRow(ctx, `
		INSERT INTO customers (email, name, phone) VALUES ($1, $2, $3)
		ON CONFLICT (email) DO UPDATE SET name=COALESCE(NULLIF(EXCLUDED.name,''), customers.name),
		                                  phone=COALESCE(NULLIF(EXCLUDED.phone,''), customers.phone),
		                                  updated_at=NOW()
		RETURNING id, email, COALESCE(name,''), COALESCE(phone,''), status, created_at`,
		email, name, phone)
	var c model.Customer
	if err := row.Scan(&c.ID, &c.Email, &c.Name, &c.Phone, &c.Status, &c.CreatedAt); err != nil {
		return nil, err
	}
	return &c, nil
}

// ===== Plans =====

func (r *Repo) GetPlanByCode(ctx context.Context, code string) (*model.Plan, error) {
	row := r.pool.QueryRow(ctx,
		`SELECT id, code, name, price_cents, max_instances, period_days FROM plans WHERE code=$1`, code)
	var p model.Plan
	if err := row.Scan(&p.ID, &p.Code, &p.Name, &p.PriceCents, &p.MaxInstances, &p.PeriodDays); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return &p, nil
}

// ===== Releases =====

func (r *Repo) GetReleaseManifest(ctx context.Context, version string) (map[string]any, error) {
	var manifest map[string]any
	err := r.pool.QueryRow(ctx,
		`SELECT manifest FROM releases WHERE version=$1`, version).Scan(&manifest)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	return manifest, err
}

func (r *Repo) GetRelease(ctx context.Context, version string) (string, map[string]any, error) {
	var masterKeyHex string
	var manifest map[string]any
	err := r.pool.QueryRow(ctx,
		`SELECT master_key_hex, manifest FROM releases WHERE version=$1`, version).Scan(&masterKeyHex, &manifest)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil, ErrNotFound
	}
	return masterKeyHex, manifest, err
}

func (r *Repo) PutRelease(ctx context.Context, version, masterKeyHex string, manifest map[string]any) error {
	_, err := r.pool.Exec(ctx, `
		INSERT INTO releases (version, master_key_hex, manifest) VALUES ($1,$2,$3::jsonb)
		ON CONFLICT (version) DO UPDATE SET manifest=EXCLUDED.manifest, master_key_hex=EXCLUDED.master_key_hex`,
		version, masterKeyHex, jsonOrNull(manifest))
	return err
}

// ===== helpers =====

func nullable(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func jsonOrNull(m map[string]any) any {
	if m == nil {
		return "{}"
	}
	b, err := json.Marshal(m)
	if err != nil {
		return "{}"
	}
	return string(b)
}
