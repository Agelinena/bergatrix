-- migrate:up

-- Pessoas que entraram pelo Authentik. A ligação é pelo "sub" do OIDC;
-- nome, usuário e e-mail seguem os do Authentik a cada login.
CREATE TABLE users (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    oidc_subject   text        NOT NULL UNIQUE,
    username       text        NOT NULL,
    name           text        NOT NULL DEFAULT '',
    email          text        NOT NULL DEFAULT '',
    is_admin       boolean     NOT NULL DEFAULT false,
    created_at     timestamptz NOT NULL DEFAULT now(),
    last_login_at  timestamptz
);

-- Login em andamento (state, nonce e PKCE), apagado no retorno do Authentik.
CREATE TABLE login_states (
    state       text PRIMARY KEY,
    nonce       text        NOT NULL,
    verifier    text        NOT NULL,
    next_path   text        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- Sessões da interface web. Só o hash SHA-256 do cookie fica aqui.
CREATE TABLE sessions (
    token_hash    text PRIMARY KEY,
    user_id       uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at    timestamptz NOT NULL DEFAULT now(),
    expires_at    timestamptz NOT NULL,
    last_seen_at  timestamptz NOT NULL DEFAULT now(),
    user_agent    text        NOT NULL DEFAULT ''
);
CREATE INDEX sessions_user ON sessions (user_id);

-- Tokens pessoais da API (Authorization: Bearer trs_…). Só o hash fica aqui.
CREATE TABLE api_tokens (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name          text        NOT NULL,
    prefix        text        NOT NULL,
    token_hash    text        NOT NULL UNIQUE,
    created_at    timestamptz NOT NULL DEFAULT now(),
    last_used_at  timestamptz
);
CREATE INDEX api_tokens_user ON api_tokens (user_id);

-- Transcrições. A fila é esta tabela: o worker pega o próximo "queued" com
-- FOR UPDATE SKIP LOCKED e manda sinal de vida em heartbeat_at.
CREATE TABLE jobs (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id            uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    title              text        NOT NULL,
    source_kind        text        NOT NULL CHECK (source_kind IN ('upload', 'url')),
    source_url         text,
    source_bytes       bigint,
    model              text        NOT NULL,
    language           text,                        -- null = detectar
    prompt             text        NOT NULL DEFAULT '',
    status             text        NOT NULL DEFAULT 'queued' CHECK (status IN (
                           'uploading', 'queued', 'downloading', 'preparing',
                           'transcribing', 'done', 'failed', 'canceled')),
    progress           real        NOT NULL DEFAULT 0,
    error              text,
    duration_seconds   real,
    detected_language  text,
    has_audio          boolean     NOT NULL DEFAULT false,
    cancel_requested   boolean     NOT NULL DEFAULT false,
    attempts           integer     NOT NULL DEFAULT 0,
    worker             text,
    heartbeat_at       timestamptz,
    created_at         timestamptz NOT NULL DEFAULT now(),
    started_at         timestamptz,
    finished_at        timestamptz,
    transcript         text        NOT NULL DEFAULT '',
    search             tsvector GENERATED ALWAYS AS (
                           to_tsvector('portuguese', title || ' ' || transcript)) STORED
);
CREATE INDEX jobs_user_created ON jobs (user_id, created_at DESC);
CREATE INDEX jobs_queue ON jobs (created_at) WHERE status = 'queued';
CREATE INDEX jobs_search ON jobs USING gin (search);

-- Trechos com horário. Editáveis pela interface.
CREATE TABLE segments (
    job_id    uuid    NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    idx       integer NOT NULL,
    start_ms  integer NOT NULL,
    end_ms    integer NOT NULL,
    text      text    NOT NULL,
    edited    boolean NOT NULL DEFAULT false,
    PRIMARY KEY (job_id, idx)
);

-- Estado de cada worker (GPU, modelo carregado, validação dos modelos).
CREATE TABLE workers (
    name          text PRIMARY KEY,
    started_at    timestamptz NOT NULL DEFAULT now(),
    heartbeat_at  timestamptz NOT NULL DEFAULT now(),
    state         text        NOT NULL,
    detail        jsonb       NOT NULL DEFAULT '{}'
);

-- Avisos para a API (eventos na tela) e para o worker (fila nova).
CREATE FUNCTION jobs_notify() RETURNS trigger AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        PERFORM pg_notify('transcriptor_jobs', json_build_object(
            'id', OLD.id, 'user', OLD.user_id, 'deleted', true)::text);
        RETURN OLD;
    END IF;
    PERFORM pg_notify('transcriptor_jobs', json_build_object(
        'id', NEW.id, 'user', NEW.user_id, 'status', NEW.status,
        'progress', NEW.progress)::text);
    IF NEW.status = 'queued' AND (TG_OP = 'INSERT' OR OLD.status <> 'queued') THEN
        PERFORM pg_notify('transcriptor_queue', NEW.id::text);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER jobs_notify_change
    AFTER INSERT OR DELETE OR UPDATE OF status, progress, title, error, cancel_requested ON jobs
    FOR EACH ROW EXECUTE FUNCTION jobs_notify();

-- migrate:down

DROP TRIGGER jobs_notify_change ON jobs;
DROP FUNCTION jobs_notify();
DROP TABLE workers;
DROP TABLE segments;
DROP TABLE jobs;
DROP TABLE api_tokens;
DROP TABLE sessions;
DROP TABLE login_states;
DROP TABLE users;
