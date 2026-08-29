# gross-view-keycloak

## Инфраструктура gross-view

Docker Compose стек для gross-view: PostgreSQL (TimescaleDB), Keycloak, Nginx, n8n, плюс сервисы инфраструктуры — Tailscale (VPN), Vault (секреты), DNS (dnsmasq).

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
| n8n        | 172.28.0.5    | - (internal)   | Workflow automation                       |
| wireguard  | 172.28.0.6    | 51820 (udp)    | VPN-доступ к внутренним сервисам          |
| vault      | 172.28.0.7    | 8200           | Хранилище секретов                        |
| dns        | 172.28.0.8    | 53 (tcp/udp)   | Внутренний DNS (dnsmasq)                  |

Внутренняя подсеть: `172.28.0.0/24` (bridge, keycloak_network).

## WireGuard (VPN)

Обеспечивает безопасный доступ к внутренним сервисам (Postgres, Keycloak admin, n8n) без их публикации наружу. Используется [linuxserver/wireguard](https://docs.linuxserver.io/images/docker-wireguard/) в режиме сервера.

### Настройка

1. Укажите публичный IP или домен Docker-хоста в `.env`:
   ```
   WG_SERVERURL=185.12.34.56   # или ваш домен; "auto" — определить автоматически
   WG_PEERS=5                  # число клиентов (или список имён: myPC,myPhone,...)
   ```
2. Поднимите стек. При первом старте контейнер сгенерирует серверный ключ и конфиги для всех `WG_PEERS`.
3. Соберите клиентские конфиги клиентов (текстовые и QR-коды):
   - Лог контейнера: `docker logs wireguard` (при `LOG_CONFS=true`),
   - Файлы: `docker exec -it wireguard cat /config/peer1/peer1.conf` (файлы `peerX.conf` и QR-коды `.png` лежат в `/config/peerX`).
4. Импортируйте конфиг в клиент WireGuard (Windows/macOS/iOS/Android/классический Linux).

### Доступ к внутренним сервисам (split tunneling)

Клиентам раздаются только внутренние подсети (`172.28.0.0/24` и адрес WG-сервера), поэтому через VPN идет только трафик к инфраструктуре gross-view, остальной интернет — обычным маршрутом. Адреса:

- `postgres` — 172.28.0.2:5432
- `keycloak` — 172.28.0.3:8080
- `n8n` — 172.28.0.5:5678
- `vault` — 172.28.0.7:8200

В качестве DNS клиентам отдаётся внутренний dnsmasq (`172.28.0.8`), поэтому `*.local` имена (`postgres.local`, `auth.local`, ...) также резолвятся.

### Добавление клиентов

Увеличьте `WG_PEERS` (или добавьте имена в список) и пересоздайте контейнер. Новые ключи генерируются только для свежих peer, старые сохраняются в `/config`. Обновлённые конфиги появятся в логе и в `/config/peerX`.

### Проброс порта

Клиенты подключаются к серверу по UDP-порту `51820`. Если хост за NAT, пробросьте `UDP 51820` на Docker-хост (в роутере/Mikrotik).

### Совместимость

- Контейнеру нужен capability `NET_ADMIN`; `SYS_MODULE` + `/lib/modules` — если модуль `wireguard` не загружен в ядре хоста.
- Работает на WSL2/Linux (модуль `wireguard` есть в новых ядрах), а также на macOS/Windows как клиент.
- Для работы вне Docker Desktop подойдёт таргетный Linux-хост/K8s.

## Vault (секреты)

### Первый запуск (инициализация)

```bash
# 1. Инициализация (одноразово). Вернуть результат: 1 unseal key + root token.
docker exec -it gross-view-infra-vault-1 vault operator init -key-shares=1 -key-threshold=1

# 2. Распечатать Vault
docker exec -it gross-view-infra-vault-1 vault operator unseal <UNSEAL_KEY>
```

Сохраните unseal key и root token в безопасном месте (не в git!). После каждого рестарта контейнера требуется распечатка.

### Заполнение секретов

```bash
docker exec -it gross-view-infra-vault-1 vault secrets enable -path=secret kv-v2

docker exec -it gross-view-infra-vault-1 vault kv put secret/postgres \
  username="$POSTGRES_DB_USER" password="$POSTGRES_DB_PSWD" database="$POSTGRES_DB_NAME"

docker exec -it gross-view-infra-vault-1 vault kv put secret/keycloak \
  admin="$KEYCLOAK_ADMIN" admin_password="$KEYCLOAK_ADMIN_PASSWORD"

docker exec -it gross-view-infra-vault-1 vault kv put secret/n8n \
  db_user="$N8N_DB_USER" db_password="$N8N_DB_PSWD" encryption_key="$N8N_ENCRYPTION_KEY"

docker exec -it gross-view-infra-vault-1 vault kv put secret/gross-view \
  db_user="$GV_DB_USER" db_password="$GV_DB_PSWD"
```

UI: http://localhost:8200/ui (в dev-режиме TLS отключён).

## DNS (dnsmasq)

Добавляет в общий сетевой контур:

- SRV-записи для сервисов: `*.local` (например `postgres.local` → `172.28.0.2`)
- Алиасы: `db.local`, `auth.local`, `workflow.local`, `secrets.local`, `vpn.local`
- Кэширование внешних запросов (8.8.8.8 / 8.8.4.4)

Конфигурация: `dns/dnsmasq.conf`. Чтобы использовать DNS другими клиентами, укажите им `nameserver 172.28.0.8`.

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

N8N_DB_NAME=
N8N_DB_USER=
N8N_DB_PSWD=
N8N_ENCRYPTION_KEY=
GENERIC_TIMEZONE=

WG_SERVERURL=auto
WG_PEERS=5
WG_PEERDNS=172.28.0.8
WG_INTERNAL_SUBNET=10.13.13.0
PUID=1000
PGID=1000
```

`.env` и `certs/` в `.gitignore` — не коммитьте их.

## Деплой в K8s

Готовые манифесты для деплоя в Kubernetes находятся в `k8s/` (зеркало docker-compose стека).

```bash
# 1. Заполните секреты в k8s/base/secret.yaml (замените changeme)
# 2. Примените (из корня репозитория)
kubectl apply -k .
# 3. Выдайте первый Let's Encrypt сертификат для mint-box.ru:
#    (nginx-под не поднимется, пока не создан Secret mint-box-tls)
kubectl create job --from=cronjob/certbot certbot-bootstrap -n gross-view
kubectl logs job/certbot-bootstrap -n gross-view
```

Соответствие сервисов: postgres → StatefulSet, keycloak → Deployment, nginx → Deployment + LoadBalancer (80/443, TLS-терминация для mint-box.ru), n8n → Deployment, vault → StatefulSet, wireguard → Deployment + LoadBalancer, dns → Deployment, certbot → CronJob (Let's Encrypt, HTTP-01/webroot, ежедневное обновление → Secret `mint-box-tls` + рестарт nginx). Тема и realm Keycloak встраиваются в ConfigMap через `configMapGenerator` в корневом `kustomization.yaml`. Требуются DNS-записи `mint-box.ru`/`www.mint-box.ru` на внешний IP ноды и доступный порт 80.

Планы на продакшен-кластер:

1. WireGuard оставить как sidecar/Deployment (или перейти на Tailscale Kubernetes Operator / Cloud VPN).
2. Vault перевести на K8s-хранилище (etcd/file) с auto-unseal через cloud KMS.
3. Ресурсы K8s обрабатывать через Vault Agent Injector / external secrets.
4. Публиковать через nginx LoadBalancer только 80/443 (`mint-box.ru`); Postgres и внутренние API — только через WireGuard/VPN/ClusterIP.

## Структура

```
├── docker-compose.yml
├── kustomization.yaml          # K8s: theme + realm ConfigMaps
├── k8s/base/                   # K8s-манифесты (Namespace, Secrets, workload, nginx, certbot)
├── .env
├── dns/
│   └── dnsmasq.conf
├── vault/
│   └── config/
│       └── vault.hcl
├── nginx/
│   └── gross-view.local.conf
├── postgres/
│   └── init/
├── themes/
│   └── gross-view/
└── gross-view-realm.json