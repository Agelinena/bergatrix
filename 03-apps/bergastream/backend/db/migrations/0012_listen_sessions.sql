-- migrate:up

-- Sessões compartilhadas ("ouvir junto"): todos ouvem a mesma coisa. O
-- estado da reprodução (fila, faixa atual, posição) fica em `playback`.
CREATE TABLE listen_sessions (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id   uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name       text NOT NULL DEFAULT '',
    -- 'all': pausar pausa para todos; 'individual': só para quem pausou.
    pause_mode text NOT NULL DEFAULT 'all' CHECK (pause_mode IN ('all', 'individual')),
    playback   jsonb NOT NULL DEFAULT '{}',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    ended_at   timestamptz
);

CREATE TABLE listen_session_members (
    session_id uuid NOT NULL REFERENCES listen_sessions(id) ON DELETE CASCADE,
    user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    status     text NOT NULL CHECK (status IN ('invited', 'joined', 'left', 'declined')),
    invited_by uuid REFERENCES users(id) ON DELETE SET NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (session_id, user_id)
);

CREATE INDEX idx_session_members_user ON listen_session_members (user_id, status);

-- migrate:down

DROP TABLE listen_session_members;
DROP TABLE listen_sessions;
