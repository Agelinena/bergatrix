-- migrate:up

-- Gestão de contas: desativar sem apagar (playlists e histórico ficam) e
-- links de "redefinir senha" por e-mail (só o hash do token é guardado).
ALTER TABLE users ADD COLUMN disabled_at timestamptz;

-- Um e-mail por conta: a ligação com o Authentik pelo e-mail não pode ser
-- ambígua (e os avisos vão para uma pessoa só).
DROP INDEX users_email_lower;
CREATE UNIQUE INDEX users_email_lower ON users (lower(email)) WHERE email IS NOT NULL;

CREATE TABLE password_resets (
    token_hash  text        PRIMARY KEY,
    user_id     uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    expires_at  timestamptz NOT NULL,
    used_at     timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX password_resets_user ON password_resets (user_id);

-- migrate:down

DROP TABLE password_resets;
DROP INDEX users_email_lower;
CREATE INDEX users_email_lower ON users (lower(email));
ALTER TABLE users DROP COLUMN disabled_at;
