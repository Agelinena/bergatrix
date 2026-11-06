-- migrate:up

-- Fase 2: embeddings e histórias. Uma história é a mesma notícia em vários
-- veículos. Todo artigo com embedding fica em exatamente uma história (a
-- maioria sozinha); a aba "IA" mostra as que têm 2 veículos ou mais.

CREATE EXTENSION IF NOT EXISTS vector;

-- bge-m3 (multilíngue): 1024 dimensões. Outro modelo precisa ter as mesmas.
CREATE TABLE article_embeddings (
    article_id  bigint PRIMARY KEY REFERENCES articles(id) ON DELETE CASCADE,
    embedding   vector(1024) NOT NULL,
    -- Nomes próprios e siglas da manchete e do começo do texto (checagem de
    -- entidade: segura o grupo que "cresce" juntando assuntos parecidos).
    entities    text[]      NOT NULL DEFAULT '{}',
    model       text        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);
-- Sem índice HNSW: o agrupamento compara só com os artigos-base da janela de
-- tempo (busca exata, poucos milhares de vetores).

CREATE TABLE stories (
    id                  bigserial PRIMARY KEY,
    title               text        NOT NULL,
    first_published_at  timestamptz NOT NULL,
    last_published_at   timestamptz NOT NULL,
    article_count       integer     NOT NULL DEFAULT 0,
    source_count        integer     NOT NULL DEFAULT 0,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_stories_last ON stories (last_published_at DESC, id DESC);
CREATE INDEX idx_stories_multi ON stories (last_published_at DESC, id DESC) WHERE source_count >= 2;

-- seed: os artigos que definem a história. Um artigo novo é comparado com
-- eles, e não com um centróide que se arrasta (é o que evita o efeito
-- corrente). added_by = manual: posto ali por uma pessoa; o agrupamento
-- automático nunca mexe nele.
CREATE TABLE story_articles (
    article_id  bigint PRIMARY KEY REFERENCES articles(id) ON DELETE CASCADE,
    story_id    bigint      NOT NULL REFERENCES stories(id) ON DELETE CASCADE,
    similarity  real,
    is_seed     boolean     NOT NULL DEFAULT false,
    added_by    text        NOT NULL DEFAULT 'auto' CHECK (added_by IN ('auto', 'manual')),
    added_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_story_articles_story ON story_articles (story_id);

-- Exemplos rotulados (mesma notícia ou não): vêm de juntar e separar
-- histórias e da tela de calibração. Servem para escolher o limite.
CREATE TABLE story_pairs (
    article_a   bigint      NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
    article_b   bigint      NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
    same        boolean     NOT NULL,
    source      text        NOT NULL CHECK (source IN ('merge', 'split', 'label')),
    user_id     uuid        REFERENCES users(id) ON DELETE SET NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (article_a, article_b),
    CHECK (article_a < article_b)
);

-- migrate:down

DROP TABLE story_pairs;
DROP TABLE story_articles;
DROP TABLE stories;
DROP TABLE article_embeddings;
