# AGENTS.md

## Project Overview

This repository manages **infrastructure configuration** for the "gross-view" project. It contains Keycloak realm settings, Nginx reverse proxy configuration, VPN/secret/DNS infrastructure services (WireGuard, Vault, dnsmasq), and custom CSS styles for authentication forms.

> **Requirement:** any change to the repo (files, services, network, code, config) — from an agent or a human — **must** be reflected back into this file (structure, notes, IP map, new services, new conventions). After every modification, review AGENTS.md and update it if the change makes current instructions inaccurate or incomplete.

## Repository Structure

- `gross-view-realm.json` — Keycloak realm configuration (exported/imported)
- `docker-compose.yml` — Docker Compose stack: PostgreSQL, Keycloak, Nginx, n8n, WireGuard, Vault, dnsmasq
- `nginx/gross-view.local.conf` — Nginx site config for `gross-view.local`
- `dns/dnsmasq.conf` — Internal DNS (dnsmasq) config: static hostnames + `.local` aliases for all services on `172.28.0.0/24`
- `vault/config/vault.hcl` — HashiCorp Vault server config (file storage, TLS disabled in dev, `ui = true`)
- `.env.example` — Template for environment variables (gitignored `.env` holds secrets)
- `README.md` — Project documentation
- `themes/gross-view/` — Keycloak custom theme (login pages, messages, styles)
- `themes/gross-view/login/resources/css/login.css` — Custom CSS styles for authentication forms (login, registration, etc.)
- `themes/gross-view/login/resources/js/theme.js` — Applies the site's theme (`data-theme`) to the login page by reading the shared `localStorage` key `gross-view:theme`

## Purpose

This repo manages reverse proxy routing, Keycloak theme customizations, realm settings, VPN access, secrets storage, internal DNS, and multi-container orchestration. Nginx provides unified entry point routing `/sso` to Keycloak, `/api` to backend, and `/` to frontend. WireGuard serves as the secure VPN channel to non-public services (Postgres, Keycloak admin, n8n); Vault stores the stack's credentials (used when migrating to cloud K8s).

## Infrastructure Services

### Static network

- `keycloak_network` uses subnet `172.28.0.0/24` (bridge). Every service has a fixed IP — do not change without updating `dns/dnsmasq.conf`.
- IP map: postgres `172.28.0.2`, keycloak `172.28.0.3`, nginx `172.28.0.4`, n8n `172.28.0.5`, wireguard `172.28.0.6`, vault `172.28.0.7`, dns `172.28.0.8`.
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
- Secret paths currently populated: `secret/postgres`, `secret/keycloak`, `secret/n8n`, `secret/gross-view` (KV v2 engine).

### DNS (dnsmasq)

- Serves static `*.local` aliases (`postgres.local`, `db.local`, `auth.local`, ...) from `dns/dnsmasq.conf` and forwards external queries to 8.8.8.8/8.8.4.4.
- Exposes host ports 53 tcp/udp. Clients use it by pointing their resolver at `172.28.0.8`.

## Important Notes

- Nginx config changes affect routing for the entire `gross-view.local` site
- CSS changes affect the visual appearance of Keycloak login/registration screens
- Realm JSON should only be modified carefully — it defines clients, roles, mappers, and identity providers
- Do not add application source code here — this is configuration-only
- When editing `login.css`, ensure compatibility with Keycloak's FreeMarker templates (IDs/classes used in forms may vary by Keycloak version)
- `login.css` supports light/dark via the `data-theme` attribute on `<html>`; keep the semantic tokens (`--color-surface`, `--color-body-bg`, `--color-on-accent`, `--color-accent`, status tokens) in `:root` and the `[data-theme='dark']` block in sync with `src/app/index.css` of gross-view-ui
- The theme is applied to the login page by `js/theme.js` (declared via `scripts=` in `theme.properties`); its storage key must match `THEME_STORAGE_KEY` in `src/features/theme/model.ts` of gross-view-ui
- Do not commit or log: `WG_*` secrets in `.env`, `wireguard_config` generated peer/private keys, Vault unseal keys, Vault root token, or contents of `.env` / `certs/`

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
