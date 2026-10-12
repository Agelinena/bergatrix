-- migrate:up

-- Qualidade real do arquivo (lida com ffprobe). quality_rank: 10 baixa
-- (MP3 128), 20 média (MP3 192 / Opus do YouTube), 30 alta (MP3 320),
-- 40 sem perda (FLAC 16 bits), 50 hi-res (FLAC 24 bits); 0 = ainda não medido.
ALTER TABLE files
    ADD COLUMN codec        text,
    ADD COLUMN bitrate_kbps integer,
    ADD COLUMN sample_rate  integer,
    ADD COLUMN bit_depth    integer,
    ADD COLUMN quality_rank smallint NOT NULL DEFAULT 0,
    ADD COLUMN source       text;  -- deemix | youtube | lidarr

-- Faixas de playlist buscam qualidade melhor com o tempo: Deemix (MP3 320 do
-- Premium, ou FLAC se a conta tiver) e FLAC pela Usenet (Lidarr). Faixa que
-- sai de todas as playlists sai daqui.
CREATE TABLE quality_upgrades (
    track_id            uuid PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,
    -- pending: falta tentar algo | waiting: aguardando o Lidarr achar na
    -- Usenet | done: atingiu a melhor qualidade buscada
    status              text NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending', 'waiting', 'done')),
    deemix_checked_at   timestamptz,
    lidarr_artist_id    integer,
    lidarr_album_id     integer,
    lidarr_foreign_album_id text,  -- MusicBrainz (release group)
    lidarr_searched_at  timestamptz,
    searches            integer NOT NULL DEFAULT 0,
    next_attempt_at     timestamptz NOT NULL DEFAULT now(),
    last_error          text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_quality_upgrades_due ON quality_upgrades (next_attempt_at)
    WHERE status <> 'done';

-- Faixas que já estão em playlists entram na fila de melhoria.
INSERT INTO quality_upgrades (track_id)
SELECT DISTINCT track_id FROM playlist_tracks
ON CONFLICT DO NOTHING;

-- migrate:down

DROP TABLE quality_upgrades;
ALTER TABLE files
    DROP COLUMN codec,
    DROP COLUMN bitrate_kbps,
    DROP COLUMN sample_rate,
    DROP COLUMN bit_depth,
    DROP COLUMN quality_rank,
    DROP COLUMN source;
