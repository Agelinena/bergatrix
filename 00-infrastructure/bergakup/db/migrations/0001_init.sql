-- migrate:up

-- ── Login (Authentik, OIDC) ─────────────────────────────────────────
CREATE TABLE users (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    oidc_subject   text        NOT NULL UNIQUE,
    username       text        NOT NULL,
    name           text        NOT NULL DEFAULT '',
    email          text        NOT NULL DEFAULT '',
    created_at     timestamptz NOT NULL DEFAULT now(),
    last_login_at  timestamptz
);

CREATE TABLE login_states (
    state       text PRIMARY KEY,
    nonce       text        NOT NULL,
    verifier    text        NOT NULL,
    next_path   text        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- Só o hash SHA-256 do cookie fica aqui.
CREATE TABLE sessions (
    token_hash    text PRIMARY KEY,
    user_id       uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at    timestamptz NOT NULL DEFAULT now(),
    expires_at    timestamptz NOT NULL,
    last_seen_at  timestamptz NOT NULL DEFAULT now(),
    user_agent    text        NOT NULL DEFAULT ''
);
CREATE INDEX sessions_user ON sessions (user_id);

-- ── Agentes ─────────────────────────────────────────────────────────
-- O agente roda no host (systemd) e é quem executa tudo. A web só guarda a
-- configuração. public_key: chave X25519 do agente; os segredos digitados na
-- web são cifrados no navegador para ela (sealed box) e só o agente abre.
CREATE TABLE agents (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name              text        NOT NULL UNIQUE,
    hostname          text        NOT NULL DEFAULT '',
    public_key        text        NOT NULL,
    token_hash        text        NOT NULL UNIQUE,
    version           text        NOT NULL DEFAULT '',
    applied_revision  integer     NOT NULL DEFAULT 0,
    apply_error       text,
    info              jsonb       NOT NULL DEFAULT '{}',
    last_seen_at      timestamptz,
    created_at        timestamptz NOT NULL DEFAULT now()
);

-- Código de uso único para instalar um agente (bergakup-agent enroll).
CREATE TABLE enrollment_codes (
    code_hash   text PRIMARY KEY,
    created_by  uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz NOT NULL,
    used_at     timestamptz,
    agent_id    uuid REFERENCES agents(id) ON DELETE SET NULL
);

-- Caminhos do host, fuso e e-mail de cada agente.
CREATE TABLE agent_settings (
    agent_id               uuid PRIMARY KEY REFERENCES agents(id) ON DELETE CASCADE,
    timezone               text        NOT NULL DEFAULT 'America/Sao_Paulo',
    repo_root              text        NOT NULL DEFAULT '',
    stacks_file            text        NOT NULL DEFAULT '',
    dumps_dir              text        NOT NULL DEFAULT '/srv/appdata/bergakup/dumps',
    smtp                   jsonb       NOT NULL DEFAULT '{}',
    smtp_password_sealed   text,
    updated_at             timestamptz NOT NULL DEFAULT now()
);

-- ── O que, onde e quando ────────────────────────────────────────────
-- Destino: um bucket do B2, uma pasta local/NAS, um rest-server ou SFTP.
-- username: Key ID do B2 ou usuário do rest-server. secret_sealed: a chave.
CREATE TABLE storages (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    agent_id       uuid        NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
    name           text        NOT NULL,
    kind           text        NOT NULL CHECK (kind IN ('b2', 'local', 'rest', 'sftp')),
    endpoint       text        NOT NULL DEFAULT '',
    region         text        NOT NULL DEFAULT '',
    bucket         text        NOT NULL DEFAULT '',
    path           text        NOT NULL DEFAULT '',
    username       text        NOT NULL DEFAULT '',
    secret_sealed  text,
    lock_days      integer     NOT NULL DEFAULT 0,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (agent_id, name)
);

-- Conjunto de dados: userdata (NAS), docker (pasta do repositório e .env),
-- servidor (HD: appdata e dumps dos bancos) ou um personalizado.
--   none      só copia os arquivos
--   policies  faz os dumps e aplica a política de cada stack (stop/pause/skip)
--   cold      faz os dumps e para todas as stacks durante a cópia
CREATE TABLE datasets (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    agent_id     uuid        NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
    slug         text        NOT NULL CHECK (slug ~ '^[a-z0-9][a-z0-9-]{0,39}$'),
    name         text        NOT NULL,
    kind         text        NOT NULL CHECK (kind IN ('userdata', 'docker', 'servidor', 'custom')),
    paths        text[]      NOT NULL DEFAULT '{}',
    excludes     text[]      NOT NULL DEFAULT '{}',
    consistency  text        NOT NULL DEFAULT 'none' CHECK (consistency IN ('none', 'policies', 'cold')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (agent_id, slug)
);

-- Repositório restic: um conjunto num destino. Cada um tem a sua senha.
CREATE TABLE repositories (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    dataset_id        uuid        NOT NULL REFERENCES datasets(id) ON DELETE CASCADE,
    storage_id        uuid        NOT NULL REFERENCES storages(id) ON DELETE RESTRICT,
    subpath           text        NOT NULL,
    password_sealed   text,
    initialized_at    timestamptz,
    recovery_key_at   timestamptz,
    created_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (dataset_id, storage_id)
);

-- Tarefa agendada sobre um repositório.
CREATE TABLE jobs (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    repository_id   uuid        NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
    name            text        NOT NULL,
    enabled         boolean     NOT NULL DEFAULT true,
    schedule        text        NOT NULL DEFAULT '0 3 * * *',
    retention       jsonb       NOT NULL DEFAULT '{"daily": 3, "weekly": 4}',
    prune_schedule  text        NOT NULL DEFAULT '30 4 * * 0',
    check_schedule  text        NOT NULL DEFAULT '0 6 1 * *',
    check_subset    text        NOT NULL DEFAULT '5%',
    anomaly_pct     real        NOT NULL DEFAULT 30,
    stale_hours     integer     NOT NULL DEFAULT 26,
    ping_url        text        NOT NULL DEFAULT '',
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

-- Política de cada stack durante o backup do servidor:
--   hot   copia com tudo rodando (padrão)
--   stop  para os containers da stack durante a cópia
--   pause congela os containers (docker pause) durante a cópia
--   skip  fica fora do backup
CREATE TABLE stack_policies (
    agent_id  uuid NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
    stack     text NOT NULL,
    mode      text NOT NULL CHECK (mode IN ('hot', 'stop', 'pause', 'skip')),
    PRIMARY KEY (agent_id, stack)
);

-- Cada mudança na configuração vira uma revisão. O agente baixa a mais nova,
-- valida, aplica e confirma (agents.applied_revision).
CREATE TABLE config_revisions (
    agent_id    uuid        NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
    revision    integer     NOT NULL,
    document    jsonb       NOT NULL,
    checksum    text        NOT NULL,
    created_by  uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (agent_id, revision)
);

-- ── Execução ────────────────────────────────────────────────────────
-- Pedidos da web para o agente (rodar agora, restaurar, listar...).
CREATE TABLE commands (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    agent_id       uuid        NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
    kind           text        NOT NULL,
    params         jsonb       NOT NULL DEFAULT '{}',
    status         text        NOT NULL DEFAULT 'pending'
                       CHECK (status IN ('pending', 'dispatched', 'done', 'failed', 'canceled')),
    run_id         uuid,
    created_by     uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at     timestamptz NOT NULL DEFAULT now(),
    dispatched_at  timestamptz,
    finished_at    timestamptz
);
CREATE INDEX commands_pending ON commands (agent_id, created_at) WHERE status = 'pending';

-- Toda execução do agente (agendada ou pedida). O id vem do agente.
CREATE TABLE runs (
    id             uuid PRIMARY KEY,
    agent_id       uuid        NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
    kind           text        NOT NULL,
    job_id         uuid REFERENCES jobs(id) ON DELETE SET NULL,
    repository_id  uuid REFERENCES repositories(id) ON DELETE SET NULL,
    command_id     uuid REFERENCES commands(id) ON DELETE SET NULL,
    trigger        text        NOT NULL DEFAULT 'schedule',
    status         text        NOT NULL DEFAULT 'running'
                       CHECK (status IN ('running', 'success', 'warning', 'failed')),
    started_at     timestamptz NOT NULL DEFAULT now(),
    finished_at    timestamptz,
    summary        jsonb       NOT NULL DEFAULT '{}',
    error          text
);
CREATE INDEX runs_started ON runs (started_at DESC);
CREATE INDEX runs_job ON runs (job_id, started_at DESC);

CREATE TABLE run_logs (
    run_id  uuid        NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
    seq     integer     NOT NULL,
    ts      timestamptz NOT NULL,
    level   text        NOT NULL,
    line    text        NOT NULL,
    PRIMARY KEY (run_id, seq)
);

-- Cópia da lista de snapshots de cada repositório (o agente atualiza).
CREATE TABLE snapshots (
    repository_id  uuid        NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
    snapshot_id    text        NOT NULL,
    short_id       text        NOT NULL,
    time           timestamptz NOT NULL,
    hostname       text        NOT NULL DEFAULT '',
    paths          text[]      NOT NULL DEFAULT '{}',
    tags           text[]      NOT NULL DEFAULT '{}',
    summary        jsonb       NOT NULL DEFAULT '{}',
    PRIMARY KEY (repository_id, snapshot_id)
);

CREATE TABLE notifications (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    agent_id    uuid REFERENCES agents(id) ON DELETE CASCADE,
    level       text        NOT NULL CHECK (level IN ('info', 'warning', 'error')),
    title       text        NOT NULL,
    body        text        NOT NULL DEFAULT '',
    dedupe_key  text,
    run_id      uuid REFERENCES runs(id) ON DELETE SET NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    read_at     timestamptz
);
CREATE UNIQUE INDEX notifications_dedupe ON notifications (dedupe_key) WHERE dedupe_key IS NOT NULL AND read_at IS NULL;
CREATE INDEX notifications_created ON notifications (created_at DESC);

CREATE TABLE audit_log (
    id       bigserial PRIMARY KEY,
    ts       timestamptz NOT NULL DEFAULT now(),
    user_id  uuid REFERENCES users(id) ON DELETE SET NULL,
    action   text        NOT NULL,
    detail   jsonb       NOT NULL DEFAULT '{}'
);

-- migrate:down
DROP TABLE audit_log, notifications, snapshots, run_logs, runs, commands, config_revisions,
    stack_policies, jobs, repositories, datasets, storages, agent_settings, enrollment_codes,
    agents, sessions, login_states, users;
