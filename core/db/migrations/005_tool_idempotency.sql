CREATE TABLE IF NOT EXISTS tool_idempotency (
  organization_id uuid NOT NULL,
  operation text NOT NULL,
  idempotency_key text NOT NULL,
  status text NOT NULL DEFAULT 'claimed' CHECK (status IN ('claimed','completed')),
  response jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (organization_id, operation, idempotency_key)
);

CREATE INDEX IF NOT EXISTS idx_tool_idempotency_updated_at
  ON tool_idempotency(updated_at);

COMMENT ON TABLE tool_idempotency IS 'Durable at-most-once gate for side-effecting tool calls. Duplicate keys are rejected before provider execution.';
