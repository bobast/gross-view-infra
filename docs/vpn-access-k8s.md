# VPN-доступ к сервисам Kubernetes-кластера (WireGuard-шлюз)

Дата: 2026-10-05. Статус: манифесты применялись в кластере (ротации peer-ов
2026-10-06/07). **2026-10-07 nginx-stream-прокси был удалён из манифестов**
(контейнер `proxy` и ConfigMap `vpn-gateway-proxy`, вместе с ними pod-level
`securityContext.fsGroup: 101` и volume'ы `vpn-proxy`/`proxy-logs`/`proxy-cache`/
`proxy-run`) — туннель поднимался, но портов внутри него не было. **2026-10-08
прокси-слой восстановлен** из §12 этого документа: контейнер `proxy`, ConfigMap
`vpn-gateway-proxy` (воссоздан как `k8s/base/vpn-gateway-proxy-configmap.yaml`,
в git-истории его по-прежнему нет), строка в `kustomization.yaml`, `fsGroup: 101`
и volume'ы возвращены в `k8s/base/vpn-gateway-deployment.yaml`. Порты
`10.13.13.1:15432` (postgres) / `10.13.13.1:18200` (vault) снова слушаются
внутри туннеля. §12 сохранён как историческая точка отсчёта (тексты, которые
восстанавливались).

Задача: дать разработчику с ноутбука доступ к внутренним сервисам кластера
(минимум — PostgreSQL и Vault), не публикуя их наружу и не открывая наружу весь
сетевой диапазон кластера.

Решение: под `vpn-gateway` в ns `gross-view`, в котором в одном pod-е живут
WireGuard-сервер и nginx-stream-proxy. Клиент подключается по
UDP к публичному IP узла, попадает в туннель `10.13.13.0/24` и видит ровно два
порта: прокси на PostgreSQL и прокси на Vault.

---

## 1. Проверенные факты о кластере

Все замеры сделаны 2026-10-05 через `kubectl` и временные диагностические поды
(поды созданы, измерения сняты, затем удалены — в кластере следов не осталось).

| Что | Значение / результат |
|---|---|
| Кластер | k0s, control-plane на контроллере `192.168.132.4` (`200.165.238.230:6443`), **один** worker `192.168.132.5` (`200.165.239.108`), k8s 1.36.3 |
| CNI | Calico, VXLAN, IPPool `10.244.0.0/16`, podCIDR узла `10.244.0.0/24`, `natOutgoing: true`, BPF выкл. |
| Service CIDR | `10.96.0.0/12` (напр. vault `10.96.200.70`, keycloak `10.98.130.148`) |
| Ресурсы узла | 2 CPU / 1912 Mi RAM (лимиты всех подов суммарно превышают RAM намеренно) |
| Хранилище | `local-path` (RWO, локальный диск) — PVC переносимы только на тот же узел |
| Балансировщик Timeweb | **только TCP**: `proto-http`, `proto-https`, `proto-tcp`, `proto-tcp-ssl`, `proto-http2`. **UDP через LB невозможен** |
| Входящий трафик на IP узла | TCP работает: `http://200.165.239.108/healthz` → 200 (nginx `hostPort: 80`) |
| **Входящий UDP на IP узла** | **проходит**: временный под с `hostPort 43210/udp` получил датаграмму, отправленную на `200.165.239.108:43210` |
| WireGuard в pod-netns | **работает** с одним лишь `NET_ADMIN` (без `privileged`): `ip link add dev wg0 type wireguard` успешно |
| `net.ipv4.ip_forward` в pod-netns | `0`, и `/proc/sys` **read-only** без `privileged` (в privileged — меняется) |
| `rp_filter` в pod-netns | `2` (loose) — совместимо с туннелем |
| `iptables`/`wg-quick` | В образе `linuxserver/wireguard` есть и iptables, и `wg-quick` ⇒ поднимаем туннель штатным `wg-quick up`. Он трогает sysctl/iptables **только** для default-route (`*/0`) AllowedIPs — у нас его нет, поэтому read-only `/proc/sys` пода не задевается (проверено на живом буте образа 2026-10-06) |

Следствия, которые определили конструкцию:

1. **WireGuard нельзя завести через балансировщик** — только напрямую на публичный IP узла (`hostPort`). Это же снимает главный риск: входящий UDP на узел подтверждён замером.
2. **Маршрутизация pod/service CIDR внутрь туннеля отпадает**: она требует `ip_forward=1`, а в pod-netns это либо невозможно (`/proc/sys` read-only), либо нужен `privileged`-под. Выбранный вариант (прокси-порты) обходится без форвардинга вообще.
3. **WireGuard на хостовом netns** (DaemonSet с `hostNetwork`) потребовал бы дополнительных правил в FORWARD-цепочке Calico — лишняя точка отказа при нулевой выгоде.

---

## 2. Архитектура

```
   ноутбук (10.13.13.2/32)
        │  WireGuard, UDP 43210, AllowedIPs = 10.13.13.1/32
        ▼
   200.165.239.108:43210  (публичный IP узла worker-192.168.132.5, hostPort)
        │  kube-proxy DNAT
        ▼
   pod vpn-gateway (10.244.4.x, ns gross-view)
   ┌──────────────────────────────────────────────────────────────┐
   │ wg0 10.13.13.1/24   (контейнер wireguard, NET_ADMIN)        │
   │   :15432 ──► postgres.gross-view.svc.cluster.local:5432      │
   │   :18200 ──► vault.gross-view.svc.cluster.local:8200         │
   │              (контейнер proxy, nginx stream)                │
   └──────────────────────────────────────────────────────────────┘
        │  ClusterIP / pod IP, внутри кластера
        ▼
   postgres-0 (10.244.4.x:5432)          vault (10.96.200.70 → pod:8200)
```

> История: **2026-10-07** строки `:15432`/`:18200` (и контейнер `proxy`) из
> манифестов убрасывались — туннель у клиента был, но соединиться не с чем:
> ни pod IP, ни ClusterIP в туннель не попадают, а прокси-портов на адресе
> `wg0` нет. **2026-10-08 прокси-слой восстановлен** (§12), схема снова рабочая.

Ключевые решения:

| Решение | Почему |
|---|---|
| Только прокси-порты, без маршрутизации CIDR | У клиента в `AllowedIPs` стоит `10.13.13.1/32`. Даже если он захочет — в туннель физически нечего положить: ни pod IP, ни ClusterIP, ни `10.96.0.1:443` (API-сервер). Поверхность атаки = UDP-порт, закрытый криптографией WireGuard, и два TCP-порта (прокси-слой восстановлен 2026-10-08; в период 2026-10-07…10-08 их не было). |
| Оба компонента в одном pod-е | nginx должен слушать адрес `wg0`. Разные pod-ы = разные netns; либо `hostNetwork` у обоих, либо сетевой плагин вроде Multus. Общий netns — самое простое. |
| `hostPort`, а не `Service` | LB Timeweb не умеет UDP (см. §1). |
| `NET_ADMIN` без `privileged` и без `hostNetwork` | Подтверждено замером. Никаких правок в Calico и на узле. |
| Peer-ключи в Secret, приватные ключи — на машине разработчика | Приватный ключ клиента физически не покидает ноутбук (создаётся локально скриптом и кладётся в `wg-quick`-конфиг). На сервере лежит только публичная часть + адрес туннеля (PSK не используется, см. §3). |
| Ручное выдавание конфигов (1–2 человека) | Без UI/контроллера; скрипт `vpn-peer.sh` печатает готовый конфиг и сам патчит Secret. |

---

## 3. Что добавлено в репозиторий

| Файл | Назначение |
|---|---|
| `k8s/base/vpn-gateway-deployment.yaml` | Deployment: init-контейнер `render-config` (рендер конфига из Secret) + контейнер `wireguard` (образ `linuxserver/wireguard`, `NET_ADMIN`, `hostPort 43210/udp`) + контейнер `proxy` (nginx stream, восстановлен 2026-10-08; был удалён 2026-10-07) |
| `k8s/base/vpn-gateway-entrypoint-configmap.yaml` | Скрипт рендера `wg0.conf` из Secret (LF-пин в `.gitattributes`); запускается init-контейнером, сам туннель поднимает образ |
| `k8s/base/vpn-gateway-proxy-configmap.yaml` | `nginx.conf` со stream-листенерами на `10.13.13.1` (`15432` → postgres, `18200` → vault). Удалён 2026-10-07, **восстановлен 2026-10-08** из §12 (в git-истории его **нет** — первая версия файла не была закоммичена) |
| `k8s/base/kustomization.yaml` | Ресурсы vpn-шлюза в сборке (с 2026-10-08 — три: deployment + entrypoint-configmap + proxy-configmap) |
| `scripts/lib-wg-keys.sh` | Общая генерация ключей для обоих скриптов: backend `wg` или fallback на `openssl` (X25519) |
| `scripts/vpn-init.sh` | Генерация серверных ключей → Secret `vpn-gateway-keys` |
| `scripts/vpn-peer.sh` | `add` / `list` / `remove` peer-ов, генерация клиентского конфига |
| `k8s/base/vault-deployment.yaml`, `k8s/base/eso-externalsecret.yaml`, `vault/entrypoint.sh`, `k8s/base/vault-entrypoint-configmap.yaml`, `docker-compose.yml`, `.env.example` | Аутентификация человека в Vault (`userpass` + политика `dev-policy`) |
| `.gitattributes`, `.gitignore` | LF-пин для новых ConfigMap-ов, игнор `/vpn/` и `*.wg.conf` |

**Secret `vpn-gateway-keys` в git отсутствует намеренно** — в манифесте есть только
ссылка на него. Пока секрета нет, под остаётся в `Pending` (`secret not found`),
остальной стек не затрагивается.

Формат секрета:

```
server_privatekey        (обязателен, иначе под уходит в CrashLoop с внятной ошибкой)
server_publickey         (формальный; его читает scripts/vpn-peer.sh)
peer_<имя>_publickey     ┐
peer_<имя>_address       ┘─ по паре на разработчика; пустое значение = пир не создан
```

Нюансы формата:

- **PSK (preshared key) не используется** — от него отказались полностью
  2026-10-06: `vpn-peer.sh`/`lib-wg-keys.sh` не генерируют `psk`, entrypoint не
  пишет строку `PresharedKey`, а ключ `peer_<имя>_presharedkey` удалён из Secret.
  Защиту handshake даёт сама X25519-пара; `vpn-peer.sh remove` при отклике пира
  по-прежнему затирает легаси-ключ `presharedkey`, если он в Secret остался;
- `peer_<имя>_address` хранит **AllowedIPs** пира: голый адрес туннеля
  (`10.13.13.2` → в конфиг попадает `10.13.13.2/32`) либо готовый CIDR для
  site-to-site пира (`192.168.86.0/24` остаётся как есть). Append `/32` к CIDR
  дал бы `192.168.86.0/24/32` и WireGuard отверг весь конфиг — скрипт это
  знает (см. ветку `case "$allowed" in */*)` в ConfigMap);
- несколько AllowedIPs — через запятую **без пробелов**
  (`10.13.13.2/32,192.168.86.16/32`): значение содержит `/`, ветка `*/*`
  в `case` пропускает его верbatim, `wg show` подтверждает оба CIDR у пира (живая
  проверка 2026-10-07);
- для пира с AllowedIPs вне серверной подсети маршрут `dev wg0` ставит сам
  `wg-quick` (проверено на живом буте 2026-10-06: `ip -4 route add
  192.168.86.0/24 dev wg0`): wg0 несёт on-link только `10.13.13.0/24`, без
  маршрута ответ пира ушёл бы из pod-а в eth0 и потерялся.

**Текущие peer-ы (на 2026-10-08):**

| Peer | AllowedIPs | Комментарий |
|---|---|---|
| `GW` | `10.10.11.1/32,10.10.11.41/32` | **текущий (добавлен 2026-10-08 взамен `gagarin`)** — внешний шлюз: публичный ключ `ojD0T517girSt/rWvkmbi1LtJb6wGBd+c9RnJVZm+XY=`, `Endpoint = 77.232.55.58:13233`, `PersistentKeepalive = 23` (секунды). Чужой ключ + endpoint/keepalive — только прямой патч Secret-а: `peer_GW_{publickey,address,endpoint,keepalive}` (штатный `vpn-peer.sh add` генерирует свою пару и чужой ключ принять не может). `endpoint`/`keepalive` — новые **опциональные** ключи: рендер-скрипт (`vpn-gateway-entrypoint-configmap.yaml`) добавляет `Endpoint`/`PersistentKeepalive` в `[Peer]` только если ключ существует, `vpn-peer.sh remove` чистит их наравне с остальными. Проверено: `render-config` → `wrote ... with 1 peer(s)`, `wg show wg0` → peer `ojD0…`, endpoint `77.232.55.58:13233`, `persistent keepalive: every 23 seconds`, маршруты `10.10.11.1/32`/`10.10.11.41/32 dev wg0` (2026-10-08 к `AllowedIPs` добавлен `10.10.11.41/32`). |
| ~~`gagarin`~~ | ~~`10.13.13.2/32, 192.168.86.16/32`~~ | **отозван полностью 2026-10-08**: `vpn-peer.sh remove gagarin` вычистил `peer_gagarin_*` из Secret (скрипт попутно починен — комментарий внутри продолжения строки `-p \` уводил JSON в комментарий и ронял `remove`), локальный `vpn/gagarin.conf` удалён, под пересобран. Эта же машина (хост `gagarin`, в LAN `192.168.86.0/24`); второй CIDR — LAN-IP хоста, на него кластер теперь маршрутизирует через туннель (маршрут `192.168.86.16 dev wg0` в pod-netns шлюза). **Ротация №8 (2026-10-08, последняя — пир `gagarin` отозван полностью тем же днём):** действовавший на тот момент публичный ключ `sOrBWZVxNJuLgY2X8PcKWME+JcYOP0nTwe/RA38OewY=` — явный возврат к ключу №2: прямой патч Secret-а (`peer_gagarin_publickey`, значение в обычном base64 только в `data`, `peer_gagarin_address` не тронут) + правка pod-аннотации `vpn.gross-view/peer-publickeys` в манифесте (ключ изменился — сработал триггер пересборки) + `kubectl apply -k .`. Проверено: `render-config` → `wrote ... with 1 peer(s)`, `wg show wg0` печатает peer `sOrBWZVx…` с `allowed ips: 10.13.13.2/32, 192.168.86.16/32`. Заодно при этой ротации исправлена порча манифеста: у контейнера `wireguard` в `drop:` лежала склеенная строка `- ALLsOrBWZVx…` вместо `- ALL` — «drop ALL» не срабатывал и контейнер работал с полным дефолтным набором capabilities (проверено живьём до правки: `CapEff a80435fb` = дефолт + NET_ADMIN); после правки и пересборки `CapEff = 0000000000001003` (только CHOWN|DAC_OVERRIDE|NET_ADMIN). ⚠️ Локальный `vpn/gagarin.conf` (удалён 2026-10-08 вместе с пиром) содержал приватный ключ пары `08/del…` — ни к №8, ни к №7 он парой не был. **Ротация №7 (2026-10-07, отозвана):** публичный ключ `iJC0hhmgdv2hD+nyF/iUxJsNFL33c/izzxzDPyHBsQc=` — внесён прямым патчем Secret-а (значение только в `data`, `peer_gagarin_address` не тронут), под пересобран через `kubectl -n gross-view rollout restart deployment/vpn-gateway`; тогда проверено `wg show wg0` → peer `iJC0hhmg…` с `allowed ips: 10.13.13.2/32, 192.168.86.16/32`. Перед патчем №7 в Secret лежал `sOrBWZVx…` (№2) — записи о ротациях №3–№6 состоянию Secret не соответствовали. **Ротация №6 (отозвана):** публичный ключ `IF9oLK/VU6TC393yw8gW6E64FDyJ9kemWU9eIUo2p0w=` — внесён прямым патчем Secret-а (сгенерирован на стороне клиента) и дублирован в pod-аннотацию `vpn.gross-view/peer-publickeys`, под пересобран через `kubectl apply -k .`; одновременно `peer_gagarin_address` расширен до двух CIDR (в wg-конфиг значение попадает **без пробелов** после запятой: `10.13.13.2/32,192.168.86.16/32` — ветка `case */*` использует его верbatim, оба CIDR не содержат `/0`, так что default-route логика wg-quick не задевается). Предыдущие (отозваны): `yn+R6H7OeIMdWGKyHLc3D75Q5dDM7jdjuZWeXY2yl3Q=` (№5, 2026-10-06, с `AllowedIPs = 10.13.13.2`), `+3iZ8kgN5UATV9OcVR/raGzILYGhAQZc8s8NQfd1TWU=` (№4), `3S8E4r8Xp2wGCPYtZ8Cs76eXPs4vLPcFqxhuCBlPCiQ=` (№3), `sOrBWZVxNJuLgY2X8PcKWME+JcYOP0nTwe/RA38OewY=` (№2), `O3c/U4UQF53WrSWebqXItdfeEXaT/f13gCQyJfr/GUw=` (№1), до них — site-to-site `BQzP2vDjnqFHB+zxaztyG8WoK7LFHdjKocXnE8Du4Hw=`. ⚠️ Локального `vpn/gagarin.conf` в репозитории нет — клиентский конфиг должен быть пары `IF9o…` (приватный ключ остался на клиентской машине) |
| ~~`pavlov`~~ | — | — | отозван 2026-10-06 (из Secret вычищены `peer_pavlov_*`, локальный `vpn/pavlov.conf` удалён) |

История: 2026-10-05/06 под именем `gagarin` был **site-to-site** пир с
`AllowedIPs = 192.168.86.0/24` — его публичный ключ
`BQzP2vDjnqFHB+zxaztyG8WoK7LFHdjKocXnE8Du4Hw=` пришёл «снаружи» и был вписан в
Secret напрямую. 2026-10-06 он отозван (`vpn-peer.sh remove gagarin`) и заменён
новой парой, сгенерированной на этой машине: чужой приватный ключ недоступен,
поэтому рабочий клиентский конфиг на стороне сайта-в-сайте создать было нельзя.

Ручная запись пира с чужим публичным ключом (то, что `vpn-peer.sh add` не умеет —
он генерирует свою пару):

```bash
kubectl -n gross-view patch secret vpn-gateway-keys --type=merge -p "{\"data\":{
  \"peer_<имя>_publickey\":\"$(printf '%s' '<PUBKEY>' | base64 -w0)\",
  \"peer_<имя>_address\":\"$(printf '%s' '<AllowedIPs>' | base64 -w0)\"}}"
# и рестарт шлюза (см. шаг 2 — rollout restart; scale 0→1 как запасной путь)
```

---

## 4. Порядок внедрения

Шаг 0 (уже выполнен, повторять не нужно): замеры из §1.

### Шаг 1. Ключи Vault (до `kubectl apply`, иначе ESO будет ругаться на отсутствующие ключи)

```bash
# root-токен лежит в /vault/data/init.json; достаём его без печати в лог
TOKEN=$(kubectl -n gross-view exec deploy/vault -c vault -- \
  sh -c 'sed -n "s/.*\"root_token\": *\"\([^\"]*\)\".*/\1/p" /vault/data/init.json')
```

На существующем кластере bootstrap-сид повторно **не** применяется (путь
`secret/gross-view` уже создан), поэтому дописываем **оба** ключа одной командой:

```bash
kubectl -n gross-view exec -i deploy/vault -c vault -- env VAULT_TOKEN="$TOKEN" \
  vault kv patch secret/gross-view \
  vault_userpass_username=vpn-dev vault_userpass_password='<СВОЙ_ПАРОЛЬ>'
```

Форсируем синхронизацию Secret и перезапускаем Vault, чтобы подхватить новые env:

```bash
kubectl -n gross-view annotate externalsecret gross-view-secrets force-sync="$(date +%s)" --overwrite
kubectl -n gross-view rollout restart deployment/vault
```

Проверка: в логах vault должно появиться
`userpass user 'vpn-dev' configured (policy dev-policy)`; пока пароль не задан —
`vault_userpass_password is unset or still 'change_me' — skipping userpass auth`.

### Шаг 2. Ключи туннеля

```bash
./scripts/vpn-init.sh           # Secret vpn-gateway-keys (серверные ключи)
./scripts/vpn-peer.sh add maria  # конфиг vpn/maria.conf (0600, в git не попадает)
./scripts/vpn-peer.sh list      # кто зарегистрирован
```

Сейчас в Secret один пир — **`GW`** (`AllowedIPs = 10.10.11.1/32,10.10.11.41/32`, `Endpoint = 77.232.55.58:13233`, `PersistentKeepalive = 23`, см. §3), добавленный прямым патчем Secret-а 2026-10-08: `peer_GW_publickey` + `peer_GW_address` + опциональные `peer_GW_endpoint`/`peer_GW_keepalive` (чужой публичный ключ — `vpn-peer.sh add` генерирует свою пару и его принять не может). Локального конфига у него нет — приватный ключ живёт на стороне внешнего шлюза.
`gagarin` отозван полностью тем же днём (`remove gagarin` → Secret очищен,
локальный `vpn/gagarin.conf` удалён), `pavlov` — 2026-10-06. Прежний
site-to-site пир `gagarin` (`192.168.86.0/24`, внешний ключ) отозван
2026-10-06 через `remove gagarin` → `add gagarin`: `vpn-peer.sh add` чужой
публичный ключ принять не может, поэтому старый набор ключей сначала отзывают.

Pod стартует сам, как только Secret появится (kubelet повторяет mount с backoff до
~2 минут) — `rollout restart` после `vpn-init.sh` не нужен. Peer-ов, добавленных
позже (и смену их ключей), entrypoint подхватывает только при рестарте пода.
С 2026-10-06 у Deployments `strategy: Recreate`, поэтому работает обычный
`kubectl -n gross-view rollout restart deployment/vpn-gateway`: старый под удаляется
до создания нового, hostPort 43210/udp успевает освободиться. Запасной путь
(если стратегию когда-нибудь вернут к `RollingUpdate`) — dance 0→1:

```bash
kubectl -n gross-view scale deployment/vpn-gateway --replicas=0   # ждём удаления подов
kubectl -n gross-view scale deployment/vpn-gateway --replicas=1
```

Ключи генерируются на машине оператора намеренно: ключ, родившийся внутри кластера,
пришлось бы вытаскивать через лог пода. Генератору нужен **либо** `wg`
(`apt install wireguard-tools`), **либо** `openssl` ≥ 1.1.1 — `scripts/lib-wg-keys.sh`
выбирает доступный backend, поэтому `sudo apt install` не обязателен (openssl-путь
даёт те же 32-байтные base64-ключи; публичный ключ сверен с эталоном RFC 7748).

### Шаг 3. Развёртывание

```bash
kubectl apply -k .
kubectl -n gross-view rollout status deployment/vpn-gateway --timeout=180s
kubectl -n gross-view logs deployment/vpn-gateway -c wireguard
```

Ожидаемое в логах (логи init-контейнера и основного разделены):

```bash
kubectl -n gross-view logs deployment/vpn-gateway -c render-config   # wrote ... with N peer(s)
kubectl -n gross-view logs deployment/vpn-gateway -c wireguard       # Client mode selected /
                                                                    # Activating tunnel / All tunnels are now active
                                                                    # (с 2026-10-08 есть и логи -c proxy:
                                                                    #  [vpn-proxy] waiting for wg0 → wg0 is up, starting nginx stream proxy)
```

⚠️ Если менялся ConfigMap entrypoint —
`kubectl -n gross-view rollout restart deployment/vpn-gateway`: со `strategy: Recreate`
(2026-10-06) рестарт на single-node с hostPort проходит без зависания; при возврате
к `RollingUpdate` снова понадобится `scale --replicas=0` → дождаться удаления подов
→ `--replicas=1`.

Проверка, что peer действительно загрузился (частая ошибка — молча 0 peer-ов):

```bash
kubectl -n gross-view exec deploy/vpn-gateway -c wireguard -- wg show wg0
# в выводе должен быть блок "peer:"; число peer-ов видно в логе init-контейнера:
# "wrote ... with 1 peer(s)"
```

Проверка прокси изнутри pod-а (контейнер `proxy` восстановлен 2026-10-08):

```bash
kubectl -n gross-view exec deploy/vpn-gateway -c proxy -- \
  wget -qO- --timeout=5 http://10.13.13.1:18200/v1/sys/health     # vault: initialized/unsealed
kubectl -n gross-view exec deploy/vpn-gateway -c proxy -- \
  sh -c 'nc -w 3 10.13.13.1 15432 </dev/null && echo postgres OK'   # 5432 через stream
kubectl -n gross-view exec deploy/vpn-gateway -c proxy -- tail -5 /var/log/nginx/access.log
# в access.log видно upstream: 10.244.x.x:5432 и 10.96.200.70:8200 — DNS-резолв сработал
```

### Шаг 4. Проверка с ноутбука

```bash
sudo install -m 600 ivan.conf /etc/wireguard/gross-view.conf
sudo wg-quick up gross-view
sudo wg show                     # latest handshake, transfer, endpoint
sudo wg-quick down gross-view
```

⚠️ Проверки доступа к сервисам (`psql "host=10.13.13.1 port=15432 ..."`,
`curl http://10.13.13.1:18200/v1/sys/health`, `vault login -method=userpass
username=vpn-dev`, `vault kv get/patch secret/gross-view`) **работают с
2026-10-08** (прокси-слой восстановлен; в период 2026-10-07…10-08 прокси-портов
внутри туннеля не было). Пароль для psql берётся из `gross-view-secrets`
(или из Vault: поле `gv_db_password`) — он тот же, что у сервисов.

### Шаг 5. Управление доступом

```bash
./scripts/vpn-peer.sh add maria         # выдать доступ
./scripts/vpn-peer.sh remove maria      # отозвать
# применить — рестартом пода (с 2026-10-06 обычный rollout restart безопасен):
kubectl -n gross-view rollout restart deployment/vpn-gateway
./scripts/vpn-init.sh --force           # ротация серверных ключей (ломает всех)
```

Entrypoint перечитывает Secret только при старте пода, поэтому после каждой
операции с peer-ами нужен рестарт пода. У Deployments `strategy: Recreate`
(2026-10-06): старый под удаляется до создания нового, hostPort 43210/udp
освобождается заранее — `rollout restart` и `kubectl apply -k .` на single-node
не зависают. Если пир вписан в Secret напрямую (чужой публичный ключ), продублируйте
ключ в pod-аннотацию `vpn.gross-view/peer-publickeys` манифеста — иначе `apply -k .`
пересборку не заметит (поднимет тот же pod template). Запасной путь без правки
манифеста — `scale --replicas=0` → дождаться удаления подов → `--replicas=1`.

---

## 5. Доступ к сервисам: что важно знать

> История: **2026-10-07…10-08** контейнер `proxy` был убран из манифестов, и
> раздел описывал состояние «до удаления прокси» — из туннеля до `postgres-0`
> и Vault было не добраться. **С 2026-10-08 прокси-слой восстановлен**, раздел
> снова актуален.

**PostgreSQL.** Туннель даёт TCP до `postgres-0` с аутентификацией scram-sha-256
(дефолт официального образа). `pg_hba.conf` не менялся: подключение приходит с IP
пода-шлюза, то есть неотличимо от внутрикластерного, и пароль остаётся единственным
барьером. Отдельный Service не нужен — `postgres` headless, и nginx резолвит
`postgres.gross-view.svc.cluster.local` в pod IP в момент соединения (`resolver
... valid=10s`), поэтому перезапуск пода не ломает туннель. DBeaver/pgAdmin/GUI
работают: хост `10.13.13.1`, порт `15432`.

**Vault.** В кластере Vault работает с `tls_disable = 1` (`vault/vault-config.hcl`),
поэтому по туннелю идёт обычный HTTP — это нормально, трафик шифруется WireGuard.
Аутентификация — `userpass`, пользователь из `vault_userpass_username`
(по умолчанию `vpn-dev`), политика `dev-policy`: только `secret/data/gross-view`
и его metadata. Правка значения в Vault попадает в кластер через ESO при
следующей синхронизации (`refreshInterval: 1h`) — то есть это рабочий путь
«поправил секрет по VPN → через час применено», а не только чтение.

Логины и пароли в UI-лог не попадают, но каждое чтение/изменение видно в
`sys/audit`-событиях Vault, если позже включить файловый или сокетный аудит
(сейчас не включён — это отдельный долг, см. §8).

---

## 6. Безопасность: что защищает, а что нет

| Угроза | Мера |
|---|---|
| Скан UDP-порта 43210 снаружи | WireGuard отвечает только на валидный handshake; неавторизованные пакеты отбрасываются. Наличие порта не даёт ничего |
| Подбор/перебор ключа peer-а | Curve25519 (X25519): подбор приватного ключа из публичного непрактичен, весь handshake держится на кривой. Preshared key не используется — от него отказались 2026-10-06 (из Secret удалён `peer_gagarin_presharedkey`, скрипты `psk` не генерируют). Подмена адреса не проходит из-за привязки к ключу |
| Доступ разработчика в кластер мимо двух портов | У клиента в туннеле маршрутизируется только `10.13.13.1/32`; pod/service CIDR недоступны by construction. На стороне сервера в wg-подсистему уходят только AllowedIPs пиров (`10.10.11.1/32,10.10.11.41/32` у `GW`; у отозванного `gagarin` — `10.13.13.2/32, 192.168.86.16/32`, для site-to-site пира туда же уходил бы его CIDR, маршрут `dev wg0` живёт в pod-netns шлюза и наружу не выходит) |
| Попадание приватного ключа в git | Клиентский ключ генерируется локально и остаётся в `vpn/<name>.conf` (0600, `.gitignore`); серверный ключ — только в Secret |
| Плейсхолдер-пароль `change_me` как рабочий | Entrypoint **не** включает userpass, пока пароль пуст или равен `change_me` (проверено в §5 шаг 1) |
| Компрометация ноутбука | Отзыв = `vpn-peer.sh remove` + `rollout restart` (секунды). Ключи можно перевыпустить (`add --reissue`) |
| DoS/перегрузка шлюза | Есть лимиты CPU/memory (wireguard 200m/192Mi, прокси 100m/64Mi) и `revisionHistoryLimit: 0` |

Осознанные компромиссы:

- **Privilege-контейнер в кластере.** `NET_ADMIN` даёт поду право управлять своими сетевыми интерфейсами; плюс `CHOWN`/`DAC_OVERRIDE` — чтобы штатный init образа (`lsiown -R abc:abc /config`) мог сменить владельца отрендеренного конфига и root-сервис прочитал его (обе-cap нужны только контейнеру `wireguard`). Это всё равно больше, чем у остальных подов стека. Альтернатива — WireGuard на узле, но там нужен доступ к Calico/FORWARD. Ни `privileged`, ни `SYS_MODULE`, ни `hostNetwork` не используются.
- **Секрет `vpn-gateway-keys` не зашифрован at rest.** В кластере не включено EncryptionConfiguration для Secret. Ключи лежат в etcd в base64. Для dev-окружения приемлемо; для продакшена — EncryptionConfiguration или внешний secrets-оператор для этого секрета.
- **Пароль Vault попадает в `gross-view-secrets`**, который читают почти все поды (ESO тянет его из Vault по цепочке). Причина — сохранение свойства «zero manual steps» на свежем кластере; в продакшене этот один секрет стоит вынести в отдельный Secret/ExternalSecret.
- **Туннель без второго фактора.** WireGuard-ключ — единственный секрет. Для усиления можно завернуть WG в прокси с TLS/mTLS на балансировщике, но это отдельный проект.
- **Мониторинга туннеля нет.** Есть только логи и `wg show`. Стоит добавить alert на отсутствие handshake (кастомный `log_format vpn` живёт в nginx-конфиге прокси, `vpn-gateway-proxy-configmap.yaml` — удалённом 2026-10-07 и восстановленном 2026-10-08).

---

## 7. Что НЕ делаем и почему

| Вариант | Почему отклонён |
|---|---|
| WireGuard через `Service type: LoadBalancer` | Балансировщик Timeweb не поддерживает UDP (§1) |
| Маршрутизация `10.244.0.0/16` + `10.96.0.0/12` в туннель | Требует `ip_forward=1`; в pod-netns `/proc/sys` read-only (нужен `privileged`), плюс клиент получает сетевой доступ ко всему кластеру |
| WireGuard на хостовом netns (DaemonSet `hostNetwork`) | Нужны правила в FORWARD-цепочке Calico; сложнее в поддержке, не даёт выигрыша на одном узле |
| Tailscale / Headscale | Требует исходящей связи с внешним control plane (или ещё один control plane в кластере) и агента на узле; для 1–2 человек WireGuard без внешних зависимостей проще |
| Проброс портов 5432/8200 через nginx на LB | Доступ снаружи без криптографии — неприемлемо; nginx-прокси вместо этого живёт в туннеле |
| OpenVPN | Работает через TCP-LB, но заметно тяжелее WireGuard и хуже эксплуатируется |

---

## 8. Долги и точки развития

1. **NetworkPolicy** (Calico это умеет) — ограничить входящие на pod `vpn-gateway` (сейчас открыт только `hostPort` снаружи) и отдельно закрыть прямой доступ к `postgres`/`vault` для всего, что не является кластером и не VPN-шлюзом. Имеет смысл, когда в кластере появится handler.
2. **Аудит Vault**: включить файловый аудит-устройство, иначе userpass-доступ разработчика не оставляет следов.
3. **TLS для Vault** (`tls_disable = 0` + `vault-tls` initContainer по образцу nginx) — полезно, когда к Vault начнут ходить не только через туннель.
4. **HA/резервирование шлюза.** Сейчас `replicas: 1` на одном worker: рестарт пода = минуты без доступа. Ключи можно шарить через Secret и поднять второй `vpn-gateway` с `hostPort` на другом узле (нужен второй worker, которого пока нет).
5. **WireGuard-поддержка на стороне handler**: если появится k8s-деплой `gross-view-handler`, часть маршрутизации (`wg_*`-ключи в Vault уже есть, включая `wg_internal_subnet: 10.13.13.0`) можно будет переиспользовать.
6. **MTU**: взят консервативный `1380`; при жалобах на зависание больших `pg_dump` — проверить, не режется ли трафик на VXLAN/MTU 1500.

---

## 9. Откат

Полностью обратим: VPN не участвует в трафике приложений.

```bash
kubectl -n gross-view delete deployment vpn-gateway
kubectl -n gross-view delete configmap vpn-gateway-entrypoint
kubectl -n gross-view delete configmap vpn-gateway-proxy
kubectl -n gross-view delete secret vpn-gateway-keys          # ключи — в мусор
kubectl apply -k .                                            # вернуть kustomization без vpn-ресурсов
```

Если откатывается только userpass в Vault: удалить
`vault auth disable userpass` (через root-токен) и убрать
`VAULT_USERPASS_*` из `k8s/base/vault-deployment.yaml` + `docker-compose.yml`.
Политика `dev-policy` без аутентификации ничего не даёт.

---

## 10. Что осталось непроверенным

| Гипотеза | Как проверить при внедрении |
|---|---|
| Реальный handshake WireGuard через интернет до `200.165.239.108:43210` | Шаг 4: `wg show` должен показать `latest handshake`. **UDP-доходимость подтверждена замером (2026-10-05), сам handshake — нет: его даёт только клиент с ноутбука** |
| Трафик `10.13.13.1 → postgres` проходит без потерь и без зависания длинных сессий | С 2026-10-08 (прокси восстановлен): `psql` + `pg_dump` большой таблицы, сессия дольше `proxy_timeout`. TCP-установление через stream уже проверено изнутри pod-а |
| nginx stream корректно резолвит headless `postgres` после рестарта его пода | `kubectl -n gross-view delete pod postgres-0` и повторный `psql`. Резолв на текущий IP подтверждён (upstream `10.244.4.116:5432` в access.log) |
| Образ `linuxserver/wireguard` поднимает туннель вживую в поде (проверено только на локальном буте в namespace) | Логи `-c wireguard`: `Client mode selected` → `Activating tunnel` → `All tunnels are now active`; затем `wg show wg0` печатает peer |

---

## 11. Типовые ошибки

| Симптом | Причина и что делать |
|---|---|
| `MountVolume.SetUp failed for volume "vpn-keys": secret "vpn-gateway-keys" not found` | Secret ещё не создан. `./scripts/vpn-init.sh` — после появления Secret под поднимется **сам** (kubelet повторяет mount), `rollout restart` не нужен |
| `FailedScheduling: 1 node(s) didn't have free ports for the requested pod ports` | Со `strategy: Recreate` (2026-10-06) не должно встречаться: старый под удаляется до создания нового, hostPort 43210/udp свободен. Если встретилось — стратегия откатилась к `RollingUpdate` (`kubectl -n gross-view get deploy vpn-gateway -o jsonpath='{.spec.strategy}'`): восстановите `Recreate` либо вручную `scale --replicas=0` → дождаться удаления пода → `--replicas=1` (приём для single-node + hostPort, тот же у nginx) |
| `apk add` в логах падает | **Больше не применяется** (образ `linuxserver/wireguard` содержит `wireguard-tools` из коробки; скрипт пакеты не ставит). Старый симптом сохранён для истории: нужен был egress воркера к alpine-зеркалу |
| Логи `-c wireguard`: `No valid tunnel config found` / `Tunnel ... failed` | Init-контейнер `render-config` не записал `/config/wg_confs/wg0.conf` (см. его лог: обычно `FATAL: ... no server_privatekey`) либо `wg-quick up` отверг конфиг. ⚠️ В этой ветке образ делает `ip route del default` — default-route пода пропадает, и контейнер `proxy` (восстановлен 2026-10-08) из-за этого теряет DNS → резолв upstream'ов в stream-конфиге не работает, хотя nginx поднимается. Смотрите лог `-c render-config` |
| В логах `wrote ... with 0 peer(s)`, хотя peer добавлен | Имена ключей Secret разбираются как `peer_<имя>_*`; при неверном разборе address-файл ищется как `peer_peer_<имя>_address` и peer молча пропускается. Проверьте `wg show wg0` — там должен быть блок `peer:` |
| Под `Pending` после `rollout restart` | Не должно случаться со `strategy: Recreate`; если случилось — стратегия снова `RollingUpdate`: `scale deployment/vpn-gateway --replicas=0` → дождаться удаления → `--replicas=1` (тот же приём, что для nginx) |
| Под `Running`, но `0/1` по прокси-контейнеру | Контейнер `proxy` ждёт wg0 (`wait`-цикл) либо его readiness (`nc 10.13.13.1 15432`) не проходит: wg0 не поднялся — смотрите логи `-c wireguard` (обычно нет ключа в Secret, см. первую строку) и `-c proxy` |
| Туннель поднимается, `wg show` без handshake | Проверьте `Endpoint` в конфиге: публичный IP узла `200.165.239.108` должен совпадать с текущим `EXTERNAL-IP` (`kubectl get nodes -o wide`); сменился IP — перевыпустите конфиг (`vpn-peer.sh add <имя> --reissue`) |
| `psql` через 15432 не подключается | Туннель работает, но сервис не слушает: `kubectl -n gross-view get endpoints postgres vault`. Также проверьте контейнер `proxy`: `kubectl -n gross-view logs deploy/vpn-gateway -c proxy` (в логе должен быть `[vpn-proxy] wg0 is up, starting nginx stream proxy`) |

---

## 12. Удалённые артефакты прокси-слоя (2026-10-07)

> **2026-10-08: прокси-слой восстановлен** — все три куска из этого раздела
> возвращены в манифесты дословно (`k8s/base/vpn-gateway-proxy-configmap.yaml`
> создан здесь впервые, контейнер `proxy`, `fsGroup: 101` и volume'ы — обратно
> в `vpn-gateway-deployment.yaml`, строка — обратно в `kustomization.yaml`).
> Раздел сохранён как историческая точка отсчёта текстов.

⚠️ Файл `k8s/base/vpn-gateway-proxy-configmap.yaml` **не был закоммичен** (лежал
только в индексе git) — при удалении из рабочего дерева он исчез бы из истории
безвозвратно. Поэтому его содержимое и вырезанные куски Deployment сохранены
здесь: это и есть инструкция по возврату прокси-слоя.

### 12.1. ConfigMap `vpn-gateway-proxy`

Файл `k8s/base/vpn-gateway-proxy-configmap.yaml` + строка
`- vpn-gateway-proxy-configmap.yaml` в `k8s/base/kustomization.yaml`:

```yaml
# nginx stream proxy that publishes the VPN-only ports of the vpn-gateway pod.
#
# This is the whole access-control surface of the tunnel: a client may only reach
# 10.13.13.1, and on that address ONLY these two ports exist. Pod CIDR
# (10.244.0.0/16) and Service CIDR (10.96.0.0/12) are deliberately NOT routed into
# the tunnel (clients get AllowedIPs = 10.13.13.1/32), so there is nothing else to
# reach even from inside the cluster network.
#
# The listen address is the wg0 address, NOT 0.0.0.0: the proxy must not become
# reachable from other pods in the cluster.
apiVersion: v1
kind: ConfigMap
metadata:
  name: vpn-gateway-proxy
  namespace: gross-view
  labels:
    app.kubernetes.io/name: vpn-gateway
    app.kubernetes.io/part-of: gross-view
data:
  nginx.conf: |
    # Minimal nginx config for the VPN access proxy (nginx:stable-alpine).
    worker_processes 1;
    error_log /var/log/nginx/error.log warn;
    pid /var/run/nginx.pid;

    events {
      worker_connections 256;
    }

    stream {
      # Resolve upstreams at connection time (like nginx/gross-view.local.conf does
      # for HTTP): a literal `proxy_pass host:port` is resolved once at config load,
      # so it would keep a stale pod IP after postgres/vault restart. `postgres` is a
      # headless Service, so it resolves straight to the current pod IP.
      resolver kube-dns.kube-system.svc.cluster.local valid=10s ipv6=off;
      resolver_timeout 5s;

      log_format vpn '$remote_addr [$time_local] $protocol $status '
                     'sent=$bytes_sent recv=$bytes_received '
                     'session=$session_time upstream=$upstream_addr';
      access_log /var/log/nginx/access.log vpn;

      # PostgreSQL 15/TimescaleDB over the tunnel.
      server {
        listen 10.13.13.1:15432;
        set $pg_upstream postgres.gross-view.svc.cluster.local:5432;
        proxy_pass $pg_upstream;
        proxy_connect_timeout 5s;
        # Long psql sessions / large dumps: do not cut idle connections.
        proxy_timeout 1h;
      }

      # HashiCorp Vault API + UI (plain HTTP inside the tunnel; Vault itself runs
      # with tls_disable = 1 in this cluster — see vault/vault-config.hcl).
      server {
        listen 10.13.13.1:18200;
        set $vault_upstream vault.gross-view.svc.cluster.local:8200;
        proxy_pass $vault_upstream;
        proxy_connect_timeout 5s;
        proxy_timeout 1h;
      }
    }
```

### 12.2. Контейнер `proxy` в `k8s/base/vpn-gateway-deployment.yaml`

Вставить обратно в `spec.template.spec.containers` **после** контейнера
`wireguard`:

```yaml
        - name: proxy
          image: dockerhub.timeweb.cloud/library/nginx:stable-alpine
          # Both containers share the pod network namespace, but they start in
          # parallel: wait for wg0 to carry 10.13.13.1, otherwise nginx fails to
          # bind the stream listen address and exits.
          command:
            - /bin/sh
            - -c
            - |
              set -eu
              echo "[vpn-proxy] waiting for wg0 (10.13.13.1)..."
              until ip -o -4 address show dev wg0 2>/dev/null | grep -q '10\.13\.13\.1/'; do
                sleep 1
              done
              echo "[vpn-proxy] wg0 is up, starting nginx stream proxy"
              exec nginx -g 'daemon off;'
          volumeMounts:
            - name: vpn-proxy
              mountPath: /etc/nginx/nginx.conf
              subPath: nginx.conf
              readOnly: true
            - name: proxy-logs
              mountPath: /var/log/nginx
            - name: proxy-cache
              mountPath: /var/cache/nginx
            - name: proxy-run
              mountPath: /var/run
          # BusyBox nc is used with a plain connect+close (no -z): the flag set differs
          # between busybox and other nc builds, and this form works with both.
          readinessProbe:
            exec:
              command: ["sh", "-c", "nc -w 2 10.13.13.1 15432 </dev/null >/dev/null 2>&1"]
            initialDelaySeconds: 10
            periodSeconds: 15
            timeoutSeconds: 5
            failureThreshold: 4
          resources:
            requests:
              cpu: 25m
              memory: 32Mi
            limits:
              cpu: 100m
              memory: 64Mi
```

### 12.3. Pod-level `securityContext` и volume'ы

В `spec.template.spec` перед `initContainers` (группа 101 = пользователь `nginx`
образа nginx:stable-alpine, чтобы emptyDirs прокси были ему writable):

```yaml
      securityContext:
        fsGroup: 101
```

В `spec.template.spec.volumes` (после `- name: vpn-config`):

```yaml
        - name: vpn-proxy
          configMap:
            name: vpn-gateway-proxy
            defaultMode: 0444
        - name: proxy-logs
          emptyDir: {}
        - name: proxy-cache
          emptyDir: {}
        - name: proxy-run
          emptyDir: {}
```

После восстановления всех трёх кусков: `kubectl apply -k .` (Deployment со
`strategy: Recreate` пересоберёт под без зависания на hostPort). Бюджет ресурсов
вернётся к `vpn-gateway 85m / 400m`, `112Mi / 320Mi` (см. AGENTS.md, таблицу
resource sizing — её нужно будет вернуть обратно).