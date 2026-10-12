-- migrate:up

-- Quando o álbum foi pedido ao Lidarr: define a fase de busca diária
-- (UPGRADE_DAILY_DAYS) e quantos álbuns estão nela (LIDARR_MAX_ACTIVE).
ALTER TABLE quality_upgrades ADD COLUMN lidarr_requested_at timestamptz;

-- Pedidos já feitos: estimativa (uma busca por dia desde o pedido).
UPDATE quality_upgrades
SET lidarr_requested_at = coalesce(lidarr_searched_at, updated_at)
                          - make_interval(days => greatest(searches - 1, 0))
WHERE lidarr_foreign_album_id IS NOT NULL;

-- Encerradas como "baixou o álbum, mas sem esta faixa" pela comparação antiga
-- (duração até 5 s; medleys "A / B"): pedem o álbum de novo.
UPDATE quality_upgrades
SET status = 'pending', lidarr_artist_id = NULL, lidarr_album_id = NULL,
    lidarr_foreign_album_id = NULL, lidarr_requested_at = NULL,
    lidarr_searched_at = NULL, searches = 0, last_error = NULL, next_attempt_at = now()
WHERE status = 'done' AND last_error LIKE 'o Lidarr baixou o álbum%';

-- Álbum fora do perfil de metadados (coletâneas): tenta de novo pelo álbum
-- de estúdio (ISRC → MusicBrainz).
UPDATE quality_upgrades
SET status = 'pending', lidarr_album_id = NULL, lidarr_foreign_album_id = NULL,
    lidarr_requested_at = NULL, next_attempt_at = now()
WHERE status = 'waiting' AND last_error LIKE 'álbum fora do perfil%';

-- Já passaram pelo Deemix e ficaram para depois (Lidarr desligado na época,
-- ou álbum não achado pelo nome): entram na fila do Lidarr.
UPDATE quality_upgrades
SET next_attempt_at = now()
WHERE status = 'pending' AND lidarr_foreign_album_id IS NULL
  AND deemix_checked_at IS NOT NULL AND next_attempt_at > now();

-- migrate:down

ALTER TABLE quality_upgrades DROP COLUMN lidarr_requested_at;
