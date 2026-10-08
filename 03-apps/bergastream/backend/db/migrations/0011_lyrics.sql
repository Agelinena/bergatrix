-- migrate:up

-- Letras (LRCLIB), uma vez por faixa. "found = false" também fica guardado
-- (não buscar de novo a cada vez que a música toca); tenta outra vez depois
-- de alguns dias.
CREATE TABLE lyrics (
    track_id   uuid PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,
    found      boolean NOT NULL,
    synced     text,      -- LRC ("[mm:ss.xx] linha")
    plain      text,
    source     text NOT NULL DEFAULT 'lrclib',
    fetched_at timestamptz NOT NULL DEFAULT now()
);

-- migrate:down

DROP TABLE lyrics;
