#!/usr/bin/env bash
set -euo pipefail

psql \
  --username "$POSTGRES_USER" \
  --dbname "$POSTGRES_DB" \
  --set n8n_db_name="$N8N_DB_NAME" \
  --set n8n_db_user="$N8N_DB_USER" \
  --set n8n_db_password="$N8N_DB_PASSWORD" <<-'EOSQL'
  CREATE USER :"n8n_db_user" WITH PASSWORD :'n8n_db_password';
  CREATE DATABASE :"n8n_db_name" OWNER :"n8n_db_user";
  GRANT ALL PRIVILEGES ON DATABASE :"n8n_db_name" TO :"n8n_db_user";
EOSQL
