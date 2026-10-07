-- migrate:up

CREATE TABLE tracks (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    title             text NOT NULL,
    artist            text NOT NULL,
    album             text,
    duration_seconds  integer NOT NULL,
    isrc              text UNIQUE,
    cover_url         text,
    created_at        timestamptz NOT NULL DEFAULT now()
);

-- migrate:down

DROP TABLE tracks;