-- migrate:up

-- Credenciais nos usuários existentes. Os usuários de teste ("User A",
-- "User B") ganham username "usera"/"userb" e ficam sem senha até alguém
-- definir uma com `python -m app.auth.cli set-password`.
ALTER TABLE users
    ADD COLUMN username      text,
    ADD COLUMN password_hash text,
    ADD COLUMN is_admin      boolean     NOT NULL DEFAULT false,
    ADD COLUMN created_at    timestamptz NOT NULL DEFAULT now();

UPDATE users SET username = lower(regexp_replace(name, '\s+', '', 'g'));

ALTER TABLE users ALTER COLUMN username SET NOT NULL;
CREATE UNIQUE INDEX users_username_lower ON users (lower(username));

-- Refresh tokens: só o hash SHA-256 é guardado. Cada uso gera um token novo
-- (rotação) na mesma família; reutilizar um token já trocado revoga a
-- família inteira (sinal de roubo).
CREATE TABLE refresh_tokens (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    family_id   uuid        NOT NULL,
    token_hash  text        NOT NULL UNIQUE,
    created_at  timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz NOT NULL,
    revoked_at  timestamptz,
    user_agent  text
);

CREATE INDEX idx_refresh_tokens_user ON refresh_tokens (user_id);
CREATE INDEX idx_refresh_tokens_family ON refresh_tokens (family_id);

-- migrate:down

DROP TABLE refresh_tokens;
DROP INDEX users_username_lower;
ALTER TABLE users
    DROP COLUMN created_at,
    DROP COLUMN is_admin,
    DROP COLUMN password_hash,
    DROP COLUMN username;
