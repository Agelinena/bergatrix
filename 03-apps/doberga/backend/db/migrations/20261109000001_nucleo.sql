-- migrate:up

-- Núcleo do Doberga: pessoas, espaços (pessoal e grupos), convites e a base
-- do sync. As tabelas dos módulos entram em migrações próprias e seguem o
-- contrato descrito em "Tabelas sincronizadas", no fim deste arquivo.

-- ── Pessoas ─────────────────────────────────────────────────────────
-- As contas vêm do Authentik (OIDC): ligadas pelo "sub", criadas no 1º login.
CREATE TABLE users (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    username       text        NOT NULL,
    name           text        NOT NULL,
    email          text,
    oidc_subject   text UNIQUE,
    is_admin       boolean     NOT NULL DEFAULT false,
    disabled_at    timestamptz,
    last_login_at  timestamptz,
    created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX users_username_lower ON users (lower(username));
CREATE UNIQUE INDEX users_email_lower ON users (lower(email)) WHERE email IS NOT NULL;

-- Só o hash SHA-256. Cada uso gera um token novo na mesma família. Um token
-- trocado ainda vale por alguns segundos (resposta perdida na rede); depois
-- disso, se reaparecer, revoga a família inteira (sinal de roubo).
CREATE TABLE refresh_tokens (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id        uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    family_id      uuid        NOT NULL,
    token_hash     text        NOT NULL UNIQUE,
    created_at     timestamptz NOT NULL DEFAULT now(),
    expires_at     timestamptz NOT NULL,
    revoked_at     timestamptz,
    -- rotated (trocado), logout, reuse (reapareceu depois da tolerância), admin
    revoke_reason  text,
    user_agent     text
);
CREATE INDEX idx_refresh_tokens_user ON refresh_tokens (user_id);
CREATE INDEX idx_refresh_tokens_family ON refresh_tokens (family_id);

-- Abas, tema, espaço padrão de cada módulo: um JSON por pessoa, validado pela API.
CREATE TABLE user_prefs (
    user_id     uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    prefs       jsonb       NOT NULL DEFAULT '{}'::jsonb,
    updated_at  timestamptz NOT NULL DEFAULT now()
);

-- ── Espaços ─────────────────────────────────────────────────────────
-- Todo dado de módulo pertence a um espaço. "personal": um por pessoa, criado
-- no primeiro login, só dela. "group": criado por qualquer pessoa, com
-- membros. Apagar um grupo apaga tudo dele (ON DELETE CASCADE nos módulos).
CREATE TABLE spaces (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    kind              text        NOT NULL CHECK (kind IN ('personal', 'group')),
    name              text        NOT NULL CHECK (length(name) BETWEEN 1 AND 60),
    color             text,
    icon              text,
    personal_user_id  uuid UNIQUE REFERENCES users(id) ON DELETE CASCADE,
    created_by        uuid        REFERENCES users(id) ON DELETE SET NULL,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    CHECK ((kind = 'personal') = (personal_user_id IS NOT NULL))
);

CREATE TABLE space_members (
    space_id   uuid        NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
    user_id    uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role       text        NOT NULL CHECK (role IN ('owner', 'member')),
    joined_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (space_id, user_id)
);
CREATE INDEX idx_space_members_user ON space_members (user_id);

-- O link leva o token; aqui fica só o hash.
CREATE TABLE space_invites (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    space_id    uuid        NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
    token_hash  text        NOT NULL UNIQUE,
    created_by  uuid        REFERENCES users(id) ON DELETE SET NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz NOT NULL,
    uses_left   integer     NOT NULL CHECK (uses_left >= 0),
    revoked_at  timestamptz
);
CREATE INDEX idx_space_invites_space ON space_invites (space_id);

-- ── Sync ────────────────────────────────────────────────────────────
-- Cada gravação numa tabela sincronizada recebe o próximo número desta
-- sequência (rev). O aparelho guarda, por espaço, o maior rev que já recebeu.
CREATE SEQUENCE sync_rev;

-- Operações já aplicadas: reenviar uma operação (resposta perdida) devolve o
-- mesmo resultado, sem aplicar de novo.
CREATE TABLE applied_ops (
    op_id       uuid PRIMARY KEY,
    user_id     uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    result      jsonb       NOT NULL,
    applied_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_applied_ops_applied_at ON applied_ops (applied_at);

-- purged_rev: maior rev de lápide já apagada de vez. Aparelho com cursor
-- abaixo disso pode ter perdido uma exclusão e refaz o espaço do zero.
CREATE TABLE sync_meta (
    key    text PRIMARY KEY,
    value  bigint NOT NULL
);
INSERT INTO sync_meta (key, value) VALUES ('purged_rev', 0);

-- Toda gravação numa tabela sincronizada passa por aqui. O lock serializa as
-- gravações até o commit: assim o rev cresce na mesma ordem em que as linhas
-- ficam visíveis, e um pull nunca pula uma linha que ainda ia aparecer com
-- rev menor que o cursor. O volume (uma família) permite um lock global.
CREATE FUNCTION sync_touch() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_advisory_xact_lock(7461001);
    NEW.rev := nextval('sync_rev');
    NEW.updated_at := now();
    IF TG_OP = 'UPDATE' THEN
        NEW.id := OLD.id;
        NEW.space_id := OLD.space_id;     -- o espaço de uma linha não muda
        NEW.created_at := OLD.created_at;
        NEW.created_by := OLD.created_by;
    END IF;
    RETURN NEW;
END $$;

-- ── Tabelas sincronizadas (contrato dos módulos) ────────────────────
-- Toda tabela de módulo começa com estas colunas e o trigger:
--
--   id          uuid PRIMARY KEY,          -- UUIDv7 gerado no aparelho
--   space_id    uuid NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
--   rev         bigint NOT NULL,
--   created_at  timestamptz NOT NULL DEFAULT now(),
--   created_by  uuid REFERENCES users(id) ON DELETE SET NULL,
--   updated_at  timestamptz NOT NULL DEFAULT now(),
--   updated_by  uuid REFERENCES users(id) ON DELETE SET NULL,
--   deleted_at  timestamptz,
--   ...campos do módulo...
--
--   CREATE INDEX ON <tabela> (space_id, rev);
--   CREATE TRIGGER <tabela>_sync BEFORE INSERT OR UPDATE ON <tabela>
--       FOR EACH ROW EXECUTE FUNCTION sync_touch();
--
-- e entra no registro do sync (backend/app/sync/registry.py).

-- migrate:down
DROP FUNCTION sync_touch();
DROP TABLE sync_meta;
DROP TABLE applied_ops;
DROP SEQUENCE sync_rev;
DROP TABLE space_invites;
DROP TABLE space_members;
DROP TABLE spaces;
DROP TABLE user_prefs;
DROP TABLE refresh_tokens;
DROP TABLE users;
