-- migrate:up

CREATE TABLE users (
    id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name  text NOT NULL UNIQUE
);

CREATE TABLE playlists (
    id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id  uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name     text NOT NULL
);

CREATE TABLE playlist_tracks (
    playlist_id uuid NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
    track_id    uuid NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
    added_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (playlist_id, track_id)
);

CREATE INDEX idx_playlists_user ON playlists (user_id);
CREATE INDEX idx_playlist_tracks_track ON playlist_tracks (track_id);

-- Seed: 2 usuarios dummy + playlists
INSERT INTO users (name) VALUES ('User A'), ('User B');

INSERT INTO playlists (user_id, name)
SELECT u.id, 'Favoritas'
FROM users u
WHERE u.name IN ('User A', 'User B');

-- migrate:down

DROP TABLE playlist_tracks;
DROP TABLE playlists;
DROP TABLE users;