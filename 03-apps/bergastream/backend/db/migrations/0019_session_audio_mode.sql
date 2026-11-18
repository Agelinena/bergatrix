-- migrate:up

-- Onde a sessão toca: 'all' = em todos os aparelhos (cada um ouve);
-- 'owner' = só no aparelho de quem criou (os outros só controlam: fila,
-- pular, pausar, adicionar).
ALTER TABLE listen_sessions
    ADD COLUMN audio_mode text NOT NULL DEFAULT 'all' CHECK (audio_mode IN ('all', 'owner'));

-- migrate:down

ALTER TABLE listen_sessions DROP COLUMN audio_mode;
