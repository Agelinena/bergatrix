-- migrate:up

-- Remove os usuários fictícios da migração 0004 ("User A"/"User B"). Eles
-- nunca tiveram senha e só apareciam na lista de pessoas para compartilhar.
-- Só sai quem continua sem senha e sem nenhuma música em playlist.
DELETE FROM users u
WHERE u.username IN ('usera', 'userb')
  AND u.password_hash IS NULL
  AND NOT EXISTS (
      SELECT 1 FROM playlist_tracks pt
      JOIN playlists p ON p.id = pt.playlist_id
      WHERE p.user_id = u.id);

-- migrate:down

-- Nada a desfazer (dados fictícios).
SELECT 1;
