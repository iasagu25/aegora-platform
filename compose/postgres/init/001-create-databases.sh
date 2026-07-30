#!/usr/bin/env bash

set -Eeuo pipefail

required_variables=(
  DIRECTUS_DB_USER
  DIRECTUS_DB_PASSWORD
  DIRECTUS_DB_NAME
  N8N_DB_USER
  N8N_DB_PASSWORD
  N8N_DB_NAME
  BOOKING_DB_USER
  BOOKING_DB_PASSWORD
  BOOKING_DB_NAME
)

for variable in "${required_variables[@]}"; do
  if [[ -z "${!variable:-}" ]]; then
    echo "ERROR: required environment variable ${variable} is missing"
    exit 1
  fi
done

create_role_and_database() {
  local db_user="$1"
  local db_password="$2"
  local db_name="$3"

  echo "Creating PostgreSQL role: ${db_user}"

  psql \
    --username "$POSTGRES_USER" \
    --dbname postgres \
    --set=ON_ERROR_STOP=1 \
    --set=db_user="$db_user" \
    --set=db_password="$db_password" \
    --set=db_name="$db_name" <<'EOSQL'
SELECT format(
  'CREATE ROLE %I LOGIN PASSWORD %L',
  :'db_user',
  :'db_password'
)
WHERE NOT EXISTS (
  SELECT 1
  FROM pg_catalog.pg_roles
  WHERE rolname = :'db_user'
)\gexec

SELECT format(
  'CREATE DATABASE %I OWNER %I ENCODING ''UTF8'' TEMPLATE template0',
  :'db_name',
  :'db_user'
)
WHERE NOT EXISTS (
  SELECT 1
  FROM pg_catalog.pg_database
  WHERE datname = :'db_name'
)\gexec
EOSQL

  psql \
    --username "$POSTGRES_USER" \
    --dbname "$db_name" \
    --set=ON_ERROR_STOP=1 \
    --set=db_user="$db_user" <<'EOSQL'
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

SELECT format(
  'GRANT ALL ON SCHEMA public TO %I',
  :'db_user'
)\gexec
EOSQL
}

create_role_and_database \
  "$DIRECTUS_DB_USER" \
  "$DIRECTUS_DB_PASSWORD" \
  "$DIRECTUS_DB_NAME"

create_role_and_database \
  "$N8N_DB_USER" \
  "$N8N_DB_PASSWORD" \
  "$N8N_DB_NAME"

create_role_and_database \
  "$BOOKING_DB_USER" \
  "$BOOKING_DB_PASSWORD" \
  "$BOOKING_DB_NAME"

echo "PostgreSQL application databases created successfully."
