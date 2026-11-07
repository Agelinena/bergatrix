-- migrate:up

-- Versão da extração que produziu o texto guardado. Quando a extração
-- melhora (fotos, vídeos, parágrafos), o worker refaz em segundo plano as
-- matérias de versões antigas, sem piorar as que já estão boas.
ALTER TABLE articles ADD COLUMN extract_version smallint NOT NULL DEFAULT 0;
CREATE INDEX idx_articles_extract_version ON articles (extract_version, published_at DESC);

-- migrate:down

DROP INDEX idx_articles_extract_version;
ALTER TABLE articles DROP COLUMN extract_version;
