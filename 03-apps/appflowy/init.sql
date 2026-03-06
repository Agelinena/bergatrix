-- Enable extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "vector";

-- Schema auth para o GoTrue
CREATE SCHEMA IF NOT EXISTS auth;

-- Os 3 tipos que a migration add_mfa_schema falha em criar atomicamente
CREATE TYPE auth.factor_type AS ENUM ('totp', 'webauthn');
CREATE TYPE auth.factor_status AS ENUM ('unverified', 'verified');
CREATE TYPE auth.aal_level AS ENUM ('aal1', 'aal2', 'aal3');
