-- migrate:up

-- Histórico de reprodução (Passo 10 do app): base das métricas da tela
-- inicial. client_id é gerado no app por reprodução: reenviar a mesma
-- (fila offline do Passo 11) não duplica.
CREATE TABLE play_history (
    id         bigserial PRIMARY KEY,
    user_id    uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    track_id   uuid        NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
    client_id  uuid        NOT NULL UNIQUE,
    played_at  timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_play_history_user_time ON play_history (user_id, played_at DESC);

-- migrate:down

DROP TABLE play_history;
