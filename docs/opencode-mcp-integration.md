# OpenCode ↔ gross-view MCP: integration plan (docker + k8s)

> Обновлено: 2026-09-21. Описывает, как MCP-сервер gross-view-handler (`/api/mcp`)
> подключается к ИИ-агенту opencode, и все доработки инфраструктуры
> (docker-compose и K8s-манифесты), необходимые для этого.
>
> **Изменение 2026-09-21:** отменён dedicated сервис-аккаунт и общий токен.
> Оба направления аутентифицируются **реальным пользователем** (JWT):
> - handler → opencode: **сквозной JWT пользователя** (Bearer), HTTP Basic удалён;
> - opencode → handler `/api/mcp`: **OAuth 2.0 (RFC 9728)** — PKCE auth-code
>   реального пользователя через публичный Keycloak-клиент `opencode-mcp`.
> Токены общего сервис-аккаунта (`service-account-opencode-agent` +
> конфиденциальный клиент `opencode-agent`) из инфраструктуры **удалены**.

## 1. Контекст

- **gross-view-handler** — Spring Boot 4.1 (Java 21) backend. Реализует
  **собственный MCP-сервер** (Streamable HTTP, JSON-RPC 2.0) на `POST/GET /api/mcp`
  без стороннего MCP-SDK.
- **opencode** — развёртываемый ИИ-агент (`ghcr.io/anomalyco/opencode`), который
  обязан быть подключён к MCP-сервису handler-а. Пользователь обращается к агенту
  через чат в gross-view UI.
- Ключевое архитектурное решение handler-а — **workspace привязывается к MCP-сессии
  при `initialize` по субъекту JWT**, см. §2. Оно определяет, какие сущности
  (клиент Keycloak, членства, workspace-scoping) обязаны существовать в инфраструктуре.

## 2. Аутентификация и workspace: как это устроено в handler-е

### 2.1 REST-чат (UI → handler → opencode)

1. UI шлёт на `POST /api/opencode/{chat,analyze}` пользовательский **JWT
   (Keycloak)** + заголовок **`X-Workspace-Id`**.
2. Handler проверяет JWT через Spring OAuth2 Resource Server (Nimbus, JWKS
   Keycloak), затем членство/роль через `WorkspaceAccessService`
   (`ensureMember`/`ensureAnyRole(ADMIN, ANALYST)`) — двойная проверка
   (`@PreAuthorize` + сервис).
3. Handler обращается к **серверу opencode по Feign** (`opencode.api.base-url`)
   и **пробрасывает JWT текущего пользователя** в `Authorization: Bearer <jwt>`
   (из `SecurityContextHolder`; при отсутствии JWT-контекста заголовок не
   выставляется). Никаких постоянных учётных данных сервера
   (`OPENCODE_SERVER_USERNAME`/`OPENCODE_SERVER_PASSWORD`) у handler-а больше нет —
   сервер opencode живёт на внутренней сети без собственной аутентификации, JWT
   служит для атрибуции вызовов в логах/сессиях opencode. Handler создаёт сессию,
   фиксируя владельца + workspace в таблице `opencode_session`
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
подставляет контекст пользователя в MCP-запросы агента. Поэтому развёрнутый
(общий) агент обязан проходить OAuth **как реальный пользователь** — общий
сервис-аккаунт невозможен (у него нет членств в пространствах пользователей).

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

### 3.2 Развёрнутый (общий) агент — OAuth реального пользователя (текущая реализация)

Один общий инстанс агента аутентифицируется на `/api/mcp` **не** через общий
сервис-аккаунт (его больше нет), а через **OAuth-флоу от имени реального
пользователя**:

- opencode.json развёрнутого агента регистрирует gross-view как
  `type: "remote"` + `oauth: { clientId: "opencode-mcp", scope: "openid" }`
  (публичный, предрегистрированный клиент Keycloak; DCR не требуется);
- при **первом** вызове MCP (или явной командой `opencode mcp auth gross-view`)
  opencode запускает authorization-code flow (PKCE):
  - `BROWSER=none` → opencode печатает authorization URL, оператор открывает его
    в браузере, логинится в Keycloak с ролью `MCP`/`DESIGNER`/`OZON_IMPORT`
    (или ADMIN/ANALYST), callback `http://127.0.0.1:19876/mcp/oauth/callback`;
  - полученные токены opencode сохраняет в
    `~/.local/share/opencode/mcp-auth.json` **на персистентном volume** — в
    манифестах добавлен второй mount `opencode-data → /root/.local/share/opencode`
    (только `/root/.config/opencode` было бы недостаточно — после рестарта пода
    токен терялся);
- адрес для агента — **внутренний** `http://host.docker.internal:8082/api/mcp`
  (docker, handler на хосте) / `http://gross-view-api.gross-view.svc.cluster.local:8082/api/mcp`
  (k8s): без петли через публичный балансировщик и без доверия TLS-сертификату.

**Ограничение:** MCP-инструменты работают в workspace **пользователя, который
прошёл OAuth**. Изоляция чатов между пользователями — окно входа одно на агента;
для пер-пользовательской изоляции MCP-инструментов пока нет (см. §3.3).
Realm-роль `MCP` на пользователе обязательна (или legacy
`DESIGNER`/`OZON_IMPORT`).

### 3.3 v2 (реализовано) — per-(пользователь, workspace) MCP-подключение

Реализовано на стороне handler-а (`McpSessionCredentialService`, см.
`sketches/descriptions/opencode_session_mcp_connection.md`): для пары
«пользователь + workspace» динамически регистрируется MCP-сервер на агенте
(`gross-view-<workspaceId>-<userHash>`) через `POST /mcp` с заголовками
`Authorization: Bearer <mcp-jwt>` и `X-Workspace-Id`. MCP-токен выпускается
**Keycloak Token Exchange (RFC 8693)** с `audience = mcp` (фолбэк — access-токен
пользователя; управляется env handler-а `OPENCODE_MCP_TOKEN_EXCHANGE`).

**Требования к инфраструктуре (выполнено):**

1. **Keycloak** — включить feature Token Exchange: `--features=token-exchange`
   (`docker-compose.yml` → `command: start --import-realm --features=token-exchange`;
   `k8s/base/keycloak-deployment.yaml` → `args`).
2. **Realm** (`gross-view-realm.json`):
   - конфиденциальный клиент `gross-view-handler-service` (service account,
     `publicClient: false`) — им handler аутентифицируется при exchange;
   - клиент-ресурс `mcp` (`bearerOnly`, `authorizationServicesEnabled`) — audience
     для exchange; на нём выдан scope `token-exchange` клиенту
     `gross-view-handler-service` (client policy).
3. **Handler** — `keycloak.client-id`/`client-secret` указывают на
   `gross-view-handler-service` (env `KEYCLOAK_CLIENT_ID`, `KEYCLOAK_CLIENT_SECRET`).
   В `gross-view-handler` (публичный SPA-клиент) обмен невозможен — Token Exchange
   требует конфиденциальный клиент.

## 4. Доработки Docker (реализовано)

| Файл | Изменение |
|---|---|
| `docker-compose.yml` | opencode: `OPENCODE_MCP_URL` + `OPENCODE_MCP_CLIENT_ID` (публичный клиент); LLM-ключ — env `DEEPSEEK_API_KEY` (проброс из `.env`, см. §4.4); объём `opencode-data` смонтирован в `/root/.config/opencode` **и** `/root/.local/share/opencode` (OAuth-tokens); `depends_on: keycloak` удалён (entrypoint Keycloak не вызывает) |
| `nginx/gross-view.local.conf` | upstream `/api/` — `host.docker.internal:8082` (handler на хосте, см. ниже) |
| `handler/entrypoint.sh` | импорт self-signed `certs/gross-view.local.crt` в JVM-cacerts (для Nimbus JWKS по `https://gross-view.local/sso/...`) |
| `opencode/entrypoint.sh` | генерирует `/root/.config/opencode/opencode.json` (remote MCP + `oauth` публичного клиента `opencode-mcp`); **без** авто-генерации токена |
| `scripts/get-opencode-mcp-token.ps1` | **удалён** (client_credentials не используется) |
| `.env.example` | открытые переменные: `OPENCODE_MCP_URL`, `OPENCODE_MCP_CLIENT_ID`, `OPENCODE_MCP_SCOPE`, `OPENCODE_DEFAULT_MODEL`, `OPENCODE_CATALOG_CREATE_MISSING`, `KEYCLOAK_CLIENT_ID`, `KEYCLOAK_CLIENT_SECRET` (Token Exchange); удалены `OPENCODE_SERVER_USERNAME/PASSWORD`, `OPENCODE_PASSWORD`, `OPENCODE_MCP_TOKEN`, `KEYCLOAK_INTERNAL_URL`, `OPENCODE_AGENT_CLIENT_ID/SECRET`, `OPENCODE_TOKEN_MAX_ATTEMPTS` |
| `gross-view-realm.json` | realm-роли `MCP`/`ANALYST`/`ADMIN`; публичный клиент `opencode-mcp` (OAuth для opencode); конфиденциальный клиент `gross-view-handler-service` (Token Exchange) + клиент-ресурс `mcp` (audience, scope `token-exchange`); **клиент `opencode-agent` + сервис-аккаунт удалены** |
| `gross-view-handler` (соседний репозиторий) | Feign-клиент OpenCode: **сквозной JWT пользователя вместо HTTP Basic**; серверного пароля у handler-а нет |

> **handler в docker-compose отсутствует** — backend `gross-view-handler`
> (Spring Boot, порт 8082) запускается локально в режиме отладки на хостовом
> компьютере, а nginx/opencode обращаются к нему через `host.docker.internal:8082`.

### 4.1 Порядок запуска

```bash
cd C:\git\gross-view-infra
cp .env.example .env          # заполнить секреты (не коммитить .env)
docker compose up -d          # поднять всю связку (opencode без depends_on keycloak)
# Регистрация MCP — АВТОМАТИЧЕСКАЯ (OAuth-конфиг пишется entrypoint'ом из .env);
# аутентификация выполняется один раз как РЕАЛЬНЫЙ пользователь:
docker compose exec opencode opencode mcp auth gross-view
#   -> открыть напечатанный authorization URL, залогиниться в Keycloak (роль MCP)
docker compose exec opencode opencode mcp list   # gross-view -> connected
```

### 4.2 Обязательные переменные `.env`

```
OPENCODE_MCP_URL=http://host.docker.internal:8082/api/mcp  # адрес MCP для агента
OPENCODE_MCP_CLIENT_ID=opencode-mcp   # публичный Keycloak-клиент (OAuth PKCE)
OPENCODE_MCP_SCOPE=openid offline_access  # offline-токен (30дн idle); 'openid' → needs_auth
CREDENTIAL_ENCRYPTION_KEY=<32-байтовый base64> # handler падает без него (fail-fast)
```

> **Клиент `opencode-mcp`** в realm: `publicClient: true`,
> `standardFlowEnabled: true`, redirectUris
> `["http://127.0.0.1:19876/mcp/oauth/callback"]`, дефолтные scope включают
> `openid`. OAuth-токены сохраняются в **`~/.local/share/opencode/mcp-auth.json`**
> на основном volume агента (см. манифесты) — переживают рестарт пода.

> **Одноразовая ручная аутентификация** — осознанный tradeoff: headless-окружение
> не может пройти интерактивный OAuth автоматически при старте (как раньше
> авто-генерация `client_credentials`). Запускается вручную после деплоя, токены
> персистентны. Если `mcp-auth.json` потерян (сменён volume) — повторить команду.

### 4.3 Первичная настройка при существующей БД Keycloak

Роли и клиент, добавленные в `gross-view-realm.json`, применяются **только при
свежем импорте** (`start --import-realm`). На работающем Keycloak выполнить один раз:

```bash
KC=/opt/keycloak/bin/kcadm.sh   # внутри контейнера keycloak
./kcadm.sh config credentials --server http://localhost:8080 --realm master \
  --user $KEYCLOAK_ADMIN --password $KEYCLOAK_ADMIN_PASSWORD
# роли (существуют с импорта; при ручной настройке):
./kcadm.sh create roles -r gross-view-realm -s name=MCP -s name=ANALYST -s name=ADMIN
# публичный клиент OAuth для opencode (если ещё нет):
./kcadm.sh create clients -r gross-view-realm \
  -s clientId=opencode-mcp -s publicClient=true -s standardFlowEnabled=true \
  -s 'redirectUris=["http://127.0.0.1:19876/mcp/oauth/callback"]' \
  -s 'webOrigins=["http://127.0.0.1:19876"]' -s 'defaultClientScopes=["openid"]'
# убрать легаси клиент opencode-agent + сервис-аккаунт, если остались:
./kcadm.sh delete clients/<id> -r gross-view-realm  # clientId=opencode-agent
./kcadm.sh delete users/<id>   -r gross-view-realm  # username=service-account-opencode-agent
```

## 5. Операционные шаги для docker

1. Проверить, что пользователь, который будет «владельцем» MCP-аутентификации
   агента, **является членом рабочего пространства** (роль `ANALYST` достаточна
   для финансовых MCP-инструментов; `MCP`/`DESIGNER`/`OZON_IMPORT`/`ADMIN` — для
   доступа к `/api/mcp`). Членство заводится в handler-е через
   `/api/workspaces/.../invitations` или SQL в `workspace_member`.
2. Запустить `./gradlew bootRun` handler-а на хосте (порт 8082) и поднять стек
   (п. 4.1).
3. Выполнить одноразовую OAuth-аутентификацию (`opencode mcp auth gross-view` в
   контейнере или на хосте) и проверить `opencode mcp list` → `gross-view`
   со статусом `connected`; вызвать инструмент (`get_account_plan` и т.п.) — он
   отработает в workspace прошедшего OAuth пользователя.

> **Срок жизни токена.** OAuth refresh-токен обновляется opencode автоматически;
> повторная аутентификация нужна только при потере `mcp-auth.json` или смене
> grant/правил Keycloak. Быстрый способ переподключить MCP — удалить
> `~/.local/share/opencode/mcp-auth.json` и повторить `opencode mcp auth gross-view`.

> **Управление провайдерами моделей** (`POST /api/opencode/providers/{id}/connect`,
> OAuth authorize/callback, `POST /api/opencode/models/sync`) работает через
> тот же throughput (Feign сервера opencode) — минимальных прав не требует; ключи
> провайдеров лежат в persistent volume opencode (см. §4.4).

### 4.4 Управление провайдерами и их ключами

**Основной механизм поступления LLM-ключей — переменные окружения контейнера**
opencode (провайдеры сервера читают их напрямую как учётные данные). Для DeepSeek
`DEEPSEEK_API_KEY` пробрасывается из `.env` инфраструктуры через `docker-compose.yml`
(`environment: DEEPSEEK_API_KEY: ${DEEPSEEK_API_KEY:-}`); `.env.example` содержит
заглушку. После изменения ключа контейнер пересоздаётся:

```bash
docker compose up -d opencode
docker compose exec opencode printenv DEEPSEEK_API_KEY   # контроль
```

Handler дополнительно предоставляет REST-эндпоинты для подключения провайдеров
моделей **в рантайме** (UI/API) — используются как альтернатива env, когда ключ
меняется без пересоздания контейнера или провайдер подключён через OAuth:

- `POST /api/opencode/providers/{id}/connect` — подключение API-ключом
  (`PUT /auth/{id}` на сервере opencode, ключ хранится в конфиг-директории
  сервера `/root/.config/opencode`, не в инфраструктурных Secret);
- `POST /api/opencode/providers/{id}/oauth/authorize|callback` — OAuth-подключение;
- `POST /api/opencode/models/sync` — синхронизация справочника `llm_model`
  от handler-а из каталога сервера (`GET /provider`); флаг `createMissing`
  (по умолчанию — env handler-а `OPENCODE_CATALOG_CREATE_MISSING=false`)
  разрешает создавать неизвестные модели справочника как неактивные;
- `GET /api/opencode/providers|config|providers/auth` — чтение состояния.

Инфраструктурных требований это не добавляет: все вызовы идут через Feign handler-а
(со сквозным JWT пользователя) к внутреннему адресу opencode
(`opencode:4096` / `opencode.gross-view.svc.cluster.local:4096`) и не требуют
новых Secret-ов. Ключи провайдеров, заведённые через runtime-механизм, лежат в
persistent volume (PVC/volume opencode-data) и переживают перезапуск контейнера;
учитывать при бэкапе этого volume. Ключи через env (`DEEPSEEK_API_KEY`)
переживают перезапуски по определению и не попадают в volume — их источник —
`.env`/Secret инфраструктуры.

## 6. План доработок K8s (реализовано, применять при постановке API-деплоя)

1. **Новые манифесты** `k8s/base/gross-view-api-deployment.yaml` +
   `gross-view-api-service.yaml` (Deployment `gross-view-api` + ClusterIP :8082,
   зеркало docker `handler`): image `gross-view.registry.twcstorage.ru/gross-view/gross-view-handler`,
   env: `KEYCLOAK_URL=mint-box.ru`, `POSTGRES_URL=postgres:5432`,
   `DB_USER/DB_PASS` из `gross-view-secrets` (`gv_db_user`/`gv_db_password`),
   `CREDENTIAL_ENCRYPTION_KEY`, `OPENCODE_BASE_URL=http://opencode.gross-view.svc.cluster.local:4096`.
   **Никаких `OPENCODE_SERVER_USERNAME/PASSWORD` у handler-а больше нет** — сервер
   opencode без собственной аутентификации (внутренняя сеть), вызовы идут со
   сквозным JWT. `MCP_URL=https://mint-box.ru/api/mcp`.
   (nginx в K8s **уже** резолвит `gross-view-api.gross-view.svc.cluster.local:8082`)
2. **`kustomization.yaml`**: включить `gross-view-api-*.yaml`;
   раскомментировать `opencode-deployment/service/pvc.yaml` и
   `opencode-entrypoint-configmap.yaml`.
3. **`secret.yaml`**: ✅ сделано — удалены `opencode_server_username`,
   `opencode_server_password`, `keycloak_internal_url`, `opencode_agent_client_id`,
   `opencode_agent_client_secret`. Остаются секреты БД, Keycloak, registry и прочие +
   строки для `credential_encryption_key` и `keycloak_client_secret` (добавятся с
   манифестами API).
4. **`opencode-deployment.yaml`**: ✅ сделано — `initContainer wait-for-keycloak`
   **удалён** (entrypoint больше не получает токен → Keycloak при старте не нужен);
   env без OAuth-credentials (только LLM-ключ `DEEPSEEK_API_KEY` + MCP-конфиг): `BROWSER=none`, `OPENCODE_MCP_URL`
   (`http://gross-view-api…:8082/api/mcp`), `OPENCODE_MCP_CLIENT_ID=opencode-mcp`;
   entrypoint монтируется из ConfigMap `opencode-entrypoint`
   (`opencode-entrypoint-configmap.yaml`, `defaultMode: 0555`, скрипт синхронизирован
   с docker-версией `opencode/entrypoint.sh`); **второй volumeMount**
   `opencode-data → /root/.local/share/opencode` — чтобы OAuth-токены
   (`mcp-auth.json`) переживали рестарт пода.
5. **Токен**: OAuth-токены реального пользователя лежат в `mcp-auth.json` на PVC
   `opencode-data`. Периодическое обновление Secret не нужно. При логине другого
   пользователя — повторить OAuth (или удалить `mcp-auth.json`).
6. **Realm** (общий с docker): роли `MCP`/`ANALYST`/`ADMIN`, публичный клиент
   `opencode-mcp`, конфиденциальный `gross-view-handler-service` + клиент-ресурс
   `mcp` (audience Token Exchange) — импортируются свежим `mint-box.ru`
   realm-импортом; на работающих кластерах — kcadm (см. §4.3). Легаси
   `opencode-agent`/сервис-аккаунт удалены из импорта. Keycloak запускается с
   `--features=token-exchange` (`keycloak-deployment.yaml` → `args`).
7. **Бюджет ресурсов**: handler ≈ 200m CPU / 300–400Mi RAM requests. Ориентир узла
   `~800m / ~1500Mi` будет превышен — поднять узел до 2 CPU или пересмотреть limits.
8. Обновить AGENTS.md (расписание сервисов, таблица ресурсов).

## 7. Связанные файлы handler-а (для справки)

- `controller/McpController.java` — `initialize`/session binding, 401 + `resource_metadata`.
- `config/SecurityConfig.java` — OAuth2 Resource Server, `@PreAuthorize` роли.
- `service/workspace/WorkspaceService.java#resolveWorkspaceId` — членство по JWT.
- `service/integro/opencode/OpenCodeClient.java` — Feign-клиент сервера opencode.
- `config/OpenCodeFeignConfig.java` — RequestInterceptor: **сквозной JWT пользователя**
  (из `SecurityContextHolder`) в `Authorization: Bearer`.
- `service/mcp/OAuthMetadataService.java` — `mcp.url`/issuer-uri (`MCP_URL`, `KEYCLOAK_URL`).