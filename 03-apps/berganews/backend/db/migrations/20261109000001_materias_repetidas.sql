-- migrate:up

-- A mesma matéria (mesmo endereço) publicada por vários feeds aparece uma vez
-- só, creditada a todos eles. Nas histórias: matérias = endereços distintos;
-- veículos = todos os feeds que publicaram (g1 Economia e g1 Política são
-- dois veículos, mesmo publicando a mesma matéria). Recalcula as que já existem.
UPDATE stories s SET article_count = x.n, source_count = x.sources
FROM (SELECT sa.story_id, count(DISTINCT a.url) AS n, count(DISTINCT a.feed_id) AS sources
      FROM story_articles sa JOIN articles a ON a.id = sa.article_id
      GROUP BY sa.story_id) x
WHERE x.story_id = s.id;

-- Lido vale para todas as cópias da mesma matéria: quem já leu uma, leu as
-- outras.
INSERT INTO article_states (user_id, article_id, read_at)
SELECT DISTINCT ON (st.user_id, b.id) st.user_id, b.id, st.read_at
FROM article_states st
JOIN articles a ON a.id = st.article_id
JOIN articles b ON b.url = a.url AND b.id <> a.id
WHERE st.read_at IS NOT NULL
ORDER BY st.user_id, b.id, st.read_at
ON CONFLICT (user_id, article_id) DO UPDATE
    SET read_at = coalesce(article_states.read_at, EXCLUDED.read_at);

-- migrate:down

SELECT 1;
