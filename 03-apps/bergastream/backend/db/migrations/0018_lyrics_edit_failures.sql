-- migrate:up

-- Letra editável: atraso/adiantamento (vale para todos que ouvem) e texto
-- corrigido à mão. Letra editada não é trocada pela do LRCLIB.
ALTER TABLE lyrics
    ADD COLUMN offset_ms integer NOT NULL DEFAULT 0,
    ADD COLUMN edited_by uuid REFERENCES users(id) ON DELETE SET NULL,
    ADD COLUMN edited_at timestamptz;

-- Músicas que não deu para baixar (Deemix e YouTube falharam). O admin vê,
-- tenta de novo, escolhe a fonte à mão ou ignora. Sai daqui quando a
-- música é baixada.
CREATE TABLE download_failures (
    track_id        uuid        PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,
    provider        text,
    external_id     text,
    error           text,
    attempts        integer     NOT NULL DEFAULT 1,
    first_failed_at timestamptz NOT NULL DEFAULT now(),
    last_failed_at  timestamptz NOT NULL DEFAULT now(),
    ignored_at      timestamptz,
    ignored_by      uuid        REFERENCES users(id) ON DELETE SET NULL
);
CREATE INDEX download_failures_open ON download_failures (last_failed_at DESC)
    WHERE ignored_at IS NULL;

-- migrate:down

DROP TABLE download_failures;
ALTER TABLE lyrics DROP COLUMN edited_at, DROP COLUMN edited_by, DROP COLUMN offset_ms;
