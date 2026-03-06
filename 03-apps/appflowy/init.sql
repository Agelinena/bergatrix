-- Enable uuid-ossp for uuid_generate_v4()
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Enable vector for pgvector
CREATE EXTENSION IF NOT EXISTS "vector";

-- Create the auth schema required by GoTrue migrations
-- GoTrue will create all tables inside this schema on first run
CREATE SCHEMA IF NOT EXISTS auth;