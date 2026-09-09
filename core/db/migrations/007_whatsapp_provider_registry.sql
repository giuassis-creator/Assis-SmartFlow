CREATE TABLE IF NOT EXISTS organization_whatsapp_providers (
  organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  provider text NOT NULL CHECK (provider IN ('waha','wppconnect','evolution','meta')),
  session_name text NOT NULL,
  priority integer NOT NULL DEFAULT 100 CHECK (priority >= 0),
  enabled boolean NOT NULL DEFAULT true,
  config jsonb NOT NULL DEFAULT '{}'::jsonb,
  health_status text NOT NULL DEFAULT 'unknown' CHECK (health_status IN ('unknown','healthy','degraded','down')),
  last_health_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (organization_id, provider, session_name)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_org_whatsapp_provider_priority
  ON organization_whatsapp_providers(organization_id, priority)
  WHERE enabled;

CREATE INDEX IF NOT EXISTS idx_org_whatsapp_provider_active
  ON organization_whatsapp_providers(organization_id, enabled, priority);

COMMENT ON TABLE organization_whatsapp_providers IS
  'Provider/session routing metadata per organization. Secrets must never be stored here; only non-secret provider/session configuration is allowed.';
