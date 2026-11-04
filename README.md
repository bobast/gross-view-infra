# gross-view-keycloak

## Инфраструктура gross-view

Docker Compose стек для gross-view: PostgreSQL (TimescaleDB), Keycloak, Nginx, opencode.

## Быстрый старт

```bash
cp .env.example .env                              # или создайте .env, заполнив необходимые переменные
./scripts/generate-self-signed-cert.sh            # самоподписанный сертификат для gross-view.local → certs/
sudo ./scripts/install-cert-system-trust.sh       # доверие к нему на хосте (curl/браузер/JVM)
docker-compose up -d
```

### Запись в `/etc/hosts` (обязательно)

nginx публикует порты 80/443 на хост, поэтому ОС должна резолвить домен в loopback.
Без этой записи браузер и `curl` не найдут `https://gross-view.local`:

```bash
echo "127.0.0.1  gross-view.local" | sudo tee -a /etc/hosts
getent hosts gross-view.local     # проверка: должен вернуть 127.0.0.1
```

Имя должно быть ровно `gross-view.local` — оно же в `server_name` nginx и в SAN сертификата,
поэтому опечатка в hosts даст «неизвестный хост» и ошибку TLS. Внутри сети контейнеров резолв
отдельный: opencode получает `gross-view.local → 172.28.0.4` через `extra_hosts` в
`docker-compose.yml`, nginx — встроенный DNS docker (`127.0.0.11`). Запись в hosts нужна только
хосту (браузер, `curl`, локальный запуск handler на `host.docker.internal`).

### TLS-сертификат для `gross-view.local`

nginx в docker-compose терминирует TLS самоподписанным сертификатом из каталога `certs/`
(он целиком монтируется в контейнер как `/etc/nginx/certs`, пути заданы в `nginx/gross-view.local.conf`):

| Файл                              | Кто использует                                                                 |
|-----------------------------------|--------------------------------------------------------------------------------|
| `certs/gross-view.local.crt`       | nginx (`ssl_certificate`), opencode (`NODE_EXTRA_CA_CERTS`), handler (JVM truststore) |
| `certs/gross-view.local.key`       | nginx (`ssl_certificate_key`)                                                   |

```bash
./scripts/generate-self-signed-cert.sh            # сгенерировать, если файла нет / срок истекает
./scripts/generate-self-signed-cert.sh --force    # принудительно перевыпустить
```

⚠️ Файлы `.crt`/`.key` должны существовать **до** `docker-compose up` — иначе nginx упадёт с
`cannot load certificate … No such file or directory`. Каталог `certs/` смонтирован **целиком**
(и в nginx, и в opencode) — монтировать отдельный `.crt` файлом нельзя: docker создаёт
отсутствующий источник bind-mount как **каталог** (от root), и nginx после этого падает с
`cannot load certificate … Is a directory`. Если такой каталог появился, удалите его
(`sudo rm -rf certs/gross-view.local.crt`) и перегенерируйте сертификат.

Сертификат самоподписанный **и** помечен `CA:TRUE`, поэтому `.crt` работает как собственный
корневой сертификат — его достаточно положить в `NODE_EXTRA_CA_CERTS` (opencode) и импортировать
в JVM-truststore (`handler/entrypoint.sh`), отдельный CA-файл не нужен. SAN:
`gross-view.local`, `localhost`, `host.docker.internal`, `127.0.0.1`, `172.28.0.4` (IP контейнера nginx).

После перевыпуска нужно пересоздать потребителей (они пиннят файл/монтирование при создании контейнера):

```bash
docker-compose up -d nginx      # подхватить новый сертификат
docker-compose up -d opencode   # пересоздать: новая CA через NODE_EXTRA_CA_CERTS
```

Предупреждения браузера/JVM о самоподписанном издателе — ожидаемы для локального окружения
(для host-консоли см. следующий раздел — его можно убрать установкой сертификата в системное хранилище).

### Доверие к сертификату на хосте (curl, git, браузер, JVM)

Самоподписанный сертификат нужно один раз положить в **системное хранилище доверенных сертификатов
хоста** — иначе `curl`/`git`/`node`/`python` и браузер на хосте получают
`SSL certificate problem: self-signed certificate`. Контейнеры при этом не меняются: nginx,
opencode (`NODE_EXTRA_CA_CERTS`) и handler (JVM truststore) читают `certs/` напрямую.

```bash
sudo apt install libnss3-tools        # certutil для Firefox/Chrome на Linux (NSS db), опционально
sudo ./scripts/install-cert-system-trust.sh            # system store (+ NSS db, если есть certutil)
sudo ./scripts/install-cert-system-trust.sh --jvm      # + JDK cacerts (для handler в режиме отладки)
sudo ./scripts/install-cert-system-trust.sh --uninstall   # убрать из всех хранилищ
```

| Хранилище                        | Что чинит                              |
|----------------------------------|----------------------------------------|
| `/usr/local/share/ca-certificates/` → `update-ca-certificates` | `curl`, `git`, `node`, `python`, `wget` (через `/etc/ssl/certs/ca-certificates.crt`) |
| `~/.pki/nssdb` (через `certutil`) | Firefox ESR и Chrome/Chromium на Linux — без `libnss3-tools` браузер останется недоверенным |
| JDK `cacerts` (`--jvm`)          | host-handler в режиме отладки (Spring Boot) — JVM системное хранилище не читает |

Скрипт идемпотентен, поддерживает Debian/Ubuntu (`update-ca-certificates`) и RHEL/Fedora
(`update-ca-trust`), печатает fingerprint и проверяет результат (`openssl verify` + живой
TLS-хендшейк с `https://gross-view.local:443`). После каждого перевыпуска сертификата
(`generate-self-signed-cert.sh --force`) скрипт надо запустить заново — хранилища пиннят старый
сертификат.

## Сервисы

| Сервис     | IP (внутрен.) | Порты (внешн.) | Описание                                  |
|------------|---------------|----------------|-------------------------------------------|
| postgres   | 172.28.0.2    | 5432           | Основная БД (TimescaleDB)                 |
| keycloak   | 172.28.0.3    | 8080           | SSO / Identity Provider                   |
| nginx      | 172.28.0.4    | 80, 443        | Reverse proxy (входная точка /sso, /api, /)|
| opencode   | 172.28.0.5    | 4096           | AI coding agent (web UI)                  |

> Vault в docker-compose **удалён (2026-10-19)** — он работает только в Kubernetes
> (`k8s/base/vault-*.yaml`, ClusterIP `vault.gross-view.svc.cluster.local:8200`).

Внутренняя подсеть: `172.28.0.0/24` (bridge, keycloak_network).

У всех сервисов `restart: always`, поэтому после загрузки хоста (или `systemctl restart docker`)
стек поднимается автоматически — ручной `docker-compose up -d` нужен только при первом запуске
или после изменения самого `docker-compose.yml` (политика рестарта фиксируется при создании
контейнера; для уже созданных контейнеров — `docker-compose up -d` либо
`docker update --restart=always <container>`).

## Переменные окружения (.env)

Обязательные:

```dotenv
POSTGRES_DB_NAME=
POSTGRES_DB_USER=
POSTGRES_DB_PSWD=

KC_DB_NAME=
KC_DB_USER=
KC_DB_PSWD=

GV_DB_NAME=
GV_DB_USER=
GV_DB_PSWD=

KEYCLOAK_ADMIN=
KEYCLOAK_ADMIN_PASSWORD=
```

`.env` и `certs/` в `.gitignore` — не коммитьте их.

## Деплой в K8s

Готовые манифесты для деплоя в Kubernetes находятся в `k8s/` (зеркало docker-compose стека).

Порядок деплоя:

1. Установите ESO-оператор (out-of-band, namespace `external-secrets`, server-side apply) — см. note про ESO в AGENTS.md. Без него `kubectl apply -k .` упадёт на неизвестных CRD.
2. Создайте pull-secret `gross-view-registry` для доступа к реестру контейнеров (или подключите реестр к кластеру в панели Timeweb).
3. Соберите и запушьте образ посадочной страницы `gross-view.registry.twcstorage.ru/gross-view/gross-view-ui:latest` (манифесты ссылаются на него).
4. Примените манифесты из корня репозитория — `kubectl apply -k .`. Vault автозапуском засеет `secret/gross-view` dev-плейсхолдерами, ESO создаст из них Secret `gross-view-secrets`. Реальные значения положите в Vault — для LLM-ключей через `./scripts/rotate-llm-key.sh` (см. подраздел «Ротация LLM-ключей» ниже: запись в Vault сама по себе до пода не доедет).
5. Если менялась nginx-конфигурация (`k8s/base/nginx-configmap.yaml`) — перезапустите nginx, чтобы подобрать новый конфиг.
6. Выпустите первый Let's Encrypt сертификат для `mint-box.ru`.
7. Проверьте посадочную страницу.

### Ротация LLM-ключей (DeepSeek и др.)

Ключи провайдеров живут в Vault (`secret/gross-view`, свойства `<provider>_api_key`),
ESO переносит их в Secret `gross-view-secrets`, а opencode читает их как env
`<PROVIDER>_API_KEY`. Между записью в Vault и реальным применением **три pull-стадии**,
и каждая молча оставляет старое значение:

1. ESO синхронизирует Vault → Secret только по `refreshInterval: 1h` или по аннотации `force-sync`;
2. `secretKeyRef` фиксируется при **создании** контейнера — обновление Secret не меняет env уже работающего пода;
3. изменение Secret не триггерит rollout Deployment (в `k8s/base/opencode-deployment.yaml` для этого есть аннотация `gross-view/secret-version` — её бампают при ручной правке).

Симптом «ключ в Vault есть, а модель отвечает `401 Authentication Fails, Your api key: ****_KEY is invalid`»
(диагноз 2026-10-27) — это шаг 2/3: в поде остался bootstrap-плейсхолдер, а DeepSeek показывает
последние 4 символа ключа (`_KEY` — хвост `REPLACE_WITH_DEEPSEEK_API_KEY`).

Одна команда делает всё (Linux/bash):

```bash
# ключ из переменной окружения — не попадает в history и в argv
DEEPSEEK_API_KEY='sk-...' ./scripts/rotate-llm-key.sh deepseek --from-env
./scripts/rotate-llm-key.sh --list      # состояние всех провайдеров + дрейф env относительно Secret
```

Скрипт: `vault kv patch` (значение читается из stdin, RTOKEN берётся из `/vault/data/init.json` пода
или `VAULT_TOKEN`) → `force-sync` на `ExternalSecret` → ожидание нового значения в Secret →
`rollout restart deployment/opencode` → проверка env в новом поде. Флаги: `--dry-run`,
`--skip-restart`, `--timeout <sec>`; провайдеры: `deepseek openai anthropic openrouter google groq mistral xai`.

Вручную (Windows/PowerShell, без скрипта):

```powershell
kubectl -n gross-view exec deploy/vault -c vault -- vault kv patch secret/gross-view deepseek_api_key=<REAL>
kubectl -n gross-view annotate externalsecret gross-view-secrets "force-sync=$(Get-Date -UFormat %s)" --overwrite
kubectl -n gross-view get secret gross-view-secrets -o jsonpath='{.data.deepseek_api_key}'   # новый ключ доехал?
kubectl -n gross-view rollout restart deployment/opencode
kubectl -n gross-view rollout status deployment/opencode
```

Проверка: `kubectl -n gross-view exec deploy/opencode -- printenv DEEPSEEK_API_KEY` возвращает новый
ключ (не пусто и не `REPLACE_WITH_…`). Запись ключа в Vault без `force-sync` и без рестарта пода —
самая частая причина «ключ указан, но не применяется». Entrypoint opencode при старте пишет
`WARN: <VAR> still holds a placeholder …`, если видит плейсхолдер, — это тот же диагноз в логах пода.

⚠️ **Рестарт opencode сбрасывает MCP-регистрации.** Сервер `gross-view-<workspaceId>-<userHash>`
создаётся handler-ом динамически (`POST /mcp`) и не персистится агентом, поэтому после любого
пересоздания пода панель ассистента может показать «MCP-серверы не обнаружены». С 2026-10-27 handler
сверяется с агентом в `McpSessionCredentialService.prepare()` и регистрирует сервер заново на первом
же запросе (перезагрузите страницу ассистента). На образе handler-а без этой правки помогает
`kubectl -n gross-view rollout restart deployment/gross-view-api`.

### VPN-доступ к postgres и vault (k8s)

Внутренние сервисы кластера (PostgreSQL, Vault) не публикуются наружу. Для
разработчика с ноутбука есть WireGuard-шлюз `vpn-gateway`: UDP-порт узла.
Внутри туннеля nginx-stream-прокси (`vpn-gateway-proxy-configmap.yaml` +
контейнер `proxy`) публикует порты `10.2.2.3:15432` (postgres) и
`10.2.2.3:18200` (vault); прокси-слой был удалён 2026-10-07 и восстановлен
2026-10-08. С 2026-10-09 адрес wg0 — `10.2.2.3/24` (ранее `10.13.13.1/24`).

```bash
./scripts/vpn-init.sh                 # ключи сервера -> Secret vpn-gateway-keys
./scripts/vpn-peer.sh add ivan        # конфиг ivan.conf -> ./vpn/ (0600, в git не попадает)
kubectl apply -k .
# подхват peer-ов/ConfigMap — только рестартом пода. С 2026-10-06 у Deployments
# `strategy: Recreate`, поэтому обычный rollout restart безопасен (не зависает
# на hostPort):
kubectl -n gross-view rollout restart deployment/vpn-gateway
```

На ноутбуке: `wg-quick up` → `sudo wg show` (проверка handshake). Команды
`psql -h 10.2.2.3 -p 15432` и Vault `http://10.2.2.3:18200` работают после
пересборки пода с восстановленным прокси-слоем. Полный план, обоснование и меры
безопасности — [docs/vpn-access-k8s.md](docs/vpn-access-k8s.md).

### Реестр контейнеров Timeweb Cloud (Артефактори)

Собственные образы gross-view живут в реестре контейнеров Timeweb Cloud — хост `gross-view.registry.twcstorage.ru`. Токен доступа выдается в панели Timeweb при создании реестра и показывается только один раз (начинается с `registry-`); при потере токен перевыпускается в разделе «API и Terraform». Если указанный при push репозиторий ещё не существует, реестр создаст его автоматически.

Авторизация (логин — любое значение, например имя реестра; пароль — токен из панели):

```bash
docker login gross-view.registry.twcstorage.ru
```

Доступ к приватному реестру из K8s задаётся через `imagePullSecrets`: Deployment ссылается на Secret `gross-view-registry` (см. `k8s/base/gross-view-ui-deployment.yaml` и `k8s/base/gross-view-api-deployment.yaml`). Секрет создаётся либо командой:

```bash
kubectl -n gross-view create secret docker-registry gross-view-registry \
  --docker-server=gross-view.registry.twcstorage.ru \
  --docker-username=gross-view \
  --docker-password=<REGISTRY_TOKEN>
```

либо автоматически при подключении реестра к кластеру в панели Timeweb (вкладка «Управление» кластера) — тогда имя созданного секрета может отличаться, поправьте его в `imagePullSecrets`.

**Диагностика ошибки `401 Unauthorized` при pull (2026-09-13).** Симптом: под gross-view-ui в `ImagePullBackOff`, событие пода `Failed to pull image "...": failed to fetch anonymous token ... api.timeweb.cloud/api/v1/k8s/cr-auth ...: 401 Unauthorized`. Причина — Secret `gross-view-registry` не создан в кластере (kubelet тянет образ без кред), не путать с неверным токеном. Проверка: `kubectl -n gross-view get secrets` — секрета нет, и в событиях пода есть `FailedToRetrieveImagePullSecret ... Unable to retrieve some image pull secrets (gross-view-registry)`. Лечится созданием секрета командой выше (`kubectl create secret docker-registry gross-view-registry ...`). Имя секрета должно ровно совпадать со значением `imagePullSecrets` в `k8s/base/gross-view-ui-deployment.yaml` и `k8s/base/gross-view-api-deployment.yaml`.

### Push образа gross-view-ui в кластер

Кластер забирает образ `gross-view.registry.twcstorage.ru/gross-view/gross-view-ui:latest` **напрямую из реестра Timeweb Cloud** (см. `k8s/base/gross-view-ui-deployment.yaml`). Образ собирается из репозитория `../gross-view-ui` (nginx:stable-alpine + собранный `dist/`). Публикация образа в кластер = push в реестр Timeweb:

```bash
docker push gross-view.registry.twcstorage.ru/gross-view/gross-view-ui:latest
```

Дальше кластер «сам подхватывает» обновление: под разворачивается с `imagePullPolicy: Always` (тег `:latest`), потому после push достаточно перезапустить Deployment, чтобы новый под затянул свежий образ:

```bash
kubectl -n gross-view rollout restart deployment/gross-view-ui
```

### Push и ролл-аут образа gross-view-handler (K8s)

Бэкенд `gross-view-api` использует образ `gross-view.registry.twcstorage.ru/gross-view/gross-view-handler:latest`
(`k8s/base/gross-view-api-deployment.yaml`); образ собирается из соседнего репозитория `../gross-view-handler`.
Публикация = push в реестр Timeweb, а подхват нового образа = **перезапуск Deployment**: `imagePullPolicy: Always`
заставляет kubelet заново сходить в реестр при создании контейнера.

```bash
cd ../gross-view-handler
docker build -t gross-view.registry.twcstorage.ru/gross-view/gross-view-handler:latest .
docker push gross-view.registry.twcstorage.ru/gross-view/gross-view-handler:latest

kubectl -n gross-view rollout restart deployment/gross-view-api
kubectl -n gross-view rollout status deployment/gross-view-api
```

То же в PowerShell (`Set-Location` + те же команды):

```powershell
Set-Location ..\gross-view-handler
docker build -t gross-view.registry.twcstorage.ru/gross-view/gross-view-handler:latest .
docker push gross-view.registry.twcstorage.ru/gross-view/gross-view-handler:latest

kubectl -n gross-view rollout restart deployment/gross-view-api
kubectl -n gross-view rollout status deployment/gross-view-api
```

Проверка, что запустился именно новый образ (у тега `:latest` меняется только digest):

```bash
kubectl -n gross-view get pod -l app.kubernetes.io/name=gross-view-api \
  -o jsonpath='{.items[0].status.containerStatuses[0].imageID}{"\n"}'
```

⚠️ `kubectl apply -k .` ролл-аут **не запускает**: шаблон пода в манифесте не меняется, поэтому Deployment
остаётся прежним и под не пересоздаётся — нужен явный `rollout restart`.

⚠️ У `gross-view-api` `strategy: Recreate` (Liquibase на старте не должен идти с двух подов одновременно),
поэтому во время ролл-аута `/api` недоступен, пока новый под не пройдёт `startupProbe` (до ~5 минут холодного
старта Spring Boot). `revisionHistoryLimit: 2` (единственный Deployment с ненулевым значением) позволяет
`kubectl -n gross-view rollout undo deployment/gross-view-api`, но при теге `:latest` откат вернёт только
предыдущий шаблон, не предыдущий образ — для настоящего отката публикуйте версионированный тег и меняйте
`image:` в манифесте.

Команды для Linux и Windows даны ниже; каждая команда — в отдельном блоке для удобного копирования.

### Linux (bash)

Команды выполняются из корня репозитория `gross-view-infra`, если явно не указан другой каталог.

**1. Секреты** — секретов в манифестах нет, источник истины — Vault. После первого `kubectl apply -k .` Vault сам засеет путь `secret/gross-view` dev-плейсхолдерами, ESO создаст Secret `gross-view-secrets`. Реальные значения записываются в Vault:

```bash
kubectl -n gross-view exec deploy/vault -- vault kv put secret/gross-view <key>=<REAL_VALUE>
```

**2. Pull-secret для реестра Timeweb** (токен `registry-...` из панели):

```bash
kubectl -n gross-view create secret docker-registry gross-view-registry \
  --docker-server=gross-view.registry.twcstorage.ru \
  --docker-username=gross-view \
  --docker-password=<REGISTRY_TOKEN>
```

**3. Установка зависимостей и сборка gross-view-ui** (каталог `../gross-view-ui`):

```bash
cd ../gross-view-ui && npm ci && npm run build
```

**4. Сборка docker-образа** (каталог `../gross-view-ui`):

```bash
cd ../gross-view-ui && docker build -t gross-view.registry.twcstorage.ru/gross-view/gross-view-ui:latest .
```

**5. Авторизация в реестре** (логин — любое значение, пароль — токен из панели):

```bash
docker login gross-view.registry.twcstorage.ru
```

**6. Push образа в реестр** (это и есть «push в кластер»):

```bash
docker push gross-view.registry.twcstorage.ru/gross-view/gross-view-ui:latest
```

**7. Применение манифестов** (корень репозитория):

```bash
kubectl apply -k .
```

**8. Обновление пода gross-view-ui** (затянет свежий `:latest`):

```bash
kubectl -n gross-view rollout restart deployment/gross-view-ui
```

**9. Перезапуск nginx** — только если менялась nginx-конфигурация (`k8s/base/nginx-configmap.yaml`). На одной ноде может понадобиться `scale` до 0 и обратно (см. AGENTS.md):

```bash
kubectl -n gross-view rollout restart deployment/nginx
```

**10. Первый Let's Encrypt сертификат** (nginx init-контейнер уже создал self-signed placeholder Secret `mint-box-tls`; certbot заменит его на реальный):

```bash
kubectl create job --from=cronjob/certbot certbot-bootstrap -n gross-view
```

```bash
kubectl logs -f job/certbot-bootstrap -n gross-view
```

**11. Проверка посадочной страницы:**

```bash
curl -I https://mint-box.ru
```

### Windows (PowerShell)

В PowerShell `&&` не поддерживается (PowerShell 5.1), поэтому команды выполняются по одной — каждый блок можно копировать отдельно. В PowerShell `curl` — это алиас `Invoke-WebRequest` (для `-I` ведёт себя неверно), используйте `curl.exe`.

**1. Секреты** — секретов в манифестах нет, источник истины — Vault. После первого `kubectl apply -k .` Vault сам засеет путь `secret/gross-view` dev-плейсхолдерами, ESO создаст Secret `gross-view-secrets`. Реальные значения записываются в Vault:

```bash
kubectl -n gross-view exec deploy/vault -- vault kv put secret/gross-view <key>=<REAL_VALUE>
```

**2. Pull-secret для реестра Timeweb** (токен `registry-...` из панели):

```powershell
kubectl -n gross-view create secret docker-registry gross-view-registry --docker-server=gross-view.registry.twcstorage.ru --docker-username=gross-view --docker-password=<REGISTRY_TOKEN>
```

**3. Установка зависимостей и сборка gross-view-ui** — перейдите в каталог репозитория UI:

```powershell
Set-Location ..\gross-view-ui
```

```powershell
npm ci
```

```powershell
npm run build
```

**4. Сборка docker-образа** (по-прежнему в каталоге `gross-view-ui`):

```powershell
docker build -t gross-view.registry.twcstorage.ru/gross-view/gross-view-ui:latest .
```

**5. Авторизация в реестре** (логин — любое значение, пароль — токен из панели):

```powershell
docker login gross-view.registry.twcstorage.ru
```

**6. Push образа в реестр** (это и есть «push в кластер»):

```powershell
docker push gross-view.registry.twcstorage.ru/gross-view/gross-view-ui:latest
```

**7. Применение манифестов** — вернитесь в корень репозитория `gross-view-infra`:

```powershell
Set-Location ..\gross-view-infra
```

```powershell
kubectl apply -k .
```

**8. Обновление пода gross-view-ui** (затянет свежий `:latest`):

```powershell
kubectl -n gross-view rollout restart deployment/gross-view-ui
```

**9. Перезапуск nginx** — только если менялась nginx-конфигурация (`k8s/base/nginx-configmap.yaml`). На одной ноде может понадобиться `scale` до 0 и обратно (см. AGENTS.md):

```powershell
kubectl -n gross-view rollout restart deployment/nginx
```

**10. Первый Let's Encrypt сертификат** (nginx init-контейнер уже создал self-signed placeholder Secret `mint-box-tls`; certbot заменит его на реальный):

```powershell
kubectl create job --from=cronjob/certbot certbot-bootstrap -n gross-view
```

```powershell
kubectl logs -f job/certbot-bootstrap -n gross-view
```

**11. Проверка посадочной страницы:**

```powershell
curl.exe -I https://mint-box.ru
```

Соответствие сервисов: postgres → StatefulSet, keycloak → Deployment, nginx → Deployment + LoadBalancer (80/443, TLS-терминация для mint-box.ru), gross-view-ui → Deployment + ClusterIP (статическая SPA-посадочная страница, образ `gross-view.registry.twcstorage.ru/gross-view/gross-view-ui:latest`, pull через `imagePullSecrets` → Secret `gross-view-registry`), gross-view-api → Deployment + ClusterIP (бэкенд `gross-view-handler`, образ `gross-view.registry.twcstorage.ru/gross-view/gross-view-handler:latest`, ролл-аут после push — `rollout restart deployment/gross-view-api`, см. раздел «Push и ролл-аут образа gross-view-handler»), mail → Deployment + hostPort 25/465/587/993 (Stalwart, почта в PostgreSQL, TLS из certbot; внутренний SMTP для Keycloak — `mail:2525`), opencode → Deployment, certbot → CronJob (Let's Encrypt, HTTP-01/webroot, ежедневное обновление → Secret `mint-box-tls`/`mail-tls` + рестарт nginx/mail). Тема и realm Keycloak встраиваются в ConfigMap через `configMapGenerator` в корневом `kustomization.yaml`. Требуются DNS-записи `mint-box.ru`/`www.mint-box.ru` на внешний IP ноды и доступный порт 80.

## Почтовый сервис (Stalwart)

В namespace `gross-view` работает Stalwart `v1.0.2` (`k8s/base/mail-*.yaml`). Он принимает почту для домена `mint-box.ru`, отдаёт IMAP/SMTP и используется Keycloak для писем подтверждения регистрации. Ящики: `gi.pavlov@mint-box.ru` (администратор, aliases `postmaster@`, `abuse@`, `dmarc@`) и `no.reply@mint-box.ru` (только для отправки уведомлений).

Почтовые данные и тела писем хранятся в существующем PostgreSQL: база `stalwart`, пользователь `stalwart`. Отдельного PVC для почты нет; pod использует только `emptyDir` для кэшей. Пароль БД лежит в Vault (`secret/gross-view/stalwart_db_password`), пароли ящиков — в `secret/mail` → Secret `mail-secrets`. Бэкапы пока не настроены: потеря PVC `postgres-data-postgres-0` означает потерю почты (и Keycloak/БД).

### DNS и PTR

Обязательные записи:

```text
mx.mint-box.ru.              A      200.165.239.108
mint-box.ru.                 MX 10  mx.mint-box.ru.
mint-box.ru.                 TXT    "v=spf1 ip4:200.165.239.108 -all"
_dmarc.mint-box.ru.          TXT    "v=DMARC1; p=none; rua=mailto:dmarc@mint-box.ru"
mail._domainkey.mint-box.ru. TXT    "v=DKIM1; k=rsa; h=sha256; p=<RSA_PUBLIC_KEY>"
```

DKIM-ключ один — RSA с селектором `mail`. Управление DKIM переведено в ручной режим, автоматическая ротация отключена: иначе Stalwart периодически генерировал бы новые селекторы, а публиковать их в DNS пришлось бы вручную. Ed25519-подпись отключена, потому что часть приёмников (например, Port25) не поддерживает `ed25519-sha256` и показывает `permerror`; на доставляемость это не влияет, но чистая проверка лучше. Значения DKIM удобно смотреть в админке Stalwart (`Settings → Domains → mint-box.ru → Zone File`) или через `stalwart-cli get Domain <id>`.

**Важно:** MX должен указывать на имя `mx.mint-box.ru`, а не на IP-адрес. MX с IP в качестве target невалиден. PTR настраивается не в DNS, а в панели Timeweb: «Сети → Публичные IP → 200.165.239.108 → PTR» → `mx.mint-box.ru`.

### Порты и доступ

- 25/tcp — входящая почта (MX);
- 465/tcp — SMTPS;
- 587/tcp — submission (STARTTLS, AUTH);
- 993/tcp — IMAPS;
- 2525/tcp — только внутри кластера (ClusterIP), cleartext SMTP для Keycloak; AUTH разрешён только на этом порту;
- 8080/tcp — админка/health, только внутри кластера; снаружи доступна через VPN-шлюз на `10.2.2.3:18080` (см. ниже).

Админка доступна двумя способами:

```text
# через VPN (тот же шлюз, что Vault):
http://10.2.2.3:18080/admin

# либо локально:
kubectl -n gross-view port-forward svc/mail 18080:8080
http://127.0.0.1:18080/admin
```

Логи Stalwart пишутся в файл внутри pod:

```bash
kubectl -n gross-view exec deploy/mail -- tail -f /var/log/stalwart/stalwart.log.$(date +%F)
```

### TLS

Certbot CronJob выпускает отдельный сертификат для `mx.mint-box.ru` и обновляет Secret `mail-tls`; после обновления Secret почтовый Deployment перезапускается. Реальный сертификат Let's Encrypt уже выпущен 2026-11-04 и действует до 2027-02-02 (self-signed был только временным bootstrap-решением). При необходимости ручного выпуска/перевыпуска:

```bash
kubectl -n gross-view create job --from=cronjob/certbot certbot-mail-bootstrap
kubectl -n gross-view logs -f job/certbot-mail-bootstrap
```

Проверка:

```bash
openssl s_client -connect 200.165.239.108:993 -servername mx.mint-box.ru -brief
```

### Keycloak SMTP

Живой realm `gross-view-realm` настроен на `mx.mint-box.ru:587` со STARTTLS, отправитель `no.reply@mint-box.ru`, reply-to `gi.pavlov@mint-box.ru`. Пароль хранится в Vault (`secret/mail/noreply_password`), в `gross-view-realm.json` он не коммитится — после импорта realm на свежем кластере SMTP-пароль нужно задать вручную через admin console/`kcadm.sh`.

Внутренний `mail.gross-view.svc.cluster.local:2525` (без TLS, AUTH разрешён только на этом порту) остаётся запасным вариантом на случай проблем с внешним DNS/сертификатом.

## Структура

```
├── docker-compose.yml
├── kustomization.yaml          # K8s: theme + realm ConfigMaps
├── k8s/base/                   # K8s-манифесты (Namespace, Secrets, workload, nginx, certbot)
├── .env
├── nginx/
│   └── gross-view.local.conf
├── postgres/
│   └── init/
├── themes/
│   └── gross-view/
└── gross-view-realm.json
```
```
cat /vault/data/init.json
```

