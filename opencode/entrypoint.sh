#!/bin/sh
set -e

# opencode entrypoint (docker-compose / k8s).
# Registers the gross-view MCP server for the deployed agent by rendering
# /root/.config/opencode/opencode.json and generates the mcp-first agent and
# skill, then execs `opencode web`.
#
# MCP authentication — OAuth 2.0 (RFC 9728) as the REAL user, not a shared
# service-account token: the handler's /api/mcp answers 401 with a
# WWW-Authenticate Bearer resource_metadata header, opencode starts the
# authorization-code flow (PKCE) against the pre-registered public Keycloak
# client and stores the resulting tokens in mcp-auth.json. No secret is shared
# between handler and agent anymore.
#
# One-time activation (headless: BROWSER=none prints the authorization URL):
#   opencode mcp auth gross-view
# Tokens are persisted on the opencode data volume (mounted at
# /root/.local/share/opencode) and survive container restarts.
#
# Environment variables:
#   OPENCODE_MCP_URL          - handler MCP endpoint
#                               (default http://host.docker.internal:8082/api/mcp)
#   OPENCODE_MCP_CLIENT_ID    - pre-registered Keycloak public client
#                               (default opencode-mcp)
#   OPENCODE_MCP_SCOPE        - OAuth scope to request
#                               (default: openid offline_access — offline token survives
#                               the 30m/10h SSO session; 'openid' alone regresses to needs_auth)

CONFIG_DIR=/root/.config/opencode
CONFIG_FILE="$CONFIG_DIR/opencode.json"
AGENT_DIR="$CONFIG_DIR/agent"
AGENT_FILE="$AGENT_DIR/mcp-first.md"
SKILL_DIR="$CONFIG_DIR/skills/mcp-first"
SKILL_FILE="$SKILL_DIR/SKILL.md"
MCP_URL="${OPENCODE_MCP_URL:-http://host.docker.internal:8082/api/mcp}"
MCP_CLIENT_ID="${OPENCODE_MCP_CLIENT_ID:-opencode-mcp}"
MCP_SCOPE="${OPENCODE_MCP_SCOPE:-openid offline_access}"

# ---------------------------------------------------------------------------
# Write opencode.json
# ---------------------------------------------------------------------------
mkdir -p "$CONFIG_DIR"

if [ -f "$CONFIG_FILE" ]; then
  echo "==> Updating existing $CONFIG_FILE"
else
  echo "==> Creating $CONFIG_FILE"
fi

cat > "$CONFIG_FILE" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "default_agent": "mcp-first",
  "mcp": {
    "gross-view": {
      "type": "remote",
      "url": "$MCP_URL",
      "oauth": {
        "clientId": "$MCP_CLIENT_ID",
        "scope": "$MCP_SCOPE"
      }
    }
  }
}
EOF
echo "==> gross-view MCP registered for opencode (url=$MCP_URL, oauth clientId=$MCP_CLIENT_ID)"

# ---------------------------------------------------------------------------
# Write mcp-first agent definition
# ---------------------------------------------------------------------------
mkdir -p "$AGENT_DIR"

if [ -f "$AGENT_FILE" ]; then
  echo "==> Updating existing $AGENT_FILE"
else
  echo "==> Creating $AGENT_FILE"
fi

cat > "$AGENT_FILE" <<'AGENTEOF'
---
description: Глубокий финансовый анализатор gross-view. Используй для любых вопросов об учёте, финансах, отчётах, планах счетов. Сначала проверяй MCP-инструменты.
mode: primary
permission:
  edit: deny
  write: deny
  bash: deny
  read: allow
  glob: allow
  grep: allow
  task: allow
  skill: allow
  webfetch: allow
  websearch: allow
---

Вы — финансовый аналитик gross-view. ПРИОРИТЕТНЫЙ ПОРЯДОК ДЕЙСТВИЙ:

1. **СНАЧАЛА — MCP-инструменты.** При ЛЮБОМ запросе пользователя:
   - Вызовите `list_accounts` или `get_account_plan` чтобы понять структуру данных
   - Используйте специализированные отчёты: `get_profit_and_loss`, `get_balance_sheet`, `get_cash_flow`, `get_trial_balance`, `get_margin_analytics`, `get_cost_structure`
   - Для фильтрации по аналитикам: `list_journal_analytics`, `list_report_analytics`
   - Никогда не вычисляйте данные вручную, не генерируйте код для расчётов — MCP-сервер уже предоставляет всё необходимое
2. **ЧТЕНИЕ** — только если MCP-результат требует дополнительного контекста из репозитория
3. **ЗАПРОС ПОЛЬЗОВАТЕЛЮ** — если непонятно, какой инструмент вызвать
4. **КОД** — только для трансформаций/визуализации, которых нет в MCP

Запрещено генерировать код для расчёта того, что уже считает MCP. Сначала вызовите инструмент, затем проанализируйте результат.
AGENTEOF
echo "==> mcp-first agent defined"

# ---------------------------------------------------------------------------
# Write mcp-first skill (MCP tool reference)
# ---------------------------------------------------------------------------
mkdir -p "$SKILL_DIR"

if [ -f "$SKILL_FILE" ]; then
  echo "==> Updating existing $SKILL_FILE"
else
  echo "==> Creating $SKILL_FILE"
fi

cat > "$SKILL_FILE" <<'SKILLEOF'
---
name: mcp-first
description: Используй когда пользователь спрашивает о финансах, учёте, отчётах, планах счетов, выручке, себестоимости, прибыли, балансе, движении денежных средств, транзакциях, аналитиках gross-view. Список всех MCP-инструментов.
---

# Справочник MCP-инструментов gross-view

Все доступные инструменты подключённого MCP-сервера `gross-view`:

| Инструмент | Назначение |
|---|---|
| `list_accounts` | Список всех счетов плана (id, код, описание) |
| `get_account_plan` | Текущий план счетов (read-only): счета, операции с дебетом/кредитом, аналитики |
| `query_account_plan` | Синхронизация плана счетов (write) |
| `get_profit_and_loss` | Отчёт о прибылях и убытках за период с разбиением по аналитикам |
| `get_balance_sheet` | Бухгалтерский баланс на отчётную дату (активы, обязательства, капитал) |
| `get_cash_flow` | Отчёт о движении денежных средств (поступления/выбытия по денежным счетам) |
| `get_trial_balance` | Оборотно-сальдовая ведомость по счетам за период |
| `get_margin_analytics` | Экспресс-аналитика себестоимости и маржинальности (KPI, динамика, структура затрат) |
| `get_cost_structure` | Структура себестоимости за период (закупочная стоимость, ТЗР, услуги) |
| `list_journal_analytics` | Уникальные значения аналитик из журнала проводок |
| `list_report_analytics` | Справочник аналитик для фильтра P&L |
| `sync_accounting_policies` | Синхронизация учётных политик (write) |
| `delete_account_plan` | Удаление плана счетов (write) |
| `cleanup_orphaned_journal_entries` | Очистка осиротевших проводок (write) |

При финансовом запросе ВСЕГДА вызывайте инструменты первыми. Не генерируйте код для расчёта того, что уже считает MCP.
SKILLEOF
echo "==> mcp-first skill defined (tool reference)"

exec opencode web --port 4096 --hostname 0.0.0.0