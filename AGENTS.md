# AGENTS.md

## Project Overview

This repository manages **infrastructure configuration** for the "gross-view" project. It contains Keycloak realm settings, Nginx reverse proxy configuration, VPN/secret/DNS infrastructure services (WireGuard, Vault, dnsmasq), and custom CSS styles for authentication forms.

> **Requirement:** any change to the repo (files, services, network, code, config) — from an agent or a human — **must** be reflected back into this file (structure, notes, IP map, new services, new conventions). After every modification, review AGENTS.md and update it if the change makes current instructions inaccurate or incomplete.

## Repository Structure

- `gross-view-realm.json` — Keycloak realm configuration (exported/imported)
- `docker-compose.yml` — Docker Compose stack: PostgreSQL, Keycloak, Nginx, opencode, WireGuard, Vault, dnsmasq
- `kustomization.yaml` — Root Kustomize build generating Keycloak theme + realm ConfigMaps (apply with `kubectl apply -k .`)
- `k8s/` — Kubernetes manifests (alternative to docker-compose for cloud/K8s deployment)
  - `k8s/base/` — Namespace, Secrets, and per-service Deployments/StatefulSets/Services/ConfigMaps (nginx + certbot included; Ingress kept for reference only)
- `nginx/gross-view.local.conf` — Nginx site config for `gross-view.local` (docker-compose; in K8s mirrored by `k8s/base/nginx-configmap.yaml` for production `mint-box.ru`)
- `dns/dnsmasq.conf` — Internal DNS (dnsmasq) config: static hostnames + `.local` aliases for all services on `172.28.0.0/24`
- `vault/config/vault.hcl` — HashiCorp Vault server config (file storage, TLS disabled in dev, `ui = true`)
- `.env.example` — Template for environment variables (gitignored `.env` holds secrets)
- `README.md` — Project documentation
- `themes/gross-view/` — Keycloak custom theme (login pages, messages, styles)
- `themes/gross-view/login/resources/css/login.css` — Custom CSS styles for authentication forms (login, registration, etc.)
- `themes/gross-view/login/resources/js/theme.js` — Applies the site's theme (`data-theme`) to the login page by reading the shared `localStorage` key `gross-view:theme`

## Purpose

This repo manages reverse proxy routing, Keycloak theme customizations, realm settings, VPN access, secrets storage, internal DNS, and multi-container orchestration. Nginx provides unified entry point routing `/sso` to Keycloak, `/api` to backend, and `/` to frontend. WireGuard serves as the secure VPN channel to non-public services (Postgres, Keycloak admin, opencode); Vault stores the stack's credentials (used when migrating to cloud K8s).

## Infrastructure Services

### Static network

- `keycloak_network` uses subnet `172.28.0.0/24` (bridge). Every service has a fixed IP — do not change without updating `dns/dnsmasq.conf`.
- IP map: postgres `172.28.0.2`, keycloak `172.28.0.3`, nginx `172.28.0.4`, opencode `172.28.0.5`, wireguard `172.28.0.6`, vault `172.28.0.7`, dns `172.28.0.8`.
- `172.20.x`, `172.19.x`, `172.18.x` are taken by the host/WSL and other Docker networks — avoid them.

### WireGuard (VPN)

- Uses `lscr.io/linuxserver/wireguard` in **server mode**; generates server + peer configs and QR codes. Runs on `172.28.0.6`, exposes `51820:51820/udp`.
- Public host IP/domain via `WG_SERVERURL` in `.env` (`auto` lets the container detect it). Number/names of clients via `WG_PEERS`.
- Peer configs/QR codes are written to the `wireguard_config` volume at `/config/peerX` and printed to the container log (`LOG_CONFS=true`).
- Split tunneling: `ALLOWEDIPS=172.28.0.0/24,10.13.13.1` — clients reach only internal services, not full traffic. Clients get `PEERDNS=172.28.0.8` (the internal dnsmasq) so they can resolve `*.local` names.
- For remote clients the upstream router/Mikrotik must forward `UDP 51820` to the Docker host.
- Requires capability `NET_ADMIN` (creates `wg0` interface); `SYS_MODULE` + `/lib/modules` optional if the `wireguard` kernel module isn't already loaded. Works on WSL2/Linux and as client on Win/macOS/mobile.

### Vault (secrets)

- Uses file storage (`/vault/data`), mlock disabled, TLS disabled (dev). After any restart the container is **sealed** — manual `vault operator unseal <UNSEAL_KEY>` is required.
- Unseal key and root token are generated on first `vault operator init` and must be kept outside the repo (they are NOT in `.env`).
- Secret paths currently populated: `secret/postgres`, `secret/keycloak`, `secret/opencode`, `secret/gross-view` (KV v2 engine).

### DNS (dnsmasq)

- Serves static `*.local` aliases (`postgres.local`, `db.local`, `auth.local`, ...) from `dns/dnsmasq.conf` and forwards external queries to 8.8.8.8/8.8.4.4.
- Exposes host ports 53 tcp/udp. Clients use it by pointing their resolver at `172.28.0.8`.

## Important Notes

- Nginx config changes affect routing for the entire `gross-view.local` site. In K8s the routing lives in `k8s/base/nginx-configmap.yaml` (production domain `mint-box.ru`); `k8s/base/ingress.yaml` (ingress-nginx) is kept for reference only and is excluded from the kustomize build — keep the nginx config and ingress in sync if either is changed. Changes to the nginx ConfigMap require a Deployment rollout: `kubectl -n gross-view rollout restart deployment/nginx`.
- CSS changes affect the visual appearance of Keycloak login/registration screens
- Realm JSON should only be modified carefully — it defines clients, roles, mappers, and identity providers
- Do not add application source code here — this is configuration-only
- When editing `login.css`, ensure compatibility with Keycloak's FreeMarker templates (IDs/classes used in forms may vary by Keycloak version)
- `login.css` supports light/dark via the `data-theme` attribute on `<html>`; keep the semantic tokens (`--color-surface`, `--color-body-bg`, `--color-on-accent`, `--color-accent`, status tokens) in `:root` and the `[data-theme='dark']` block in sync with `src/app/index.css` of gross-view-ui
- The theme is applied to the login page by `js/theme.js` (declared via `scripts=` in `theme.properties`); its storage key must match `THEME_STORAGE_KEY` in `src/features/theme/model.ts` of gross-view-ui
- Keycloak hostname: `kc-hostname` or `KC_HOSTNAME_URL`/`KC_HOSTNAME_ADMIN_URL` in `k8s/base/keycloak-deployment.yaml` point at `https://mint-box.ru/sso` (production). docker-compose (local dev) keeps `gross-view.local` values. The realm's redirectUris contain both `gross-view.local` and `mint-box.ru` — keep these in sync when changing domains.
- Do not commit or log: `WG_*` secrets in `.env`, `wireguard_config` generated peer/private keys, Vault unseal keys, Vault root token, or contents of `.env` / `certs/`

## Kubernetes (K8s) deployment

The `k8s/` directory mirrors the docker-compose stack for cloud/K8s. Both describe the same services; keep them in sync.

- Apply with `kubectl apply -k .` from the repo root. The **root** `kustomization.yaml` uses `configMapGenerator` to embed the Keycloak theme (`themes/gross-view/`) and realm (`gross-view-realm.json`) into ConfigMaps because kustomize cannot reference files outside its own directory.
- Service → manifest mapping (all in `gross-view` namespace):
  - postgres → `k8s/base/postgres-statefulset.yaml` (StatefulSet + headless `Service` + `volumeClaimTemplates`, `postgres-init` ConfigMap for init scripts)
  - keycloak → `k8s/base/keycloak-deployment.yaml` (Deployment + `Service`, mounts generated `keycloak-theme` / `keycloak-realm` ConfigMaps). The theme ConfigMap is flat (keys without `/`); each theme file is mounted with `subPath` to its nested path under `/opt/keycloak/themes/login/...` (ConfigMap data keys cannot contain `/`). Keep the root `kustomization.yaml` configMapGenerator file keys (`theme.properties`, `login.properties`, `login_en.properties`, `login_ru.properties`, `login.css`, `theme.js`) and the keycloak-deployment subPath mounts in sync when adding theme files.
  - nginx → `k8s/base/nginx-deployment.yaml` (+ `nginx-configmap.yaml`, `nginx-service.yaml`, `tls-secret.yaml`) — Deployment + LoadBalancer `Service` (80/443), the TLS-terminating entry point; config mirrors `nginx/gross-view.local.conf` for production domain `mint-box.ru`. `k8s/base/ingress.yaml` exists for reference but is NOT in the kustomize build (would conflict on node ports 80/443)
  - certbot → `k8s/base/certbot-cronjob.yaml` (+ `certbot-pvc.yaml`, `certbot-rbac.yaml`) — daily CronJob issuing/renewing the Let's Encrypt cert for `mint-box.ru` via HTTP-01 (webroot on the `certbot-data` PVC shared with nginx). On renewal it writes the `mint-box-tls` Secret and rolls the nginx Deployment
  - opencode → `k8s/base/opencode-deployment.yaml` (Deployment + `Service` + `opencode-data` PVC). Uses `ghcr.io/anomalyco/opencode` in web mode; file-based storage (no DB). Requires `OPENCODE_SERVER_PASSWORD` and `ANTHROPIC_API_KEY` secrets. `BROWSER=none` disables the headless `xdg-open` error on startup.
  - vault → `k8s/base/vault-statefulset.yaml` (StatefulSet + `Service` + `volumeClaimTemplates`, `vault-config` ConfigMap with vault.hcl). Capabilities (`IPC_LOCK`), like WireGuard's `NET_ADMIN`/`SYS_MODULE`, live in the **container** `securityContext` (`spec.template.spec.containers[].securityContext`), not the pod-level one — `capabilities` is not a valid pod-securityContext field.
  - wireguard → `k8s/base/wireguard-deployment.yaml` (Deployment + LoadBalancer `Service` UDP 51820, privileged + NET_ADMIN/SYS_MODULE)
  - dns → `k8s/base/dnsmasq-deployment.yaml` (Deployment + `Service` 53/tcp+udp, `dnsmasq-config` ConfigMap)
- Secrets: `k8s/base/secret.yaml` holds placeholder values (`changeme`) in a single `gross-view-secrets` Secret. Fill real values before applying; for production use ExternalSecrets/Vault instead.
- Images: DockerHub is not directly reachable from the Moscow DC, so all Docker Hub images in the manifests are pulled via the Russian mirror `dockerhub.timeweb.cloud` (prefix `dockerhub.timeweb.cloud/`, e.g. `dockerhub.timeweb.cloud/library/nginx:stable-alpine`). Images from other registries stay as-is: `ghcr.io/anomalyco/opencode`, `quay.io/keycloak/keycloak`, `lscr.io/linuxserver/wireguard`. When adding/updating a container image, keep the DockerHub→mirror prefix convention.
- TLS: in K8s the nginx pod terminates TLS using the `mint-box-tls` Secret. `k8s/base/tls-secret.yaml` creates a **bootstrap placeholder** `mint-box-tls` (self-signed cert for `mint-box.ru`) so the nginx pod can start before certbot has run. The certbot CronJob then overwrites this Secret with the real Let's Encrypt certificate (`kubectl create secret tls ... --dry-run=client -o yaml | kubectl apply -f -`) and rolls the nginx Deployment. Do not store real certs in the repo. The cert is issued for **`mint-box.ru` only** — `www.mint-box.ru` has no A record and is deliberately excluded from both the certbot `-d` list and the nginx `server_name` (see the LoadBalancer note below). Live cert issued 2026-09-06 (expires 2026-12-05); the certbot-cronjob deploy-hook writes the `mint-box-tls` Secret and patches nginx to roll it. The init container copies `kubectl` from `dockerhub.timeweb.cloud/lachlanevenson/k8s-kubectl:latest` — the version-pinned tag `:v1.28.4` does **not** exist on the mirror (ImagePullBackOff), use `:latest`.
- nginx upstream resolution: `k8s/base/nginx-configmap.yaml` resolves `keycloak`, `gross-view-api`, `gross-view-ui` **at request time** via `resolver kube-dns.kube-system.svc.cluster.local` + `set $..._upstream` variables in `proxy_pass`, so nginx starts even when those Services aren't deployed yet (a static `proxy_pass http://keycloak:8080` would abort startup with `[emerg] host not found in upstream`). This lets the stack be rolled out incrementally. Note: nginx does NOT resolve `<host>` in front of a `$variable` proxy_pass the same way — variable names must not contain `-`; use underscores. Readiness/liveness probes hit `GET /healthz` (served by nginx itself, 200), NOT `/` (which 301-redirects), so probes stay green before backends exist.
- Storage: `k8s/base/storageclass.yaml` declares `standard` (`rancher.io/local-path`, `WaitForFirstConsumer`) as default. The **cluster must run the Rancher local-path-provisioner** for PVCs to bind — k0s does NOT ship one by default, so on a fresh cluster install it first (e.g. `kubectl apply -f` the rancher/local-path-provisioner `deploy/local-path-storage.yaml`; keep the DockerHub→timeweb mirror convention for its images). Until it is installed, any `certbot-data`-like PVC stays `Pending` and dependent pods stay unscheduled.
- Cluster-specific changes (StorageClass, replicas, WireGuard CIDRs) are applied by adding `patches` to the root `kustomization.yaml`. A nested `k8s/overlays` directory is NOT possible: kustomize forbids an overlay inside the repo root from including the root kustomization (cycle), and `configMapGenerator` cannot reach theme/realm files outside its own directory, so the root is the single build point.
- The cluster on Timeweb is **self-managed k0s** (single worker `worker-192.168.132.5`, k0s) with the Timeweb Cloud LoadBalancer controller (`k8s.timeweb.cloud/*` annotations) attached out-of-band (no controller pod in-cluster) — it provisions a **Timeweb balancer device** from each `LoadBalancer` Service. For a Service to get balancer rules, **every port needs `name` + `appProtocol` (e.g. `k8s.timeweb.cloud/proto-tcp`); without `appProtocol` the controller builds only one rule for the first port** (this was the cause of missing 443). `k8s/base/nginx-service.yaml` uses TCP passthrough (`proto-tcp`) on 80/443 so nginx keeps terminating TLS and serving ACME; the balancer does NOT terminate TLS. See https://timeweb.cloud/docs/k8s/network/kubernetes-load-balancer
- ⚠️ **Timeweb LoadBalancer health-check targets the node's port 80, NOT the NodePort.** Diagnosed 2026-09-06 via `tcpdump` on the node's `eth1`: the balancer (private IP `192.168.132.6`) probes the backend on `192.168.132.5:80` with a bare TCP connect (~every 30s) regardless of the `nginx` Service's `NodePort` (30571/30868). Nothing listened on host port 80 → SYN-ACK was answered with **RST** → backend marked "unavailable" → balancer dropped all traffic. **Fix:** `nginx-deployment.yaml` exposes the nginx container on `hostPort: 80`, so host port 80 is DNAT'd to the nginx pod whose `location /` returns 200. Keep `hostPort: 80` on the nginx container — removing it re-breaks the balancer health check. After this fix the balancer public IP `200.165.238.21` serves HTTP 200 on `/` and `/healthz`; `mint-box.ru` A-record points at the balancer's `EXTERNAL-IP` (`kubectl -n gross-view get svc nginx`), currently `200.165.238.21`. `www.mint-box.ru` has no A record (NXDOMAIN) and is intentionally not covered by the cert/nginx. certbot HTTP-01 validation succeeded 2026-09-06 — `https://mint-box.ru/healthz` returns 200 with a trusted Let's Encrypt chain, `https://mint-box.ru/sso` proxies to keycloak (301), `http://mint-box.ru/` returns 200 (meta-refresh redirect for the balancer health check).
- ⚠️ **Single-node `hostPort: 80` rollout deadlock.** Because nginx uses `hostPort: 80` and the cluster has one worker, `kubectl rollout restart deployment/nginx` or any nginx ReplicaSet change gets **stuck**: the new pod can't schedule (host port 80 still held by the old pod) and the old pod won't terminate until the new one is Ready — 0/1 Unschedulable, "didn't have free ports". Workaround when this happens: `kubectl -n gross-view scale deployment/nginx --replicas=0`, wait for pods to clear, then `--replicas=1`. The certbot deploy-hook (which `patch`es the Deployment) triggers this each renewal on a single node, so expect to run the scale 0→1 dance after each cert update.
- The static `172.28.0.0/24` IPs in `dns/dnsmasq.conf` and WireGuard `PEERDNS`/`ALLOWEDIPS` are Docker-era and do NOT apply to K8s (dynamic pod IPs). In K8s prefer the cluster's CoreDNS (`<svc>.<ns>.svc.cluster.local`) and update WireGuard ALLOWEDIPS to the pod/service CIDR.

## StatefulSet volumeClaimTemplates (immutable)

- `volumeClaimTemplates` in a StatefulSet is **immutable** after creation. Changing it
  (e.g. adding/removing `storageClassName`, size, accessModes) causes
  `Forbidden: updates to statefulset spec ... are forbidden` on `kubectl apply -k`.
- Postgres and vault StatefulSets deliberately do NOT set `storageClassName` so the
  PVCs pick up the cluster's default StorageClass; do not re-add it. To force a
  specific StorageClass on a fresh cluster, recreate the StatefulSet with
  `kubectl delete statefulset <name> --cascade=orphan` (and its PVCs) first, or use
  a kustomize patch only on a cluster where the StatefulSet has never been created.

## Test cluster resource sizing

The test cluster runs on a single node: **1 CPU / 2 GB RAM / 30 GB NVMe**. All K8s manifests set CPU and memory **requests and limits** to fit within this budget. Total requests are ~560m CPU / ~1104Mi RAM, leaving headroom for system overhead (kubelet, OS, container runtime). When adding or modifying containers, verify the sum of all requests does not exceed ~800m CPU / ~1500Mi RAM to keep the scheduler happy.

| Service | CPU req/lim | Mem req/lim |
|---------|-------------|-------------|
| nginx | 50m / 100m | 32Mi / 64Mi |
| postgres | 150m / 200m | 448Mi / 512Mi |
| keycloak | 200m / 250m | 384Mi / 384Mi |
| opencode | 75m / 150m | 128Mi / 256Mi |
| vault | 50m / 100m | 64Mi / 128Mi |
| wireguard | 25m / 50m | 32Mi / 64Mi |
| dnsmasq | 10m / 25m | 16Mi / 32Mi |

## Available Skills

Skills provide specialized instructions and workflows for specific tasks.
Use the skill tool to load a skill when a task matches its description.

<available_skills>
  <skill>
    <name>docker-compose</name>
    <description>Use when managing Docker Compose configurations for multi-container environments. Covers service definitions, volumes, networks, environment variables, health checks, and orchestration of containers like Keycloak, databases, and reverse proxies.</description>
    <location>&lt;built-in&gt;</location>
  </skill>
  <skill>
    <name>postgresql-configuration</name>
    <description>Use when configuring PostgreSQL database settings, including connection pooling, performance tuning, backup strategies, user roles, and authentication methods. Applicable for database setup and optimization tasks.</description>
    <location>&lt;built-in&gt;</location>
  </skill>
  <skill>
    <name>nginx-configuration</name>
    <description>Use when configuring Nginx as a reverse proxy, load balancer, or web server. Covers server blocks, SSL/TLS setup, proxy pass directives, caching, rate limiting, and security headers.</description>
    <location>&lt;built-in&gt;</location>
  </skill>
</available_skills>
