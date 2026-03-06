-- Enable uuid-ossp for uuid_generate_v4()
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Enable vector for pgvector
CREATE EXTENSION IF NOT EXISTS "vector";

-- NÃO criar schema auth aqui — o GoTrue gerencia isso completamente