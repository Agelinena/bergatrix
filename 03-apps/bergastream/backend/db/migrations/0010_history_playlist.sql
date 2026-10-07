-- migrate:up

-- De qual playlist veio cada reprodução: a Biblioteca ordena as playlists
-- pela última vez que foram tocadas.
ALTER TABLE play_history
    ADD COLUMN playlist_id uuid REFERENCES playlists(id) ON DELETE SET NULL;

CREATE INDEX idx_play_history_playlist ON play_history (user_id, playlist_id, played_at DESC)
    WHERE playlist_id IS NOT NULL;

-- migrate:down

DROP INDEX idx_play_history_playlist;
ALTER TABLE play_history DROP COLUMN playlist_id;
