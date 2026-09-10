# OpenCode ↔ gross-view MCP: integration plan (docker + k8s)

> Обновлено: 2026-09-08. Описывает, как MCP-сервер gross-view-handler (`/api/mcp`)
> подключается к ИИ-агенту opencode, и все доработки инфраструктуры
> (docker-compose и K8s-манифесты), необходимые для этого.

## 1. Контекст

- **gross-view-handler** — Spring Boot 4.1 (Java 21) backend. Реализует
  **собственный MCP-сервер** (Streamable HTTP, JSON-RPC 2.0) на `POST/GET /api/mcp`
  без стороннего MCP-SDK.
- **opencode** — развёртываемый ИИ-агент (`ghcr.io/anomalyco/opencode`), который
  обязан быть подключён к MCP-сервису handler-а. Пользователь обращается к агенту
  через чат в gross-view UI.
- Ключевое архитектурное решение handler-а — **workspace привязывается к MCP-сессии
  при `initialize` по субъекту JWT**, см. §2. Оно определяет, какие сущности
  (клиент Keycloak, токен, членства) обязаны существовать в инфраструктуре.

## 2. Аутентификация и workspace: как это устроено в handler-е

### 2.1 REST-чат (UI → handler → opencode)

1. UI шлёт на `POST /api/opencode/{chat,analyze}` пользовательский **JWT
   (Keycloak)** + заголовок **`X-Workspace-Id`**.
2. Handler проверяет JWT через Spring OAuth2 Resource Server (Nimbus, JWKS
   Keycloak), затем членство/роль через `WorkspaceAccessService`
   (`ensureMember`/`ensureAnyRole(ADMIN, ANALYST)`) — двойная проверка
   (`@PreAuthorize` + сервис).
3. Handler обращается к **серверу opencode по Feign** (`opencode.api.base-url`,
   HTTP Basic из `OPENCODE_SERVER_USERNAME`/`OPENCODE_SERVER_PASSWORD`) и создаёт
   сессию, фиксируя владельца + workspace в таблице `opencode_session`
   (изоляция чатов между пользователями).

### 2.2 MCP (агент → handler `/api/mcp`)

1. `GET /.well-known/oauth-protected-resource` (RFC 9728) отдаёт метаданные:
   `resource = https://…/api/mcp`, `authorization_servers[0] = <issuer-uri>`
   (ровно `{KEYCLOAK_URL}/realms/gross-view-realm` без trailing slash),
   `scopes = [openid, offline_access]`.
2. `POST /api/mcp` без токена → `401` +
   `WWW-Authenticate: Bearer resource_metadata="..."` — точка входа в OAuth-флоу.
3. Клиент (opencode CLI) делает OIDC discovery → PKCE auth-code → JWT.
4. `initialize {params: {workspace_id}}` → `WorkspaceService.resolveWorkspaceId()`:
   проверка членства по `preferred_username` (основной ключ) / `sub` из JWT →
   `McpSessionStore.bind(sessionId, workspaceId, username)` → `Mcp-Session-Id`.
5. `tools/call` и `resources/read` читают workspace из контекста сессии
   (TTL 30 мин), **не из аргументов** (`workspace_id` из inputSchema удалён).
6. Требуемая роль на `/api/mcp`: `MCP` / `DESIGNER` / `OZON_IMPORT` / `ANALYST` /
   `ADMIN` (`@PreAuthorize("hasAnyRole(...)")`).

**Следствие для инфры:** workspace MCP-сессии определяется **субъектом JWT,
который агент предъявляет на `/api/mcp`**. Handler — только сервер, он не
подставляет контекст пользователя в MCP-запросы агента. Значит у развёрнутого
(общего) агента нужно осознанно выбрать, чей токен идёт в `Authorization`.

## 3. Сценарии подключения агента и выбор токена

### 3.1 Локальный CLI пользователя (работает уже сейчас)

```
opencode.json: { "mcp": { "gross-view": { "type": "remote",
                "url": "https://gross-view.local/api/mcp" } } }
opencode mcp auth gross-view   # браузер -> Keycloak -> callback 127.0.0.1:19876
```
Каждый пользователь получает **свой** JWT → свой workspace. Требования:
публичный `mcp.url`/issuer синхронны, роль `MCP` на пользователе, realm-клиент
`opencode-mcp` (public, callback `http://127.0.0.1:19876/mcp/oauth/callback`) — всё
уже есть в `gross-view-realm.json`.

### 3.2 Развёрнутый (общий) агент — v1 (реализуется сейчас)

Один общий инстанс агента не может пройти интерактивный OAuth. Для v1:

- В Keycloak заводится **конфиденциальный клиент `opencode-agent`** (service
  account, секрет из `.env`/Secret, `access.token.lifespan = 86400`);
  сервис-аккаунт получает **realm-роль `MCP`**.
- Сервис-аккаунт **добавляется членом рабочего пространства** (в handler-е),
  иначе `resolveWorkspaceId(null)` упадёт `WorkspaceAccessDeniedException` → 403.
- Агент получает токен через `client_credentials`
  (`scripts/get-opencode-mcp-token.ps1`) и регистрирует gross-view MCP как
  `type=remote` + `Authorization: Bearer <token>` (конфиг пишется в
  `/root/.config/opencode/opencode.json` из `.env` при старте).
- Адрес для агента — **внутренний** `http://handler:8082/api/mcp` (docker) /
  `http://gross-view-api.gross-view.svc.cluster.local:8082/api/mcp` (k8s): без
  петли через публичный балансировщик и без доверия TLS-сертификату.

**Ограничение v1:** MCP-инструменты общего агента работают в workspace
сервис-аккаунта (для всех пользователей), изоляция чатов — только на уровне
`opencode_session` в handler-е. Полная per-user изоляция MCP-инструментов — v2,
требует доработки handler-а (инъекция user-токена в конфиг MCP агента по сессии);
в этой задаче не реализуется.

### 3.3 v2 (направление, не входит в текущий план реализации)

- Handler при создании сессии для пользователя должен подставлять в конфиг
  MCP-сервера агента user-токен (или Keycloak token-exchange/impersonation),
  чтобы `initialize` биндил workspace конкретного пользователя. Для этого нужен
  конфиденциальный клиент с правом token-exchange и/или per-session перезапись
  `/mcp` конфига opencode. См. §12.12 AGENTS.md handler-а («Workspace-Scoped
  Sessions»).

## 4. Доработки Docker (реализовано)

| Файл | Изменение |
|---|---|
| `docker-compose.yml` | + сервис `handler` (build из `../gross-view-handler`, порт 8082, статический IP `172.28.0.9`); opencode: `OPENCODE_SERVER_PASSWORD` + MCP-провижининг через `opencode/entrypoint.sh` |
| `nginx/gross-view.local.conf` | upstream `/api/` теперь `http://handler:8082` (было `host.docker.internal:8082`) |
| `handler/entrypoint.sh` | импорт self-signed `certs/gross-view.local.crt` в JVM-cacerts (для Nimbus JWKS по `https://gross-view.local/sso/...`) |
| `opencode/entrypoint.sh` | генерирует `/root/.config/opencode/opencode.json` (remote MCP); **авто-генерация токена из Keycloak** (`client_credentials`), если `OPENCODE_MCP_TOKEN` не задан |
| `scripts/get-opencode-mcp-token.ps1` | ручная выдача `client_credentials`-токена (для override/диагностики) |
| `.env.example` | + `KEYCLOAK_INTERNAL_URL`, `CREDENTIAL_ENCRYPTION_KEY`, `OPENCODE_*`, `OZON_*` |
| `dns/dnsmasq.conf` | + `gross-view-api`/`gross-view-api.local` → `172.28.0.9` |
| `gross-view-realm.json` | + realm-роли `MCP`/`ANALYST`/`ADMIN`; + конфиденциальный клиент `opencode-agent` (service account); + service-account пользователь с ролью `MCP` |
| `gross-view-handler` (соседний репозиторий) | + `Dockerfile` + `.dockerignore` (по §14.1 AGENTS.md handler-а) |

### 4.1 Порядок запуска

```bash
cd C:\git\gross-view-infra
cp .env.example .env          # заполнить секреты (не коммитить .env), в т.ч.
                              # OPENCODE_AGENT_CLIENT_SECRET=<секрет клиента opencode-agent>
docker compose build handler  # сборка образа gross-view-handler
docker compose up -d          # поднять всю связку
# РЕГИСТРАЦИЯ MCP теперь АВТОМАТИЧЕСКАЯ: если OPENCODE_MCP_TOKEN пуст,
# entrypoint.sh сам получает client_credentials-токен из Keycloak при старте.
docker compose up -d opencode  # (повторно — чтобы применить новый .env)
# проверить MCP у агента: docker compose exec opencode opencode mcp list
```

### 4.2 Обязательные переменные `.env`

```
KEYCLOAK_INTERNAL_URL=http://keycloak:8080   # внутренний (in-network, plain HTTP) endpoint Keycloak
                                   # для авто-генерации токена в entrypoint.sh — образ opencode
                                   # BusyBox, в нём НЕТ curl и НЕТ TLS-стека wget, поэтому
                                   # публичный https://gross-view.local/sso из контейнера токен не даст
CREDENTIAL_ENCRYPTION_KEY=<32-байтовый base64> # handler падает без него (fail-fast)
OPENCODE_SERVER_USERNAME=opencode
OPENCODE_SERVER_PASSWORD=<пароль opencode>
OPENCODE_MCP_URL=http://handler:8082/api/mcp    # внутренний адрес MCP для агента
OPENCODE_MCP_TOKEN=<client_credentials токен opencode-agent>  # необязательно — авто-генерация
OPENCODE_AGENT_CLIENT_ID=opencode-agent
OPENCODE_AGENT_CLIENT_SECRET=<секрет клиента>   # нужен для авто-генерации токена
```

> **Единый источник правды для секрета OpenCode.** `OPENCODE_SERVER_PASSWORD` —
> единственное имя переменной: его читает сервер opencode (docker-compose) и клиент
> — handler (`opencode.api.password`). Значение обязано совпадать во **всех** местах:
> `gross-view-infra/.env`, окружение handler-а (`debug.env`/IDE/bootRun) и
> k8s-секрет `gross-view-secrets/opencode_server_password`. Рассинхронизация —
> классическая причина `401` → `error.opencode.auth` → `502` в `GlobalExceptionHandler`
> (`GET /opencode/health`, `GET /opencode/sessions`, чат).
> `OPENCODE_PASSWORD` — legacy-fallback в compose (используется, только если
> `OPENCODE_SERVER_PASSWORD` не задан); для новых конфигураций не используется.

> **Почему в entrypoint используется `wget`, а не `curl`.** Образ opencode
> (`ghcr.io/anomalyco/opencode:latest`) — минимальный BusyBox (`linux/busybox`),
> в нём **нет `curl`** (первая версия авто-генерации падала с
> `/entrypoint.sh: line …: curl: not found`), зато есть `/usr/bin/wget`
> (BusyBox wget v1.37, поддерживает `--post-data`, `--header`, `-T SEC`,
> `-O -`). BusyBox wget не имеет TLS-стека для самоподписанных сертификатов,
> поэтому для `client_credentials` используется **внутренний** Keycloak-эндпоинт
> `KEYCLOAK_INTERNAL_URL` (`http://keycloak:8080` в docker,
> `http://keycloak.gross-view.svc.cluster.local:8080` в k8s), а не публичный
> `https://gross-view.local/sso`. Второй причиной была незаполненная
> `OPENCODE_AGENT_CLIENT_SECRET` (плейсхолдер) — авто-генерация не запускалась.

> **Устойчивость авто-генерации токена (с `wget`).** Получение токена ретраится
> до `OPENCODE_TOKEN_MAX_ATTEMPTS` раз (по умолчанию 10, с паузой 2 сек). Причина
> отказа всегда попадает в лог: `WARNING: … Response: wget: …`. Главное правило:
> **ранее рабочий `opencode.json` никогда не удаляется при сбое** — transient-сбой
> Keycloak больше не выключает gross-view MCP молча (так возникала повторяющаяся
> ошибка интерфейса «MCP-серверы не обнаружены»: entrypoint удалял конфиг, и
> `GET /mcp` возвращал `{}`). Если сохранённый токен протух — opencode стартует и
> сообщает ошибку сервера в `GET /mcp` (`status: failed`, `error: "…"`), что
> диагностируемо (см. раздел handler `OpenCodeMcpStatus.error`).

> **Re-entry логика (status «unknown» / токен протух).** Начиная с фикса
> 2026-09-10 entrypoint **проверяет `exp`** сохранённого токена (base64url payload
> декодируется без jq: `tr _- /+` + `base64 -d` + греп `exp:` + сравнение с
> `date +%s`) и, если он истёк или отсутствует, **самобновляет токен** из Keycloak
> при старте — ручной `docker compose restart opencode` больше не нужен. Классическая
> причина «постоянный unknown»: opencode стартовал раньше, чем Keycloak поднялся
> (`wget: can't connect … Connection refused`), все попытки отвалились, а из volume
> подхватился протухший токен. От race-условия защищает docker-compose:
> `keycloak` имеет `healthcheck` (TCP-probe на 8080 через `/dev/tcp`, т.к. в образе
> нет curl/wget, есть bash+timeout), а `opencode` ждёт `depends_on:
> keycloak: condition: service_healthy`.

### 4.3 Первичная настройка при существующей БД Keycloak

Роли и клиент, добавленные в `gross-view-realm.json`, применяются **только при
свежем импорте** (`start --import-realm`). На работающем Keycloak выполнить один раз:

```bash
KC=/opt/keycloak/bin/kcadm.sh   # внутри контейнера keycloak
./kcadm.sh config credentials --server http://localhost:8080 --realm master \
  --user $KEYCLOAK_ADMIN --password $KEYCLOAK_ADMIN_PASSWORD
./kcadm.sh create roles -r gross-view-realm -s name=MCP -s name=ANALYST -s name=ADMIN
./kcadm.sh create clients -r gross-view-realm \
  -s clientId=opencode-agent -s secret=<секрет> -s serviceAccountsEnabled=true \
  -s access.token.lifespan=86400
# ... роль MCP на сервис-аккаунте и членство в workspace — см. §5.
```

## 5. Операционные шаги v1 для docker

1. Добавить сервис-аккаунт **членом рабочего пространства** в handler-е
   (username = `service-account-opencode-agent`), напр. через `/api/workspaces/.../invitations`
   (приглашение по `preferred_username`) или SQL в `workspace_member`.
2. Заполнить `OPENCODE_AGENT_CLIENT_SECRET` в `.env` (секрет клиента `opencode-agent`
   из Keycloak). Если хотите задать токен вручную вместо авто-генерации — вызвать
   `scripts/get-opencode-mcp-token.ps1` и положить в `.env` `OPENCODE_MCP_TOKEN`.
3. Перезапустить opencode; в логах должно быть
   `==> gross-view MCP registered for opencode`. Проверить
   `docker compose exec opencode opencode mcp list` → `gross-view` со статусом
   `connected`; вызвать инструмент (`get_account_plan` и т.п.) — должен отработать
   в workspace сервис-аккаунта.

> **Срок жизни токена.** Токен `client_credentials` живёт `access.token.lifespan`
> клиента (в `gross-view-realm.json` — 86400 c = 24 ч). Docker: благодаря
> re-entry логике (см. выше) каждый старт контейнера проверяет `exp` сохранённого
> токена и **автоматически переиздаёт** протухший — отдельный ручной шаг не нужен;
> `docker compose restart opencode` остаётся быстрым способом переподключить MCP
> сразу (пересоздаёт конфиг и перезапускает сервер opencode). K8s: см. §6 (CronJob
> обновления Secret) — там re-entry также сработает при деплое пода.

## 6. План доработок K8s (реализовано, применять при постановке API-деплоя)

1. **Новые манифесты** `k8s/base/gross-view-api-deployment.yaml` +
   `gross-view-api-service.yaml` (Deployment `gross-view-api` + ClusterIP :8082,
   зеркало docker `handler`): image `ghcr.io/gross-view/gross-view-handler`,
   env: `KEYCLOAK_URL=mint-box.ru`, `POSTGRES_URL=postgres:5432`,
   `DB_USER/DB_PASS` из `gross-view-secrets` (`gv_db_user`/`gv_db_password`),
   `CREDENTIAL_ENCRYPTION_KEY`, `OPENCODE_BASE_URL=http://opencode.gross-view.svc.cluster.local:4096`,
   `OPENCODE_SERVER_USERNAME/PASSWORD` из `gross-view-secrets`
   (`opencode_server_username`/`opencode_server_password`),
   `MCP_URL=https://mint-box.ru/api/mcp`.
   (nginx в K8s **уже** резолвит `gross-view-api.gross-view.svc.cluster.local:8082`)
2. **`kustomization.yaml`**: включить `gross-view-api-*.yaml`;
   раскомментировать `opencode-deployment/service/pvc.yaml` и
   `opencode-entrypoint-configmap.yaml`.
3. **`secret.yaml`**: ✅ сделано — добавлены `opencode_server_username`,
   `opencode_server_password`, `keycloak_internal_url`, `opencode_agent_client_id`,
   `opencode_agent_client_secret` (плюс строки для `credential_encryption_key`,
   `keycloak_client_secret`, при необходимости `ozon_api_key` добавятся с манифестами API).
4. **`opencode-deployment.yaml`**: ✅ сделано — command `["/bin/sh", "/entrypoint.sh"]`;
   env `OPENCODE_SERVER_USERNAME/PASSWORD`, `KEYCLOAK_INTERNAL_URL`
   (`http://keycloak.gross-view.svc.cluster.local:8080`),
   `OPENCODE_AGENT_CLIENT_ID/SECRET` (из Secret), `OPENCODE_MCP_URL`
   (`http://gross-view-api…:8082/api/mcp`), опциональный `OPENCODE_MCP_TOKEN`
   (из Secret, ключ `opencode_mcp_token`, `optional: true` — авто-генерация
   является fallback); entrypoint монтируется из ConfigMap `opencode-entrypoint`
   (`opencode-entrypoint-configmap.yaml`, `defaultMode: 0555`, скрипт синхронизирован
   с docker-версией `opencode/entrypoint.sh`). **Docker-race-fix (см. §4.2/§5)**
   дублирован как `initContainer wait-for-keycloak`: ждёт `/health/ready` на
   `http://keycloak.gross-view.svc.cluster.local:8080` (цикл `wget` из образа
   opencode, BusyBox) до старта main-контейнера — k8s не поддерживает `depends_on`/
   `condition: service_healthy`, поэтому без initContainer opencode стартовал бы
   раньше готовности Keycloak, entrypoint не получил бы токен, а MCP остался бы
   в статусе «unknown». URL в initContainer обязан совпадать с
   `gross-view-secrets/keycloak_internal_url`.
5. **Токен в K8s**: если ключ `opencode_mcp_token` в Secret не задан, entrypoint
   авто-генерирует токен из `opencode_agent_client_secret` при старте пода. При
   истечении токена (24 ч) — перезапустить под (`kubectl rollout restart
   deployment/opencode`) либо периодически обновлять Secret CronJob-ом
   (обёртка над `scripts/get-opencode-mcp-token.ps1`).
6. **Realm** (общий с docker): роли `MCP`/`ANALYST`/`ADMIN`, клиент `opencode-agent` —
   импортируется свежим `mint-box.ru` realm-импортом; на работающих кластерах — kcadm.
7. **Бюджет ресурсов**: handler ≈ 200m CPU / 300–400Mi RAM requests. Ориентир узла
   `~800m / ~1500Mi` будет превышен — поднять узел до 2 CPU или пересмотреть limits.
8. Обновить AGENTS.md (расписание сервисов, таблица ресурсов).

> При постановке API-деплоя не забыть: `OPENCODE_SERVER_PASSWORD` handler-а обязан
> совпадать с секретом opencode-деплоя (одна переменная на обе стороны, см. §4.2).

## 7. Связанные файлы handler-а (для справки)

- `controller/McpController.java` — `initialize`/session binding, 401 + `resource_metadata`.
- `config/SecurityConfig.java` — OAuth2 Resource Server, `@PreAuthorize` роли.
- `service/workspace/WorkspaceService.java#resolveWorkspaceId` — членство по JWT.
- `service/integro/opencode/OpenCodeClient.java` — Feign-клиент сервера opencode.
- `service/mcp/OAuthMetadataService.java` — `mcp.url`/issuer-uri (`MCP_URL`, `KEYCLOAK_URL`).