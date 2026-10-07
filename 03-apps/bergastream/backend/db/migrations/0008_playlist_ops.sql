-- migrate:up

-- Alterações de playlist enviadas pelos apps (inclusive as feitas offline).
-- Cada operação tem um id gerado no aparelho: reenviar a mesma operação
-- devolve o resultado guardado em vez de aplicar de novo.
CREATE TABLE playlist_ops (
    op_id      uuid PRIMARY KEY,
    user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    result     jsonb NOT NULL,
    applied_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_playlist_ops_applied ON playlist_ops (applied_at);

-- migrate:down

DROP TABLE playlist_ops;
