# n8n VPS Stack

Production-oriented Docker template for running n8n, PostgreSQL, MinIO, Dozzle, and Traefik with automatic Let's Encrypt certificates.

## Phase 1: Architecture & Network Design

### Analysis & Reasoning

Traefik is used as the reverse proxy because it discovers Docker services through labels, requests Let's Encrypt certificates automatically, and removes the need to maintain separate proxy configuration files for each service. This fits a VPS template where services may be added later.

The stack uses two Docker networks:

- `web`: public reverse-proxy network. Traefik joins this network and routes HTTPS traffic to services that explicitly opt in with labels.
- `n8n_internal`: private application network. PostgreSQL is only on this network. n8n and MinIO also join it for internal service communication.

Only Traefik exposes host ports `80` and `443`. PostgreSQL, n8n, MinIO, and Dozzle do not publish host ports. Public access flows through Traefik only.

Request flow:

```text
Internet
  -> VPS ports 80/443
  -> Traefik on public Docker network
  -> n8n / MinIO API / MinIO Console / Dozzle container ports
  -> PostgreSQL over private internal Docker network where needed
```

Expected repository tree:

```text
.
├── .env.example
├── docker-compose.yml
├── deploy.sh
├── postgres
│   └── init
│       └── 01-create-n8n-db.sh
└── README.md
```

## Phase 2: Environment Configuration

### Analysis & Reasoning

The `.env` file contains all deployment-specific values: DNS hostnames, Let's Encrypt email, database credentials, n8n encryption key, MinIO credentials, and Dozzle login credentials. Secrets are intentionally kept out of `docker-compose.yml` so the compose file can be committed while `.env` remains private.

Copy the example and edit it:

```bash
cp .env.example .env
nano .env
```

Generate strong secret values:

```bash
openssl rand -hex 32
```

Use the `openssl` output for `N8N_ENCRYPTION_KEY`. Set `DOZZLE_USERNAME` and `DOZZLE_PASSWORD` directly in `.env`; `deploy.sh` reads those plain text values and automatically generates the encrypted `users.yml` file used by Dozzle.

## Phase 3: Docker Compose Infrastructure

### Analysis & Reasoning

All persistent state is stored in named Docker volumes:

- `traefik_letsencrypt`: ACME certificates.
- `postgres_data`: PostgreSQL database files.
- `n8n_data`: n8n local data and metadata.
- `minio_data`: MinIO object storage.

Every service uses `restart: unless-stopped`, which is appropriate for VPS workloads managed by Docker. Health checks are included for PostgreSQL, n8n, MinIO, Dozzle, and Traefik so operators can inspect readiness with `docker compose ps`.

Service discovery uses Docker DNS names. n8n connects to PostgreSQL at `postgres:5432`, and workflows running in n8n can use the same internal host when connecting to PostgreSQL.

Compose file:

```bash
docker compose --env-file .env config
```

## Phase 4: Automated Deployment

### Analysis & Reasoning

`deploy.sh` starts by verifying `.env`, then creates the external Docker networks required by Compose. Traefik starts first so it can bind ports `80` and `443`, initialize routing, and answer Let's Encrypt HTTP challenges. The rest of the services start afterward.

Before containers are started, `deploy.sh` also reads `DOZZLE_USERNAME` and `DOZZLE_PASSWORD` from `.env` and runs a temporary Dozzle container to generate the encrypted `users.yml` authentication file.

The deployment script then polls `https://$DOMAIN_N8N/healthz` until it receives `200`, `302`, or `401`. These statuses prove the domain reaches the n8n route through the reverse proxy.

Run:

```bash
chmod +x deploy.sh
./deploy.sh
```

## Phase 5: Operations Documentation

### Prerequisites

Use a Linux VPS with:

- Ubuntu 22.04 LTS, Ubuntu 24.04 LTS, Debian 12, or another Docker-supported Linux distribution.
- Docker Engine and Docker Compose v2.
- Open inbound firewall ports `80/tcp` and `443/tcp`.
- DNS A records pointing to the VPS public IP:
  - `DOMAIN_N8N`
  - `DOMAIN_MINIO_CONSOLE`
  - `DOMAIN_MINIO_API`
  - `DOMAIN_DOZZLE`

Install Docker on Ubuntu:

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"
```

Log out and back in after adding your user to the `docker` group.

### Deployment Guide

1. Clone or copy this repository to the VPS.
2. Create `.env`:

   ```bash
   cp .env.example .env
   nano .env
   ```

3. Fill in real domains and secrets.
4. Confirm DNS records resolve to the VPS:

   ```bash
   dig +short n8n.example.com
   dig +short s3.example.com
   ```

5. Deploy:

   ```bash
   chmod +x deploy.sh
   ./deploy.sh
   ```

6. Inspect status:

   ```bash
   docker compose --env-file .env ps
   docker compose --env-file .env logs -f traefik n8n
   ```

### Component Access Guide

Access services through HTTPS only:

- n8n: `https://$DOMAIN_N8N`
- MinIO Console: `https://$DOMAIN_MINIO_CONSOLE`
- MinIO S3 API: `https://$DOMAIN_MINIO_API`
- Dozzle: `https://$DOMAIN_DOZZLE`

n8n creates its first owner account through the web UI on first access. MinIO uses `MINIO_ROOT_USER` and `MINIO_ROOT_PASSWORD`. Dozzle uses its native login page with `DOZZLE_USERNAME` and `DOZZLE_PASSWORD` from `.env`.

### Shared Database Usage

PostgreSQL is intentionally not exposed to the host or public internet. Containers on the internal Docker network can connect with:

- Host: `postgres`
- Port: `5432`
- Admin database: value of `POSTGRES_DEFAULT_DB`
- n8n database: value of `N8N_DB_NAME`

n8n itself uses the least-privilege role:

```text
database: $N8N_DB_NAME
user:     $N8N_DB_USER
password: $N8N_DB_PASSWORD
host:     postgres
port:     5432
```

For n8n workflows that need to create or manage additional databases, create a PostgreSQL credential in n8n using:

```text
database: $POSTGRES_DEFAULT_DB
user:     $POSTGRES_ADMIN_USER
password: $POSTGRES_ADMIN_PASSWORD
host:     postgres
port:     5432
ssl:      disabled for internal Docker network traffic
```

Example SQL to create a workflow-specific database:

```sql
CREATE DATABASE workflow_app;
CREATE USER workflow_app_user WITH PASSWORD 'replace-with-strong-password';
GRANT ALL PRIVILEGES ON DATABASE workflow_app TO workflow_app_user;
```

Prefer creating separate users per workflow or application. Do not reuse the n8n application user for unrelated databases.

### Backup Procedures

#### Automated Local Backups

### Analysis & Reasoning

This stack uses `offen/docker-volume-backup:v2` for scheduled local backups. Because this VPS has limited disk space and no external object storage, backups are written to `./backups` and the filename is fixed as `n8n-stack-latest.tar.gz`. Each new backup overwrites the previous archive, and `BACKUP_RETENTION_DAYS=0` keeps pruning strict.

PostgreSQL is not backed up by copying raw database files. Raw PostgreSQL volume snapshots can be inconsistent while the database is running. Instead, the backup service uses Docker labels to run a pre-archive command inside the `postgres` container:

```bash
pg_dumpall -U "$POSTGRES_USER" > /backup/postgres/pg_dumpall.sql
```

That logical dump is written to a temporary Docker volume, included in the archive, and removed immediately by the post-archive hook to save disk space.

The generated archive contains:

- `postgres_dump/pg_dumpall.sql`
- `n8n_data/`
- `minio_data/`
- `traefik_letsencrypt/`

Create the local backup directory if it does not already exist:

```bash
mkdir -p backups
```

Trigger a backup manually right now:

```bash
docker compose --env-file .env exec backup backup
```

Confirm only the latest archive exists:

```bash
ls -lh backups
```

Disable automated backups if the VPS runs out of space:

```bash
docker compose --env-file .env stop backup
docker compose --env-file .env rm -f backup
```

Delete existing local backup archives:

```bash
rm -f backups/*.tar.gz
```

Restore from `backups/n8n-stack-latest.tar.gz`:

```bash
mkdir -p restore/latest
tar -xzf backups/n8n-stack-latest.tar.gz -C restore/latest
```

Stop services that use the target volumes:

```bash
docker compose --env-file .env stop n8n minio traefik postgres backup
```

Restore n8n, MinIO, and Traefik files into their Docker volumes:

```bash
docker run --rm \
  -v n8n_staf_n8n_data:/target \
  -v "$PWD/restore/latest/backup/n8n_data:/source:ro" \
  alpine sh -c 'rm -rf /target/* /target/.[!.]* /target/..?* 2>/dev/null || true; cp -a /source/. /target/'

docker run --rm \
  -v n8n_staf_minio_data:/target \
  -v "$PWD/restore/latest/backup/minio_data:/source:ro" \
  alpine sh -c 'rm -rf /target/* /target/.[!.]* /target/..?* 2>/dev/null || true; cp -a /source/. /target/'

docker run --rm \
  -v n8n_staf_traefik_letsencrypt:/target \
  -v "$PWD/restore/latest/backup/traefik_letsencrypt:/source:ro" \
  alpine sh -c 'rm -rf /target/* /target/.[!.]* /target/..?* 2>/dev/null || true; cp -a /source/. /target/'
```

Restore PostgreSQL from the logical dump:

```bash
docker compose --env-file .env up -d postgres
docker compose --env-file .env exec -T postgres psql -U postgres_admin -d postgres < restore/latest/backup/postgres_dump/pg_dumpall.sql
```

Start the full stack again:

```bash
docker compose --env-file .env up -d
```

Also back up `.env` securely. Without `N8N_ENCRYPTION_KEY`, existing n8n credentials cannot be decrypted.

### Restore Strategy

1. Provision a new VPS.
2. Install Docker and Docker Compose.
3. Restore this repository and the private `.env`.
4. Restore PostgreSQL and MinIO backups.
5. Run `./deploy.sh`.
6. Confirm service health and log in to n8n and MinIO.

### Security Notes

Implemented controls:

- Only ports `80` and `443` are published on the host.
- PostgreSQL has no public route and is reachable only on the internal Docker network.
- n8n, MinIO, and Dozzle are routed through Traefik with automatic TLS.
- Dozzle is protected by its native simple authentication backed by an auto-generated, encrypted `users.yml` file.
- The Docker socket is mounted read-only where required.
- Secrets are kept in `.env`, not committed into Compose.

Recommended hardening:

- Enable a host firewall such as `ufw` and allow only SSH, HTTP, and HTTPS.
- Disable root SSH login and use key-based SSH.
- Keep Docker images updated on a planned maintenance schedule.
- Store backups off-server and test restores regularly.
- Rotate MinIO, PostgreSQL, and Dozzle credentials when operators change.

### Maintenance Commands

Update images:

```bash
docker compose --env-file .env pull
docker compose --env-file .env up -d
```

View logs:

```bash
docker compose --env-file .env logs -f n8n
docker compose --env-file .env logs -f traefik
```

Restart one service:

```bash
docker compose --env-file .env restart n8n
```

List containers and health:

```bash
docker compose --env-file .env ps
```

Trigger local backup now:

```bash
docker compose --env-file .env exec backup backup
```

Check local backup disk usage:

```bash
du -sh backups
ls -lh backups
```

Disable backups and remove local archives during a disk-space emergency:

```bash
docker compose --env-file .env stop backup
docker compose --env-file .env rm -f backup
rm -f backups/*.tar.gz
```
