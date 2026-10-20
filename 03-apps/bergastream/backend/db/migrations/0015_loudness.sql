-- migrate:up

-- Volume percebido do arquivo (EBU R128, medido com o loudnorm do ffmpeg):
-- o app abaixa as músicas mais altas para todas soarem parecidas. Nulo =
-- ainda não medido (o worker mede aos poucos).
ALTER TABLE files
    ADD COLUMN loudness_lufs real,
    ADD COLUMN true_peak_db  real;

-- migrate:down

ALTER TABLE files DROP COLUMN loudness_lufs, DROP COLUMN true_peak_db;
