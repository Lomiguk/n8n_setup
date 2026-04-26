# n8n VPS Stack

Production-ready Docker-шаблон для запуска n8n, PostgreSQL, MinIO, Dozzle и Traefik с автоматическими сертификатами Let's Encrypt.

## Фаза 1: Архитектура и сетевой дизайн

### Анализ и обоснование

Traefik используется как reverse proxy, потому что он обнаруживает Docker-сервисы через labels, автоматически запрашивает сертификаты Let's Encrypt и убирает необходимость поддерживать отдельные proxy-конфигурации для каждого сервиса. Это подходит для VPS-шаблона, в который позже могут добавляться новые сервисы.

Стек использует две Docker-сети:

- `web`: публичная сеть reverse proxy. Traefik подключается к этой сети и маршрутизирует HTTPS-трафик к сервисам, которые явно включены через labels.
- `n8n_internal`: приватная сеть приложения. PostgreSQL находится только в этой сети. n8n и MinIO также подключены к ней для внутреннего обмена между сервисами.

На хосте порты `80` и `443` публикует только Traefik. PostgreSQL, n8n, MinIO и Dozzle не публикуют host-порты. Публичный доступ проходит только через Traefik.

Поток запроса:

```text
Internet
  -> VPS ports 80/443
  -> Traefik on public Docker network
  -> n8n / MinIO API / MinIO Console / Dozzle container ports
  -> PostgreSQL over private internal Docker network where needed
```

Ожидаемая структура репозитория:

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

## Фаза 2: Настройка окружения

### Анализ и обоснование

Файл `.env` содержит все значения, специфичные для deployment: DNS-имена, email для Let's Encrypt, учетные данные базы данных, ключ шифрования n8n, учетные данные MinIO и учетные данные входа в Dozzle. Секреты намеренно вынесены из `docker-compose.yml`, чтобы compose-файл можно было коммитить, а `.env` оставался приватным.

Скопируйте пример и отредактируйте его:

```bash
cp .env.example .env
nano .env
```

Сгенерируйте надежные секретные значения:

```bash
openssl rand -hex 32
```

Используйте вывод `openssl` для `N8N_ENCRYPTION_KEY`. Задайте `DOZZLE_USERNAME` и `DOZZLE_PASSWORD` напрямую в `.env`; `deploy.sh` прочитает эти plain text значения и автоматически создаст зашифрованный файл `users.yml`, который использует Dozzle.

## Фаза 3: Docker Compose инфраструктура

### Анализ и обоснование

Все постоянные данные хранятся в именованных Docker volumes:

- `traefik_letsencrypt`: ACME-сертификаты.
- `postgres_data`: файлы базы данных PostgreSQL.
- `n8n_data`: локальные данные и metadata n8n.
- `minio_data`: объектное хранилище MinIO.

Каждый сервис использует `restart: unless-stopped`, что подходит для VPS-нагрузок, управляемых Docker. Health checks включены для PostgreSQL, n8n, MinIO, Dozzle и Traefik, чтобы операторы могли проверять готовность через `docker compose ps`.

Service discovery использует Docker DNS-имена. n8n подключается к PostgreSQL по адресу `postgres:5432`, и workflows, запущенные в n8n, могут использовать тот же внутренний host при подключении к PostgreSQL.

Проверить compose-файл:

```bash
docker compose --env-file .env config
```

## Фаза 4: Автоматический deployment

### Анализ и обоснование

`deploy.sh` сначала проверяет наличие `.env`, затем создает внешние Docker-сети, требуемые Compose. Traefik запускается первым, чтобы занять порты `80` и `443`, инициализировать маршрутизацию и отвечать на Let's Encrypt HTTP challenges. Остальные сервисы запускаются после этого.

Перед запуском контейнеров `deploy.sh` также читает `DOZZLE_USERNAME` и `DOZZLE_PASSWORD` из `.env` и запускает временный контейнер Dozzle, чтобы создать зашифрованный файл аутентификации `users.yml`.

Затем deployment-скрипт опрашивает `https://$DOMAIN_N8N/healthz`, пока не получит `200`, `302` или `401`. Эти статусы подтверждают, что домен доходит до route n8n через reverse proxy.

Запуск:

```bash
chmod +x deploy.sh
./deploy.sh
```

## Фаза 5: Операционная документация

### Предварительные требования

Используйте Linux VPS с:

- Ubuntu 22.04 LTS, Ubuntu 24.04 LTS, Debian 12 или другим Linux-дистрибутивом, поддерживаемым Docker.
- Docker Engine и Docker Compose v2.
- Открытыми входящими firewall-портами `80/tcp` и `443/tcp`.
- DNS A-records, указывающими на публичный IP VPS:
  - `DOMAIN_N8N`
  - `DOMAIN_MINIO_CONSOLE`
  - `DOMAIN_MINIO_API`
  - `DOMAIN_DOZZLE`

Установка Docker на Ubuntu:

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"
```

После добавления пользователя в группу `docker` выйдите из сессии и войдите снова.

### Руководство по deployment

1. Склонируйте или скопируйте этот репозиторий на VPS.
2. Создайте `.env`:

   ```bash
   cp .env.example .env
   nano .env
   ```

3. Укажите реальные домены и секреты.
4. Убедитесь, что DNS records указывают на VPS:

   ```bash
   dig +short n8n.example.com
   dig +short s3.example.com
   ```

5. Выполните deployment:

   ```bash
   chmod +x deploy.sh
   ./deploy.sh
   ```

6. Проверьте статус:

   ```bash
   docker compose --env-file .env ps
   docker compose --env-file .env logs -f traefik n8n
   ```

### Доступ к компонентам

Доступ к сервисам выполняется только через HTTPS:

- n8n: `https://$DOMAIN_N8N`
- MinIO Console: `https://$DOMAIN_MINIO_CONSOLE`
- MinIO S3 API: `https://$DOMAIN_MINIO_API`
- Dozzle: `https://$DOMAIN_DOZZLE`

n8n создает первый owner account через web UI при первом входе. MinIO использует `MINIO_ROOT_USER` и `MINIO_ROOT_PASSWORD`. Dozzle использует native login page с `DOZZLE_USERNAME` и `DOZZLE_PASSWORD` из `.env`.

### Использование общей базы данных

PostgreSQL намеренно не открыт на host и в публичный интернет. Контейнеры во внутренней Docker-сети могут подключаться с такими параметрами:

- Host: `postgres`
- Port: `5432`
- Admin database: значение `POSTGRES_DEFAULT_DB`
- n8n database: значение `N8N_DB_NAME`

Сам n8n использует роль с минимально необходимыми правами:

```text
database: $N8N_DB_NAME
user:     $N8N_DB_USER
password: $N8N_DB_PASSWORD
host:     postgres
port:     5432
```

Для workflows n8n, которым нужно создавать или управлять дополнительными базами данных, создайте PostgreSQL credential в n8n:

```text
database: $POSTGRES_DEFAULT_DB
user:     $POSTGRES_ADMIN_USER
password: $POSTGRES_ADMIN_PASSWORD
host:     postgres
port:     5432
ssl:      disabled for internal Docker network traffic
```

Пример SQL для создания отдельной базы данных под workflow:

```sql
CREATE DATABASE workflow_app;
CREATE USER workflow_app_user WITH PASSWORD 'replace-with-strong-password';
GRANT ALL PRIVILEGES ON DATABASE workflow_app TO workflow_app_user;
```

Предпочтительно создавать отдельных пользователей для каждого workflow или приложения. Не переиспользуйте application user n8n для несвязанных баз данных.

### Процедуры резервного копирования

#### Автоматические локальные backups

### Анализ и обоснование

Этот стек использует `offen/docker-volume-backup:v2` для scheduled local backups. Так как на VPS ограничено место на диске и нет внешнего object storage, backups записываются в `./backups`, а имя файла фиксировано как `n8n-stack-latest.tar.gz`. Каждый новый backup перезаписывает предыдущий архив, а `BACKUP_RETENTION_DAYS=0` делает pruning строгим.

PostgreSQL не резервируется копированием raw database files. Raw snapshots PostgreSQL volume могут быть неконсистентными, пока база работает. Вместо этого backup-сервис использует Docker labels, чтобы выполнить pre-archive command внутри контейнера `postgres`:

```bash
pg_dumpall -U "$POSTGRES_USER" > /backup/postgres/pg_dumpall.sql
```

Этот logical dump записывается во временный Docker volume, включается в архив и сразу удаляется post-archive hook, чтобы экономить место на диске.

Сгенерированный архив содержит:

- `postgres_dump/pg_dumpall.sql`
- `n8n_data/`
- `minio_data/`
- `traefik_letsencrypt/`

Создайте локальную директорию backups, если ее еще нет:

```bash
mkdir -p backups
```

Запустить backup вручную прямо сейчас:

```bash
docker compose --env-file .env exec backup backup
```

Убедиться, что существует только последний архив:

```bash
ls -lh backups
```

Отключить автоматические backups, если на VPS заканчивается место:

```bash
docker compose --env-file .env stop backup
docker compose --env-file .env rm -f backup
```

Удалить существующие локальные backup-архивы:

```bash
rm -f backups/*.tar.gz
```

Восстановление из `backups/n8n-stack-latest.tar.gz`:

```bash
mkdir -p restore/latest
tar -xzf backups/n8n-stack-latest.tar.gz -C restore/latest
```

Остановить сервисы, использующие целевые volumes:

```bash
docker compose --env-file .env stop n8n minio traefik postgres backup
```

Восстановить файлы n8n, MinIO и Traefik в их Docker volumes:

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

Восстановить PostgreSQL из logical dump:

```bash
docker compose --env-file .env up -d postgres
docker compose --env-file .env exec -T postgres psql -U postgres_admin -d postgres < restore/latest/backup/postgres_dump/pg_dumpall.sql
```

Снова запустить весь stack:

```bash
docker compose --env-file .env up -d
```

Также надежно сохраните `.env`. Без `N8N_ENCRYPTION_KEY` существующие credentials n8n нельзя будет расшифровать.

### Стратегия восстановления

1. Подготовьте новый VPS.
2. Установите Docker и Docker Compose.
3. Восстановите этот репозиторий и приватный `.env`.
4. Восстановите backups PostgreSQL и MinIO.
5. Запустите `./deploy.sh`.
6. Проверьте health сервисов и войдите в n8n и MinIO.

### Security notes

Реализованные меры:

- На host опубликованы только порты `80` и `443`.
- PostgreSQL не имеет публичного route и доступен только во внутренней Docker-сети.
- n8n, MinIO и Dozzle маршрутизируются через Traefik с автоматическим TLS.
- Dozzle защищен native simple authentication на базе автоматически сгенерированного зашифрованного файла `users.yml`.
- Docker socket монтируется read-only там, где это требуется.
- Секреты хранятся в `.env` и не коммитятся в Compose.

Рекомендуемое усиление безопасности:

- Включите host firewall, например `ufw`, и разрешите только SSH, HTTP и HTTPS.
- Отключите root SSH login и используйте key-based SSH.
- Обновляйте Docker images по плановому maintenance schedule.
- Храните backups вне сервера и регулярно тестируйте восстановление.
- Ротируйте credentials MinIO, PostgreSQL и Dozzle при смене операторов.

### Команды обслуживания

Обновить images:

```bash
docker compose --env-file .env pull
docker compose --env-file .env up -d
```

Смотреть logs:

```bash
docker compose --env-file .env logs -f n8n
docker compose --env-file .env logs -f traefik
```

Перезапустить один сервис:

```bash
docker compose --env-file .env restart n8n
```

Список containers и health:

```bash
docker compose --env-file .env ps
```

Запустить локальный backup сейчас:

```bash
docker compose --env-file .env exec backup backup
```

Проверить использование диска локальными backups:

```bash
du -sh backups
ls -lh backups
```

Отключить backups и удалить локальные архивы при нехватке места на диске:

```bash
docker compose --env-file .env stop backup
docker compose --env-file .env rm -f backup
rm -f backups/*.tar.gz
```
