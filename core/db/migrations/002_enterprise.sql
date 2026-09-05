CREATE TABLE IF NOT EXISTS roles (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid REFERENCES organizations(id) ON DELETE CASCADE,
 name text NOT NULL, permissions jsonb NOT NULL DEFAULT '[]'::jsonb, UNIQUE(organization_id,name)
);
CREATE TABLE IF NOT EXISTS actor_roles (
 organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE, actor_id text NOT NULL, role_id uuid NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
 PRIMARY KEY(organization_id,actor_id,role_id)
);
CREATE TABLE IF NOT EXISTS approval_requests (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
 action text NOT NULL, requested_by text NOT NULL, payload jsonb NOT NULL, status text NOT NULL DEFAULT 'pending', approved_by text,
 created_at timestamptz NOT NULL DEFAULT now(), decided_at timestamptz
);
CREATE TABLE IF NOT EXISTS dead_letter_events (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid REFERENCES organizations(id) ON DELETE SET NULL,
 source text NOT NULL, event_key text, payload jsonb NOT NULL, error text NOT NULL, attempts int NOT NULL DEFAULT 1,
 next_retry_at timestamptz, status text NOT NULL DEFAULT 'pending', created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_dlq_retry ON dead_letter_events(status,next_retry_at);
