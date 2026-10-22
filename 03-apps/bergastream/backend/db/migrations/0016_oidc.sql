-- migrate:up

-- Login pelo Authentik (OIDC). Cada usuário fica ligado ao "sub" do
-- Authentik no primeiro login (pelo username ou pelo e-mail): as contas,
-- playlists e o histórico de antes continuam os mesmos.
ALTER TABLE users
    ADD COLUMN oidc_subject text,
    ADD COLUMN email        text,
    ADD COLUMN last_login_at timestamptz;

CREATE UNIQUE INDEX users_oidc_subject ON users (oidc_subject) WHERE oidc_subject IS NOT NULL;
CREATE INDEX users_email_lower ON users (lower(email));

-- migrate:down

DROP INDEX users_email_lower;
DROP INDEX users_oidc_subject;
ALTER TABLE users DROP COLUMN last_login_at, DROP COLUMN email, DROP COLUMN oidc_subject;
