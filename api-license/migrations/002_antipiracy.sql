-- XSP Anti-piracy — vincula instalação ao IP de ativação e rastreia último IP visto

ALTER TABLE installations
    ADD COLUMN IF NOT EXISTS activation_ip  INET,        -- IP registrado na ativação (imutável)
    ADD COLUMN IF NOT EXISTS last_ip        INET,        -- último IP de heartbeat (auditoria)
    ADD COLUMN IF NOT EXISTS last_ip_at     TIMESTAMPTZ; -- quando foi o último heartbeat

CREATE INDEX IF NOT EXISTS idx_install_hwid ON installations(hwid, status);
