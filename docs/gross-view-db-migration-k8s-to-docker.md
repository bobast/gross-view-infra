# Перенос БД `gross_view` из Kubernetes в Docker

Дата: 2026-11-12. Область: **только база `gross_view`** (TimescaleDB). Базы
`keycloak` и `stalwart`, роли/пароли кластера, Vault и PVC не переносятся —
Keycloak и Stalwart продолжают жить в кластере со своими БД.

Целевая среда — контейнер `postgres` из `docker-compose.yml`
(`timescale/timescaledb:2.17.2-pg16`), база `gross_view`, владелец
`gv_dba_user`. Источник — StatefulSet `postgres` в ns `gross-view`
(тот же образ, PostgreSQL 16.6 / TimescaleDB 2.17.2).

Состояние живого кластера на 2026-11-12 (ориентир для проверок): размер БД
~165 MB, 47 таблиц в схеме `public`, 67 записей в `databasechangelog`.

> Коротко: снять `pg_dump -Fc` с кластера → пересоздать локальную БД с
> расширением `timescaledb` → `timescaledb_pre_restore()` → `pg_restore` →
> `timescaledb_post_restore()` → сверить таблицы/данные → запустить локальный
> handler.

---

## 1. Что понадобится

| Компонент | Источник (K8s) | Приёмник (Docker) |
|---|---|---|
| PostgreSQL | StatefulSet `postgres`, образ `timescale/timescaledb:2.17.2-pg16` | сервис `postgres`, тот же образ |
| База | `gross_view` | `gross_view` |
| Владелец БД | `gv_dba_user` | `gv_dba_user` |
| Суперпользователь | `dba_admin` (из Vault `postgres_user`) | `dba_user` (из `.env`, `POSTGRES_DB_USER`) |
| Доступ | VPN `10.2.2.3:15432` или `kubectl exec` | `localhost:5432` (порт опубликован compose) |
| Данные | PVC `postgres-data-postgres-0` | volume `postgres_data` |

Проверки перед началом:

```bash
cd ~/git/gross-view-infra
kubectl -n gross-view get pod postgres-0          # Running, 1/1
docker compose ps postgres                        # Up / healthy
```

> **Два важных условия для всех команд `docker compose` ниже.**
>
> 1. Выполняйте их **из корня репозитория** (`cd ~/git/gross-view-infra`).
>    Из другого каталога compose отвечает
>    `no configuration file provided: not found`. Если запускаете из другого
>    места, добавляйте `-f ~/git/gross-view-infra/docker-compose.yml`.
> 2. Если `docker ps` без `sudo` отвечает
>    `permission denied while trying to connect to the Docker daemon socket`
>    (в текущем окружении это так), добавляйте `sudo` к командам compose.
>    `sudo` по умолчанию сбрасывает окружение, поэтому `-e PGPASSWORD` без
>    значения не сработает — в варианте A передавайте значение явно:
>    `-e PGPASSWORD="$PGPASSWORD"`. На вариант B (`kubectl exec`) это не влияет.

Версии должны совпадать или приёмник должен быть **не старше** источника
(восстановление в более старый TimescaleDB не поддерживается). Проверка:

```bash
# источник
kubectl -n gross-view exec postgres-0 -- sh -c \
  'psql -U "$GV_DB_USER" -d "$GV_DB_NAME" -At \
     -c "select version()" \
     -c "select extname, extversion from pg_extension order by 1"'

# приёмник (добавьте sudo, если docker требует root)
docker compose exec -T postgres sh -c \
  'psql -U "$GV_DB_USER" -d "$GV_DB_NAME" -At \
     -c "select version()" \
     -c "select extname, extversion from pg_extension order by 1"'
```

Для дампа и восстановления **не нужен** `psql` на хосте: используются
`pg_dump`/`pg_restore` из контейнера `postgres` (PostgreSQL 16). Клиент
`pg_dump` должен быть **не старше** сервера, поэтому хостовый клиент 15 или
младше с сервером 16 не справится, а клиент из контейнера гарантированно
совпадает по major-версии.

### Доступ к кластеру

Два независимых пути — достаточно одного:

- **VPN** (быстрее, не нагружает API-сервер): туннель WireGuard до
  `10.2.2.3`, внутри которого опубликован `10.2.2.3:15432` → postgres.
  Подробности — [`docs/vpn-access-k8s.md`](vpn-access-k8s.md), раздел
  «VPN-доступ к postgres и vault (k8s)» в README.
- **`kubectl exec`** (работает без VPN): дамп снимается внутри пода
  `postgres-0` и стримится на хост.

### Что остановить

- Локальный handler (Spring Boot, профиль `debug`), если он запущен: он держит
  соединения к `localhost:5432/gross_view`, а базу мы будем удалять и
  пересоздавать.
- Запись в кластерную БД на время переноса — по желанию. `pg_dump` делает
  транзакционно-согласованный снимок, поэтому остановка не обязательна, но всё,
  что пользователи создадут после начала дампа, в локальную копию не попадёт.
  Если нужен «стоп-кран»:

  ```bash
  kubectl -n gross-view scale deployment/gross-view-api --replicas=0
  # после снятия дампа:
  kubectl -n gross-view scale deployment/gross-view-api --replicas=1
  ```

  На время `--replicas=0` недоступен `/api` (включая MCP-инструменты).

---

## 2. Снять дамп с кластера

Задайте файл дампа (храните вне репозитория — в дампе лежат данные
приложения, включая зашифрованные секреты):

```bash
cd ~/git/gross-view-infra
mkdir -p "$HOME/backups"
DUMP="$HOME/backups/gross_view_$(date +%F).dump"
```

Команды ниже предполагают, что `DUMP` задан в этом же терминале; иначе
подставьте путь к файлу вручную.

Проверьте свободное место: сжатый `-Fc`-дамп заметно меньше БД (на
2026-11-12 — ~11 MB при БД ~165 MB), но локальной БД понадобится место под
распакованные данные.

### Вариант A — через VPN (быстрее)

Пароль `gv_dba_user` подставляется вручную. В кластере он хранится в Secret
`gross-view-secrets`, ключ `gv_db_password` (посмотреть:
`kubectl -n gross-view get secret gross-view-secrets -o jsonpath='{.data.gv_db_password}' | base64 -d`).
Если дампите суперпользователем `dba_admin`, замените `-U` и берите
`postgres_password`.

Прямая подстановка пароля (пароль попадёт в историю команд и на время
выполнения будет виден в `ps`):

```bash
sudo docker compose exec -T -e PGPASSWORD='<ПАРОЛЬ_GV_DBA_USER>' postgres pg_dump -h 10.2.2.3 -p 15432 -U gv_dba_user -d gross_view -Fc > "$DUMP"
```

`docker compose exec -T` обязателен в любом варианте: без `-T` compose
выделяет TTY и бинарный поток `pg_dump` будет испорчен.

Проверка связности до кластера через туннель (клиент — из локального
контейнера):

```bash
docker compose exec -T postgres pg_isready -h 10.2.2.3 -p 15432
```

Если контейнер не видит `10.2.2.3`, проверьте на хосте `ip route get 10.2.2.3`
и что туннель поднят (`sudo wg show`). В этом случае используйте вариант B.

### Вариант B — `kubectl exec` (без VPN)

```bash
kubectl -n gross-view exec postgres-0 -- \
  sh -c 'pg_dump -U "$GV_DB_USER" -d "$GV_DB_NAME" -Fc' > "$DUMP"
```

Почему без пароля: внутри пода `pg_hba.conf` официального образа доверяет
локальному сокету (`local all all trust`), а `GV_DB_USER`/`GV_DB_NAME` уже
проброшены в контейнер из Secret.

Флаг `-t` (TTY) не добавляйте — он портит бинарный вывод. `kubectl exec`
возвращает код удалённой команды, поэтому при ошибке `pg_dump` команда выше
завершится ненулевым кодом (проверьте `echo $?`).

 
## 3. Подготовить локальную БД

Локальная БД должна быть **пустой**: `pg_restore` не должен накладываться на
старую схему. Не используйте `docker compose down -v` — вместе с
`postgres_data` вы удалите базу Keycloak.

1. Убедитесь, что контейнер поднят:

   ```bash
   docker compose up -d postgres
   docker compose ps postgres
   ```

2. Если в локальной `gross_view` уже есть данные, которые нужны, снимите
   резервную копию:

   ```bash
   sudo docker compose exec -T postgres sh -c \
     'pg_dump -U "$GV_DB_USER" -d "$GV_DB_NAME" -Fc' > "$HOME/backups/gross_view_local_before.dump"
   ```

3. Удалите и создайте БД заново (суперпользователь локального контейнера —
   `POSTGRES_USER`, по умолчанию `dba_user`):

```bash
sudo docker compose exec -T postgres sh -c '
     psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
       -c "DROP DATABASE IF EXISTS \"$GV_DB_NAME\" WITH (FORCE)" \
       -c "CREATE DATABASE \"$GV_DB_NAME\" OWNER \"$GV_DB_USER\""
   '
```

   `WITH (FORCE)` (PostgreSQL 13+) завершает активные сессии — поэтому handler
   должен быть остановлен. Если роль `gv_dba_user` отсутствует, создайте её
   (обычно она есть с первого `initdb`):
   `CREATE ROLE "gv_dba_user" LOGIN PASSWORD '…' SUPERUSER;`.

4. Включите TimescaleDB в новой БД (от имени суперпользователя):

```bash
sudo docker compose exec -T postgres sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$GV_DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS timescaledb"'
```

---

## 4. Восстановление (TimescaleDB)

TimescaleDB требует специального режима восстановления: на время
`pg_restore` останавливаются background workers и включается
`timescaledb.restoring`, иначе расширение вмешивается в создание таблиц и
каталог чанков. Поэтому строго три шага **в таком порядке**:

# 1. Подготовить БД к восстановлению
```bash
sudo docker compose exec -T postgres sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$GV_DB_NAME" -c "SELECT timescaledb_pre_restore()"'
   ```
# 2. Восстановить дамп
```bash
sudo docker compose exec -T postgres sh -c 'pg_restore -U "$GV_DB_USER" -d "$GV_DB_NAME" -Fc --exit-on-error' < "$DUMP"
   ```
# 3. Вернуть БД в нормальный режим
```bash
sudo docker compose exec -T postgres sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$GV_DB_NAME" -c "SELECT timescaledb_post_restore()"'
```

Важно:

- **Шаг 3 выполните даже если шаг 2 упал** — иначе background workers останутся
  остановленными. После устранения причины повторите шаги 1–3.
- **Не используйте `pg_restore -j`**: параллельное восстановление ломает
  каталоги TimescaleDB (это прямая рекомендация документации Timescale).
- **Не используйте `--clean`**: база и так создана заново; `--clean` попытается
  удалить расширение и его схемы.
- `--exit-on-error` останавливает восстановление на первой реальной ошибке.
  Если нужно досмотреть все ошибки — уберите флаг и сохраните лог, но затем
  всё равно разберитесь с каждой.
- Имена ролей в дампе и в локальной БД совпадают (`gv_dba_user`), поэтому
  `--no-owner` не нужен: владельцы таблиц восстанавливаются как есть. Если
  локальную роль переименовали, используйте `--no-owner --no-privileges` и
  назначьте владельца вручную.

---

## 5. Проверки после восстановления

### 5.1 Структура и метаданные

```bash
docker compose exec -T postgres psql -U gv_dba_user -d gross_view <<'SQL'
SELECT current_database(), current_user, version();
SELECT extname, extversion FROM pg_extension ORDER BY 1;
SELECT count(*) AS public_tables FROM pg_tables WHERE schemaname = 'public';
SELECT count(*) AS liquibase_changesets FROM databasechangelog;
SELECT * FROM timescaledb_information.hypertables;
SELECT job_id, application_name, schedule_interval, scheduled
  FROM timescaledb_information.jobs ORDER BY job_id;
SELECT pg_size_pretty(pg_database_size(current_database())) AS db_size;
SQL
```

Ожидаемо: `public_tables = 47`, `liquibase_changesets = 67` (значения на
2026-11-12; после запуска более новой версии handler-а changeset-ов может стать
больше), `db_size` — порядка размера исходной БД.

### 5.2 Сверка списка таблиц с кластером

```bash
docker compose exec -T postgres psql -U gv_dba_user -d gross_view -Atc \
  "select tablename from pg_tables where schemaname = 'public' order by 1" > /tmp/local_tables.txt

kubectl -n gross-view exec postgres-0 -- psql -U gv_dba_user -d gross_view -Atc \
  "select tablename from pg_tables where schemaname = 'public' order by 1" > /tmp/cluster_tables.txt

diff -u /tmp/cluster_tables.txt /tmp/local_tables.txt && echo "набор таблиц совпадает"
```

### 5.3 Точечная проверка данных

Имена таблиц — из changelog handler-а (`workspace`, `journal`, `operation`,
`account`, …). Сравните несколько счётчиков с кластером:

```bash
docker compose exec -T postgres psql -U gv_dba_user -d gross_view -c \
  'SELECT count(*) AS workspaces FROM workspace;
   SELECT count(*) AS journals FROM journal;'
```

Те же запросы выполните в кластере (через `kubectl exec` или VPN) и сверьте
числа. Если таблицы не используются в вашей инсталляции, выберите те, что
видны в `\dt`.

### 5.4 Запуск локального handler

Перед запуском handler-а проверьте две вещи:

1. **Пароль роли.** Handler в профиле `debug` берёт `DB_USER`/`DB_PASS` из
   Vault по пути `secret/gross-view-handler-dev`, а не из `.env`. Пароль
   локальной роли `gv_dba_user` должен совпадать с `DB_PASS` из этого пути.
   Если в `.env` был другой `GV_DB_PSWD`, синхронизируйте:

   ```bash
   read -rsp "Новый пароль для gv_dba_user: " NEW_PASS; echo
   printf "%s\n" "ALTER ROLE gv_dba_user PASSWORD '$NEW_PASS';" \
     | docker compose exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1'
   unset NEW_PASS
   ```

   Если в пароле есть одинарная кавычка, экранируйте её удвоением (`''`).
   (Либо обновите `DB_PASS` в Vault — тогда не забудьте `force-sync`
   соответствующего ExternalSecret; для локального handler-а достаточно
   привести пароль роли в соответствие с Vault.)

2. **VPN до Vault.** Handler ходит в кластерный Vault по
   `http://10.2.2.3:18200`; без поднятого туннеля он не получит креды БД и не
   стартует.

Запустите handler в профиле `debug` (из `../gross-view-handler`) и проверьте:

```bash
curl -s http://localhost:8082/api/actuator/health
```

Liquibase при старте валидирует changelog. Если локальный код handler-а
**старее** схемы, восстановленной из кластера, старт упадёт на
`ChangeSet … is not present in the changelog`/`checksum` — возьмите версию
handler-а не старше развёрнутой в кластере.

---

## 6. Откат и уборка

- Кластерная БД при переносе **не изменяется**: дамп снимается read-only, все
  данные остаются на месте. Если вы останавливали handler — верните реплику:

  ```bash
  kubectl -n gross-view scale deployment/gross-view-api --replicas=1
  kubectl -n gross-view rollout status deployment/gross-view-api
  ```

- Если восстановление в локальную БД не удалось, проще всего повторить
  раздел 3 (пересоздать БД) и раздел 4 — дамп не тронут.
- Если нужно вернуть прежнее локальное состояние, восстановите
  `gross_view_local_before.dump` той же процедурой (pre_restore → pg_restore →
  post_restore).
- Полный сброс локального volume (`docker compose down -v`) удалит **все**
  базы, включая `keycloak`, — используйте только как крайнюю меру, после чего
  `docker compose up -d postgres` заново выполнит `postgres/init/*.sh`.
- После успешной проверки удалите дампы: они содержат данные приложения
  (включая зашифрованные секреты) и не должны попадать в git:

  ```bash
  rm -f "$DUMP" "$HOME/backups/gross_view_local_before.dump"
  ```

---

## 7. Диагностика

| Симптом | Причина | Что делать |
|---|---|---|
| `pg_dump: error: aborting because of server version mismatch` | клиент старше/младше сервера 16 | снимать дамп `pg_dump` из контейнера `postgres` (16), не хостовым клиентом |
| `FATAL: password authentication failed for user "gv_dba_user"` | неверный пароль или `-e PGPASSWORD` не пробросился | проверить Secret `gross-view-secrets` (`gv_db_password`); при `sudo` передать `-e PGPASSWORD="$PGPASSWORD"` явно (см. раздел 2) |
| `pg_dump: error: query failed: … permission denied` | дамп снят не тем пользователем | внутри пода использовать `pg_dump -U "$GV_DB_USER"`; через VPN — `gv_dba_user` |
| `input file appears to be a text format dump` / `unexpected end of file` | бинарный вывод испорчен TTY или PowerShell | переснять дамп с `-T`/из WSL либо через `kubectl cp` |
| `database "gross_view" is being accessed by other users` | запущен локальный handler или другой клиент | остановить handler; `DROP DATABASE … WITH (FORCE)` завершит оставшиеся сессии |
| `ERROR: role "gv_dba_user" does not exist` | роль не создана в локальной БД | `CREATE ROLE …` или восстановить с `--no-owner --no-privileges` |
| `ERROR: must be superuser to create extension "timescaledb"` | `CREATE EXTENSION` выполнен не суперпользователем | выполнять от `POSTGRES_USER` (`dba_user`) |
| `function timescaledb_pre_restore() does not exist` | в целевой БД нет расширения | `CREATE EXTENSION IF NOT EXISTS timescaledb` до шага 4 |
| после восстановления не работают jobs/background workers | не выполнен `timescaledb_post_restore()` | выполнить шаг 3 раздела 4 |
| `catalog version mismatch, expected "2.17.2" seen "…"` при `timescaledb_post_restore()` | дамп снят с другой версии TimescaleDB | использовать на приёмнике тот же `timescaledb 2.17.2` (образ `timescale/timescaledb:2.17.2-pg16`), пересоздать БД и повторить restore |
| `ChangeSet … is not present in the changelog` при старте handler-а | локальный handler старее кластерной схемы | запустить версию handler-а не старше развёрнутой в кластере |
| handler падает с ошибкой подключения к Vault | не поднят VPN | поднять туннель, проверить `http://10.2.2.3:18200/v1/sys/health` |

---

## 8. Чек-лист

- [ ] `kubectl -n gross-view get pod postgres-0` — `Running`
- [ ] `docker compose ps postgres` — `healthy`
- [ ] Версии PostgreSQL/TimescaleDB на источнике и приёмнике совместимы
- [ ] Дамп снят (`-Fc`), `pg_restore -l` читает его без ошибок
- [ ] Локальный handler остановлен
- [ ] Локальная БД пересоздана, расширение `timescaledb` включено
- [ ] `timescaledb_pre_restore()` → `pg_restore --exit-on-error` → `timescaledb_post_restore()`
- [ ] Список таблиц и ключевые счётчики совпадают с кластером
- [ ] Пароль `gv_dba_user` совпадает с `DB_PASS` из `secret/gross-view-handler-dev`
- [ ] Локальный handler стартует, `/api/actuator/health` отвечает
- [ ] Реплика `gross-view-api` в кластере возвращена (если останавливали)
- [ ] Дампы удалены
