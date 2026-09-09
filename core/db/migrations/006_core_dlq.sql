-- Core-owned DLQ schema. This migration is intentionally idempotent so it can be
-- applied both to fresh installations and to existing PostgreSQL volumes.
CREATE TABLE IF NOT EXISTS dead_letter_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid REFERENCES organizations(id) ON DELETE SET NULL,
  source text NOT NULL,
  event_key text,
  payload jsonb NOT NULL,
  error text NOT NULL,
  attempts int NOT NULL DEFAULT 1,
  next_retry_at timestamptz,
  status text NOT NULL DEFAULT 'pending',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_dlq_retry
  ON dead_letter_events(status, next_retry_at);

CREATE INDEX IF NOT EXISTS idx_dlq_event_key
  ON dead_letter_events(event_key)
  WHERE event_key IS NOT NULL;

COMMENT ON TABLE dead_letter_events IS
  'Core dead-letter queue for failed internal events; owned by the Core runtime.';
