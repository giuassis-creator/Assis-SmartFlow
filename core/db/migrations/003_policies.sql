CREATE TABLE IF NOT EXISTS idempotency_keys (
 organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
 key text NOT NULL, operation text NOT NULL, response jsonb, created_at timestamptz NOT NULL DEFAULT now(), expires_at timestamptz,
 PRIMARY KEY(organization_id,key)
);
CREATE TABLE IF NOT EXISTS retention_policies (
 organization_id uuid PRIMARY KEY REFERENCES organizations(id) ON DELETE CASCADE,
 message_days int NOT NULL DEFAULT 365, audit_days int NOT NULL DEFAULT 730, handoff_days int NOT NULL DEFAULT 365,
 document_days int NOT NULL DEFAULT 730, updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS rag_chunks (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
 document_id uuid NOT NULL REFERENCES knowledge_documents(id) ON DELETE CASCADE, chunk_index int NOT NULL,
 content text NOT NULL, embedding vector(768), metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
 UNIQUE(document_id,chunk_index)
);
CREATE INDEX IF NOT EXISTS rag_chunks_embedding_idx ON rag_chunks USING ivfflat (embedding vector_cosine_ops) WITH (lists=100);
