-- migrate:up

-- Fase 1: leitor. Feeds e artigos são da casa (coletados uma vez só, mesmo
-- que várias pessoas assinem); assinatura, pastas, lido/salvo e preferências
-- são de cada pessoa. Embeddings e histórias entram em migrações da fase 2.

CREATE EXTENSION IF NOT EXISTS unaccent;

-- unaccent() não é IMMUTABLE (depende do dicionário); a coluna gerada de
-- busca precisa de uma função que seja.
CREATE FUNCTION f_unaccent(text) RETURNS text
    LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT
    AS $$ SELECT public.unaccent('public.unaccent'::regdictionary, $1) $$;

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

-- Só o hash SHA-256. Cada uso gera um token novo na mesma família; um token
-- já trocado que reaparece revoga a família inteira (sinal de roubo).
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

-- Abas, ordem, idioma, tema: um JSON por pessoa, validado pela API.
CREATE TABLE user_prefs (
    user_id     uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    prefs       jsonb       NOT NULL DEFAULT '{}'::jsonb,
    updated_at  timestamptz NOT NULL DEFAULT now()
);

-- ── Feeds ───────────────────────────────────────────────────────────
CREATE TABLE feeds (
    id               bigserial PRIMARY KEY,
    url              text        NOT NULL UNIQUE,
    title            text        NOT NULL DEFAULT '',
    site_url         text,
    description      text,
    language         text,               -- <language> do feed (pt-br, en…)
    etag             text,
    last_modified    text,
    last_fetched_at  timestamptz,
    last_status      integer,
    last_error       text,
    error_count      integer     NOT NULL DEFAULT 0,
    next_fetch_at    timestamptz NOT NULL DEFAULT now(),
    created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_feeds_next_fetch ON feeds (next_fetch_at);

CREATE TABLE folders (
    id          bigserial PRIMARY KEY,
    user_id     uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name        text        NOT NULL,
    position    integer     NOT NULL DEFAULT 0,
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX folders_user_name ON folders (user_id, lower(name));

CREATE TABLE subscriptions (
    user_id     uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    feed_id     bigint      NOT NULL REFERENCES feeds(id) ON DELETE CASCADE,
    folder_id   bigint      REFERENCES folders(id) ON DELETE SET NULL,
    title       text,                    -- nome que a pessoa deu (vazio = o do feed)
    created_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, feed_id)
);
CREATE INDEX idx_subscriptions_feed ON subscriptions (feed_id);

-- ── Artigos ─────────────────────────────────────────────────────────
-- content_status: NULL = ainda não processado; ok = texto completo;
-- short = só manchete e trecho (paywall ou extração ruim: o app leva ao
-- site); error = falhou (content_error).
CREATE TABLE articles (
    id              bigserial PRIMARY KEY,
    feed_id         bigint      NOT NULL REFERENCES feeds(id) ON DELETE CASCADE,
    guid            text        NOT NULL,
    url             text        NOT NULL,
    title           text        NOT NULL,
    author          text,
    summary         text,                -- trecho do RSS, em texto
    image_url       text,
    language        text,                -- pt, en, es… (detectado)
    published_at    timestamptz NOT NULL,
    fetched_at      timestamptz NOT NULL DEFAULT now(),
    content_html    text,                -- já limpo (sem script, estilo, anúncio)
    content_text    text,
    content_status  text CHECK (content_status IN ('ok', 'short', 'error')),
    content_error   text,
    extracted_at    timestamptz,
    search          tsvector GENERATED ALWAYS AS (
        setweight(to_tsvector(CASE WHEN language = 'en' THEN 'english'::regconfig
                                   ELSE 'portuguese'::regconfig END,
                              f_unaccent(coalesce(title, ''))), 'A') ||
        setweight(to_tsvector(CASE WHEN language = 'en' THEN 'english'::regconfig
                                   ELSE 'portuguese'::regconfig END,
                              f_unaccent(coalesce(summary, ''))), 'B') ||
        setweight(to_tsvector(CASE WHEN language = 'en' THEN 'english'::regconfig
                                   ELSE 'portuguese'::regconfig END,
                              f_unaccent(left(coalesce(content_text, ''), 100000))), 'C')
    ) STORED,
    UNIQUE (feed_id, guid)
);
CREATE INDEX idx_articles_feed_published ON articles (feed_id, published_at DESC, id DESC);
CREATE INDEX idx_articles_published ON articles (published_at DESC, id DESC);
CREATE INDEX idx_articles_pending ON articles (fetched_at) WHERE content_status IS NULL;
CREATE INDEX idx_articles_url ON articles (url);
CREATE INDEX idx_articles_search ON articles USING gin (search);

-- Lido e salvo, por pessoa. Sem linha = não lido e não salvo.
CREATE TABLE article_states (
    user_id     uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    article_id  bigint      NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
    read_at     timestamptz,
    saved_at    timestamptz,
    PRIMARY KEY (user_id, article_id)
);
CREATE INDEX idx_article_states_saved ON article_states (user_id, saved_at DESC)
    WHERE saved_at IS NOT NULL;

-- Traduções sob demanda (botão no leitor), feitas pelo modelo local. Uma
-- por artigo e idioma: a segunda pessoa que pede já recebe pronta.
CREATE TABLE article_translations (
    article_id  bigint      NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
    lang        text        NOT NULL,
    title       text        NOT NULL,
    html        text        NOT NULL,
    model       text        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (article_id, lang)
);

-- migrate:down

DROP TABLE article_translations;
DROP TABLE article_states;
DROP TABLE articles;
DROP TABLE subscriptions;
DROP TABLE folders;
DROP TABLE feeds;
DROP TABLE user_prefs;
DROP TABLE refresh_tokens;
DROP TABLE users;
DROP FUNCTION f_unaccent(text);
