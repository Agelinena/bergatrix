-- migrate:up

CREATE TABLE external_ids (
    track_id    uuid NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
    provider    text NOT NULL,
    external_id text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (provider, external_id)
);

CREATE INDEX idx_external_ids_track ON external_ids (track_id);

-- migrate:down

DROP TABLE external_ids;