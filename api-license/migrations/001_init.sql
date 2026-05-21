-- XSP Licensing — initial schema
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS citext;

CREATE TABLE IF NOT EXISTS customers (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email       CITEXT UNIQUE NOT NULL,
    name        TEXT,
    phone       TEXT,
    stripe_id   TEXT,
    status      TEXT NOT NULL DEFAULT 'active',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS plans (
    id              SERIAL PRIMARY KEY,
    code            TEXT UNIQUE NOT NULL,
    name            TEXT NOT NULL,
    price_cents     INT  NOT NULL DEFAULT 0,
    max_instances   INT  NOT NULL DEFAULT 1,
    features        JSONB NOT NULL DEFAULT '{}'::jsonb,
    period_days     INT  NOT NULL DEFAULT 30,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO plans (code, name, price_cents, max_instances, period_days)
VALUES
    ('trial',      'Trial 7 dias',  0,     1, 7),
    ('basic',      'Básico',        9990,  1, 30),
    ('pro',        'Profissional',  19990, 3, 30),
    ('enterprise', 'Enterprise',    49990, 10, 30)
ON CONFLICT (code) DO NOTHING;

CREATE TABLE IF NOT EXISTS licenses (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id     UUID NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
    plan_id         INT  NOT NULL REFERENCES plans(id),
    key             TEXT UNIQUE NOT NULL,
    key_hash        TEXT UNIQUE NOT NULL,
    status          TEXT NOT NULL DEFAULT 'active',
    expires_at      TIMESTAMPTZ NOT NULL,
    max_instances   INT  NOT NULL DEFAULT 1,
    grace_period_h  INT  NOT NULL DEFAULT 24,
    notes           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    revoked_at      TIMESTAMPTZ,
    revoked_reason  TEXT,
    CHECK (status IN ('pending','active','expired','revoked','suspended'))
);
CREATE INDEX IF NOT EXISTS idx_licenses_key_hash ON licenses(key_hash);
CREATE INDEX IF NOT EXISTS idx_licenses_status   ON licenses(status, expires_at);

CREATE TABLE IF NOT EXISTS installations (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    license_id          UUID NOT NULL REFERENCES licenses(id) ON DELETE CASCADE,
    hwid                TEXT NOT NULL,
    hostname            TEXT,
    public_ip           INET,
    domain              TEXT,
    os                  TEXT,
    os_version          TEXT,
    panel_version       TEXT,
    installer_version   TEXT,
    fingerprint_v2      JSONB,
    status              TEXT NOT NULL DEFAULT 'active',
    activated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_seen_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deactivated_at      TIMESTAMPTZ,
    UNIQUE(license_id, hwid),
    CHECK (status IN ('active','blocked','frozen','deactivated'))
);
CREATE INDEX IF NOT EXISTS idx_install_license ON installations(license_id, status);

CREATE TABLE IF NOT EXISTS validation_logs (
    id              BIGSERIAL PRIMARY KEY,
    installation_id UUID REFERENCES installations(id) ON DELETE CASCADE,
    license_id      UUID REFERENCES licenses(id) ON DELETE CASCADE,
    ip              INET,
    user_agent      TEXT,
    result          TEXT NOT NULL,
    latency_ms      INT,
    signed          BOOLEAN,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_vlog_install ON validation_logs(installation_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_vlog_license ON validation_logs(license_id, created_at DESC);

CREATE TABLE IF NOT EXISTS subscriptions (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id         UUID NOT NULL REFERENCES customers(id),
    license_id          UUID NOT NULL REFERENCES licenses(id),
    provider            TEXT NOT NULL,
    provider_ref        TEXT,
    status              TEXT NOT NULL,
    current_period_end  TIMESTAMPTZ NOT NULL,
    cancel_at           TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS blacklist (
    id         BIGSERIAL PRIMARY KEY,
    kind       TEXT NOT NULL,
    value      TEXT NOT NULL,
    reason     TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(kind, value),
    CHECK (kind IN ('hwid','ip','cidr','key','email'))
);

CREATE TABLE IF NOT EXISTS fraud_events (
    id              BIGSERIAL PRIMARY KEY,
    installation_id UUID,
    license_id      UUID,
    kind            TEXT NOT NULL,
    payload         JSONB,
    severity        SMALLINT NOT NULL DEFAULT 1,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS releases (
    version         TEXT PRIMARY KEY,
    master_key_hex  TEXT NOT NULL,
    manifest        JSONB NOT NULL,
    published_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    canary_pct      INT NOT NULL DEFAULT 100
);

CREATE TABLE IF NOT EXISTS admin_audit (
    id           BIGSERIAL PRIMARY KEY,
    admin_email  TEXT,
    action       TEXT NOT NULL,
    target       TEXT,
    payload      JSONB,
    ip           INET,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
