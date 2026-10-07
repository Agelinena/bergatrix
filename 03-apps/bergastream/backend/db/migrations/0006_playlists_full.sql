-- migrate:up

-- Playlists completas (Passo 8 do app): foto, datas, quem adicionou cada
-- faixa, ordem e colaboradores com papel (vê / edita).
ALTER TABLE playlists
    ADD COLUMN description text        NOT NULL DEFAULT '',
    ADD COLUMN cover_path  text,
    ADD COLUMN created_at  timestamptz NOT NULL DEFAULT now(),
    ADD COLUMN updated_at  timestamptz NOT NULL DEFAULT now();

ALTER TABLE playlist_tracks
    ADD COLUMN added_by uuid REFERENCES users(id) ON DELETE SET NULL,
    ADD COLUMN position integer NOT NULL DEFAULT 0;

-- Dados existentes: ordem pela data de adição; quem adicionou = dono.
UPDATE playlist_tracks pt
SET position = sub.rn
FROM (
    SELECT playlist_id, track_id,
           row_number() OVER (PARTITION BY playlist_id ORDER BY added_at) AS rn
    FROM playlist_tracks
) sub
WHERE pt.playlist_id = sub.playlist_id AND pt.track_id = sub.track_id;

UPDATE playlist_tracks pt
SET added_by = p.user_id
FROM playlists p
WHERE p.id = pt.playlist_id;

CREATE INDEX idx_playlist_tracks_order ON playlist_tracks (playlist_id, position);

CREATE TABLE playlist_members (
    playlist_id uuid NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
    user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role        text NOT NULL CHECK (role IN ('viewer', 'editor')),
    added_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (playlist_id, user_id)
);

CREATE INDEX idx_playlist_members_user ON playlist_members (user_id);

-- migrate:down

DROP TABLE playlist_members;
DROP INDEX idx_playlist_tracks_order;
ALTER TABLE playlist_tracks DROP COLUMN position, DROP COLUMN added_by;
ALTER TABLE playlists
    DROP COLUMN updated_at,
    DROP COLUMN created_at,
    DROP COLUMN cover_path,
    DROP COLUMN description;
