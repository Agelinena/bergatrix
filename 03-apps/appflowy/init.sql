-- Enable uuid-ossp for uuid_generate_v4()
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Enable vector for pgvector
CREATE EXTENSION IF NOT EXISTS "vector";

-- Create the auth schema required by AppFlowy/GoTrue migrations
CREATE SCHEMA IF NOT EXISTS auth;

-- Create stub users table to satisfy AppFlowy migrations
CREATE TABLE IF NOT EXISTS auth.users (
    id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
    email text UNIQUE
);
