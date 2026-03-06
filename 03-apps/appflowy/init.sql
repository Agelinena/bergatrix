-- Enable extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "vector";

-- Cria o schema auth para o GoTrue
-- O GoTrue cria o schema mas não commita antes de usá-lo no latest
CREATE SCHEMA IF NOT EXISTS auth;