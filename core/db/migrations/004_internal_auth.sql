CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS internal_auth_secrets (
  name text PRIMARY KEY,
  token_sha256 text NOT NULL CHECK (token_sha256 ~ '^[0-9a-f]{64}$'),
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE internal_auth_secrets IS 'Stores only one-way hashes for service-to-service authentication; raw tokens remain outside PostgreSQL.';
