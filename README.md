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
| vault      | 172.28.0.6    | - (internal)   | HashiCorp Vault (источник секретов для ESO) |

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
4. Примените манифесты из корня репозитория — `kubectl apply -k .`. Vault автозапуском засеет `secret/gross-view` dev-плейсхолдерами, ESO создаст из них Secret `gross-view-secrets`. Реальные значения положите в Vault (например: `kubectl -n gross-view exec deploy/vault -- vault kv put secret/gross-view deepseek_api_key=<REAL>`).
5. Если менялась nginx-конфигурация (`k8s/base/nginx-configmap.yaml`) — перезапустите nginx, чтобы подобрать новый конфиг.
6. Выпустите первый Let's Encrypt сертификат для `mint-box.ru`.
7. Проверьте посадочную страницу.

### Реестр контейнеров Timeweb Cloud (Артефактори)

Собственные образы gross-view живут в реестре контейнеров Timeweb Cloud — хост `gross-view.registry.twcstorage.ru`. Токен доступа выдается в панели Timeweb при создании реестра и показывается только один раз (начинается с `registry-`); при потере токен перевыпускается в разделе «API и Terraform». Если указанный при push репозиторий ещё не существует, реестр создаст его автоматически.

Авторизация (логин — любое значение, например имя реестра; пароль — токен из панели):

```bash
docker login gross-view.registry.twcstorage.ru
```

Доступ к приватному реестру из K8s задаётся через `imagePullSecrets`: Deployment ссылается на Secret `gross-view-registry` (см. `k8s/base/gross-view-ui-deployment.yaml`). Секрет создаётся либо командой:

```bash
kubectl -n gross-view create secret docker-registry gross-view-registry \
  --docker-server=gross-view.registry.twcstorage.ru \
  --docker-username=gross-view \
  --docker-password=<REGISTRY_TOKEN>
```

либо автоматически при подключении реестра к кластеру в панели Timeweb (вкладка «Управление» кластера) — тогда имя созданного секрета может отличаться, поправьте его в `imagePullSecrets`.

**Диагностика ошибки `401 Unauthorized` при pull (2026-09-13).** Симптом: под gross-view-ui в `ImagePullBackOff`, событие пода `Failed to pull image "...": failed to fetch anonymous token ... api.timeweb.cloud/api/v1/k8s/cr-auth ...: 401 Unauthorized`. Причина — Secret `gross-view-registry` не создан в кластере (kubelet тянет образ без кред), не путать с неверным токеном. Проверка: `kubectl -n gross-view get secrets` — секрета нет, и в событиях пода есть `FailedToRetrieveImagePullSecret ... Unable to retrieve some image pull secrets (gross-view-registry)`. Лечится созданием секрета командой выше (`kubectl create secret docker-registry gross-view-registry ...`). Имя секрета должно ровно совпадать со значением `imagePullSecrets` в `k8s/base/gross-view-ui-deployment.yaml`.

### Push образа gross-view-ui в кластер

Кластер забирает образ `gross-view.registry.twcstorage.ru/gross-view/gross-view-ui:latest` **напрямую из реестра Timeweb Cloud** (см. `k8s/base/gross-view-ui-deployment.yaml`). Образ собирается из репозитория `../gross-view-ui` (nginx:stable-alpine + собранный `dist/`). Публикация образа в кластер = push в реестр Timeweb:

```bash
docker push gross-view.registry.twcstorage.ru/gross-view/gross-view-ui:latest
```

Дальше кластер «сам подхватывает» обновление: под разворачивается с `imagePullPolicy: Always` (тег `:latest`), потому после push достаточно перезапустить Deployment, чтобы новый под затянул свежий образ:

```bash
kubectl -n gross-view rollout restart deployment/gross-view-ui
```

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

Соответствие сервисов: postgres → StatefulSet, keycloak → Deployment, nginx → Deployment + LoadBalancer (80/443, TLS-терминация для mint-box.ru), gross-view-ui → Deployment + ClusterIP (статическая SPA-посадочная страница, образ `gross-view.registry.twcstorage.ru/gross-view/gross-view-ui:latest`, pull через `imagePullSecrets` → Secret `gross-view-registry`), opencode → Deployment, certbot → CronJob (Let's Encrypt, HTTP-01/webroot, ежедневное обновление → Secret `mint-box-tls` + рестарт nginx). Тема и realm Keycloak встраиваются в ConfigMap через `configMapGenerator` в корневом `kustomization.yaml`. Требуются DNS-записи `mint-box.ru`/`www.mint-box.ru` на внешний IP ноды и доступный порт 80.

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