-- Enable pgcrypto for gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Create the auth schema required by AppFlowy/GoTrue migrations
CREATE SCHEMA IF NOT EXISTS auth;

-- Create stub users table to satisfy AppFlowy migrations
CREATE TABLE IF NOT EXISTS auth.users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email text UNIQUE
);
