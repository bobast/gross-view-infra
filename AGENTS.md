# AGENTS.md

## Project Overview

This repository manages **infrastructure configuration** for the "gross-view" project. It contains Keycloak realm settings, Nginx reverse proxy configuration, and custom CSS styles for authentication forms.

## Repository Structure

- `gross-view-realm.json` — Keycloak realm configuration (exported/imported)
- `docker-compose.yml` — Docker Compose stack: PostgreSQL, Keycloak, Nginx
- `nginx/gross-view.local.conf` — Nginx site config for `gross-view.local`
- `README.md` — Project documentation
- `themes/gross-view/` — Keycloak custom theme (login pages, messages, styles)
- `themes/gross-view/login/resources/css/login.css` — Custom CSS styles for authentication forms (login, registration, etc.)
- `themes/gross-view/login/resources/js/theme.js` — Applies the site's theme (`data-theme`) to the login page by reading the shared `localStorage` key `gross-view:theme`

## Purpose

This repo manages reverse proxy routing, Keycloak theme customizations, realm settings, and multi-container orchestration. Nginx provides unified entry point routing `/sso` to Keycloak, `/api` to backend, and `/` to frontend.

## Important Notes

- Nginx config changes affect routing for the entire `gross-view.local` site
- CSS changes affect the visual appearance of Keycloak login/registration screens
- Realm JSON should only be modified carefully — it defines clients, roles, mappers, and identity providers
- Do not add application source code here — this is configuration-only
- When editing `login.css`, ensure compatibility with Keycloak's FreeMarker templates (IDs/classes used in forms may vary by Keycloak version)
- `login.css` supports light/dark via the `data-theme` attribute on `<html>`; keep the semantic tokens (`--color-surface`, `--color-body-bg`, `--color-on-accent`, `--color-accent`, status tokens) in `:root` and the `[data-theme='dark']` block in sync with `src/app/index.css` of gross-view-ui
- The theme is applied to the login page by `js/theme.js` (declared via `scripts=` in `theme.properties`); its storage key must match `THEME_STORAGE_KEY` in `src/features/theme/model.ts` of gross-view-ui

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
