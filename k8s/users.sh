#!/bin/sh
# Least-privilege PostgreSQL users for Result and the worker (ADR 0023).
# Runs once from /docker-entrypoint-initdb.d on an empty database (after schema.sql: the image
# runs the files by name), and again on every scripts/deploy.sh run, so an existing database
# gets the users and a password changed in secrets.env is applied. Idempotent.
# psql reads the passwords from the environment (\getenv): they never appear on a command line.
psql -v ON_ERROR_STOP=1 --no-psqlrc --quiet --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'SQL'
\getenv result_password RESULT_DB_PASSWORD
\getenv worker_password WORKER_DB_PASSWORD
SELECT 'CREATE ROLE result_reader LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'result_reader')
\gexec
SELECT 'CREATE ROLE worker_writer LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'worker_writer')
\gexec
ALTER ROLE result_reader WITH LOGIN PASSWORD :'result_password';
ALTER ROLE worker_writer WITH LOGIN PASSWORD :'worker_password';
-- Result only counts the votes.
GRANT SELECT ON votes TO result_reader;
-- The worker upserts. INSERT ... ON CONFLICT (id) DO UPDATE also needs SELECT on the columns it reads.
GRANT SELECT, INSERT, UPDATE ON votes TO worker_writer;
SQL
