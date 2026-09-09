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
