# gross-view-keycloak

## Инфраструктура gross-view

Docker Compose стек для gross-view: PostgreSQL (TimescaleDB), Keycloak, Nginx, opencode.

## Быстрый старт

```bash
cp .env.example .env   # или создайте .env, заполнив необходимые переменные
docker-compose up -d
```

## Сервисы

| Сервис     | IP (внутрен.) | Порты (внешн.) | Описание                                  |
|------------|---------------|----------------|-------------------------------------------|
| postgres   | 172.28.0.2    | - (internal)   | Основная БД (TimescaleDB)                  |
| keycloak   | 172.28.0.3    | - (internal)   | SSO / Identity Provider                   |
| nginx      | 172.28.0.4    | 80, 443        | Reverse proxy (входная точка /sso, /api, /)|
| opencode   | 172.28.0.5    | 4096           | AI coding agent (web UI)                  |

Внутренняя подсеть: `172.28.0.0/24` (bridge, keycloak_network).

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

DEEPSEEK_API_KEY=
```

`.env` и `certs/` в `.gitignore` — не коммитьте их.

## Деплой в K8s

Готовые манифесты для деплоя в Kubernetes находятся в `k8s/` (зеркало docker-compose стека).

Порядок деплоя:

1. Заполните секреты в `k8s/base/secret.yaml` (замените `changeme` на реальные значения; не коммитьте их).
2. Создайте pull-secret `gross-view-registry` для доступа к реестру контейнеров (или подключите реестр к кластеру в панели Timeweb).
3. Соберите и запушьте образ посадочной страницы `gross-view.registry.twcstorage.ru/gross-view/gross-view-ui:latest` (манифесты ссылаются на него).
4. Примените манифесты из корня репозитория — `kubectl apply -k .`.
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

**1. Секреты** — отредактируйте `k8s/base/secret.yaml`, замените `changeme` на реальные значения.

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

**10. Первый Let's Encrypt сертификат** (nginx-под не поднимется, пока не создан Secret `mint-box-tls`):

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

**1. Секреты** — отредактируйте `k8s/base/secret.yaml`, замените `changeme` на реальные значения.

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

**10. Первый Let's Encrypt сертификат** (nginx-под не поднимется, пока не создан Secret `mint-box-tls`):

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