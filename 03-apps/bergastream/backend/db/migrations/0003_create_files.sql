-- migrate:up

CREATE TABLE files (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    track_id       uuid NOT NULL UNIQUE REFERENCES tracks(id) ON DELETE CASCADE,
    path           text NOT NULL,
    size_bytes     bigint,
    format         text NOT NULL,
    kind           text NOT NULL DEFAULT 'cache',
    last_played_at timestamptz,
    created_at     timestamptz NOT NULL DEFAULT now()
);

-- migrate:down

DROP TABLE files;