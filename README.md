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
| tailscale  | 172.28.0.6    | - (internal)   | VPN-доступ к внутренним сервисам          |
| vault      | 172.28.0.7    | 8200           | Хранилище секретов                        |
| dns        | 172.28.0.8    | 53 (tcp/udp)   | Внутренний DNS (dnsmasq)                  |

Внутренняя подсеть: `172.28.0.0/24` (bridge, keycloak_network).

## Tailscale (VPN)

Обеспечивает безопасный доступ к внутренним сервисам (Postgres, Keycloak admin, n8n) без их публикации наружу.

### Настройка

1. Зарегистрируйтесь в [Tailscale](https://tailscale.com) и получите auth key в Admin Console → Settings → Keys.
2. Поместите ключ в `.env`:
   ```
   TS_AUTHKEY=tskey-auth-XXXXX
   ```
3. Поднимите стек. Подключение к VPN запустится автоматически.
4. В Admin Console подтвердите регистрацию узла `gross-view-vpn` (или настройте auto-approve).

### Доступные метки (MagicDNS)

- `postgres` — 172.28.0.2:5432
- `keycloak` — 172.28.0.3:8080
- `n8n` — 172.28.0.5:5678

### ACL (пример)

В Admin Console → Access Controls. Разрешить доступ только определённым группам:

```json
{
  "groups": {
    "group:developers": ["user1@example.com"],
    "group:admins": ["admin@example.com"]
  },
  "acls": [
    { "action": "accept", "src": ["group:developers"], "dst": ["postgres:5432"] },
    { "action": "accept", "src": ["group:admins"], "dst": ["*:*"] }
  ]
}
```

> Настройте ACL **до** деплоя в облачный K8s, чтобы никто лишний не имел доступа к БД.

### Совместимость

- Контейнеру нужен `/dev/net/tun` и capability `NET_ADMIN`.
- На WSL2/Linux работает из коробки.
- На Docker Desktop for Windows туннельное устройство снаружи может не пробрасываться — используйте WSL2 или таргетный Linux-хост/K8s.

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

TS_AUTHKEY=tskey-auth-XXXXX
```

`.env` и `certs/` в `.gitignore` — не коммитьте их.

## Деплой в облачный K8s (план)

1. Tailscale оставить как sidecar/Deployment (или использовать Tailscale Kubernetes Operator).
2. Vault перевести на K8s-хранилище (etcd/file) с auto-unseal через cloud KMS.
3. Ресурсы K8s обрабатывать через Vault Agent Injector / external secrets.
4. Публиковать через Ingress только nginx (`gross-view.local`); Postgres и внутренние API — только через Tailscale/ClusterIP.

## Структура

```
├── docker-compose.yml
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