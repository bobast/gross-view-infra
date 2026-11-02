#!/bin/sh
set -e

# opencode entrypoint (docker-compose / k8s).
# Generates the mcp-first agent and skill reference, writes
# /root/.config/opencode/opencode.json, then execs `opencode web`.
#
# MCP-подключение агента к MCP-сервису handler-а (/api/mcp) НЕ настраивается здесь
# статично. Одно подключение регистрируется на пару «пользователь + пространство»
# динамически gross-view-handler через POST /mcp с заголовками:
#   Authorization: Bearer <mcp-jwt>
#   X-Workspace-Id: <workspaceId>
# (<mcp-jwt> выпускается handler-ом по токену из заголовка запроса пользователя —
# Keycloak Token Exchange RFC 8693, audience=mcp). Имя сервера детерминировано парой:
# gross-view-<workspaceId>-<userHash>.
#
# Регистрация выполняется только при OPENCODE_MCP_SHARED_AGENT=true на handler-е
# (по умолчанию false: POST /mcp в opencode глобальный для процесса, поэтому
# per-user серверы видны всем диалогам; в debug-профиле локальной однопользовательской
# установки включено). Без этого инструментов gross-view-* в сессии нет.
#
# Статичного общего OAuth-сервера (opencode mcp auth gross-view) у развёрнутого
# агента БОЛЬШЕ НЕТ — общий shared-контур нарушал изоляцию сессий. Локальный CLI
# пользователя по-прежнему может подключаться вручную через свой opencode.json
# (публичный Keycloak-клиент opencode-mcp и callback 127.0.0.1:19876 сохранены).

CONFIG_DIR=/root/.config/opencode
CONFIG_FILE="$CONFIG_DIR/opencode.json"
AGENT_DIR="$CONFIG_DIR/agent"
AGENT_FILE="$AGENT_DIR/mcp-first.md"
SKILL_DIR="$CONFIG_DIR/skills/mcp-first"
SKILL_FILE="$SKILL_DIR/SKILL.md"

# ---------------------------------------------------------------------------
# LLM provider credentials sanity check
# ---------------------------------------------------------------------------
# Provider keys arrive as env vars (Vault -> ESO -> Secret `gross-view-secrets`
# -> secretKeyRef, see k8s/base/opencode-deployment.yaml). A placeholder value
# is TRUTHY, so opencode treats the provider as configured and the
# misconfiguration only surfaces later as an opaque provider 401
# ("Your api key: ****_KEY is invalid", diagnosed 2026-10-27). Warn loudly but
# do NOT fail — a crash loop would hide the whole agent. Values are never
# logged, only the variable name and the reason.
check_provider_key() {
  _name="$1"
  _value="$2"
  if [ -z "$_value" ]; then
    echo "WARN: ${_name} is empty — the provider will report missing credentials" >&2
    return 0
  fi
  case "$_value" in
    changeme*|change_me*|REPLACE_WITH_*|*PLACEHOLDER*)
      echo "WARN: ${_name} still holds a placeholder — LLM calls will fail with 401." >&2
      echo "      Write the real key into secret/gross-view and run scripts/rotate-llm-key.sh" >&2
      ;;
  esac
}
check_provider_key DEEPSEEK_API_KEY "${DEEPSEEK_API_KEY:-}"
check_provider_key OPENAI_API_KEY "${OPENAI_API_KEY:-}"
check_provider_key ANTHROPIC_API_KEY "${ANTHROPIC_API_KEY:-}"
check_provider_key OPENROUTER_API_KEY "${OPENROUTER_API_KEY:-}"
check_provider_key GOOGLE_API_KEY "${GOOGLE_API_KEY:-}"
check_provider_key GROQ_API_KEY "${GROQ_API_KEY:-}"
check_provider_key MISTRAL_API_KEY "${MISTRAL_API_KEY:-}"
check_provider_key XAI_API_KEY "${XAI_API_KEY:-}"
unset _name _value

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
  "default_agent": "mcp-first"
}
EOF
echo "==> opencode.json written (MCP-сервер регистрируется handler-ом на пару пользователь+пространство)"

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
   - Проводки журнала за период — `list_journal_entries` (фильтры: `documentId`, `operationId`, `accountCode`, аналитики, лимит); `returned=0, hasMore=false` означает, что проводок нет
   - Используйте специализированные отчёты: `get_profit_and_loss`, `get_balance_sheet`, `get_cash_flow`, `get_trial_balance`, `get_margin_analytics`, `get_cost_structure`, `get_product_cost_structure`
   - Для фильтрации по аналитикам: `list_journal_analytics`, `list_report_analytics`
   - Никогда не вычисляйте данные вручную, не генерируйте код для расчётов — MCP-сервер уже предоставляет всё необходимое
   - MCP-сервер подключён handler-ом на пару «пользователь + пространство» и носит префикс `gross-view-<workspaceId>-<userHash>_<tool>` — ищите доступные инструменты в текущей сессии по суффиксу имени (например `..._get_account_plan`), не по статичному имени `gross-view`. Если таких инструментов нет вообще — MCP отключён на handler-е (`OPENCODE_MCP_SHARED_AGENT=false`) или сервер ещё не зарегистрирован
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

MCP-сервер подключается handler-ом динамически на пару «пользователь +
пространство» и носит имя `gross-view-<workspaceId>-<userHash>`; инструменты
в текущей сессии доступны с префиксом `<server>_<tool>` (например
`gross-view-..._list_accounts`). Если инструментов с таким префиксом нет вообще —
MCP отключён на handler-е (`OPENCODE_MCP_SHARED_AGENT=false`, безопасный режим
мультитенантной установки) либо сервер ещё не зарегистрирован; это не ошибка
истёкшей сессии.

| Инструмент | Назначение |
|---|---|
| `list_accounts` | Счета плана (id, код, описание, тип) |
| `get_account_plan` | Текущий план: счета и операции (read-only) |
| `query_account_plan` | Синхронизация плана счетов (write) |
| `sync_accounting_policies` | Совместная синхронизация учётных политик (write) |
| `delete_account_plan` | Удаление плана счетов (write) |
| `cleanup_orphaned_journal_entries` | Очистка осиротевших проводок (write, ADMIN) |
| `get_profit_and_loss` | P&L за период в разрезе аналитик |
| `get_balance_sheet` | Бухгалтерский баланс на отчётную дату |
| `get_cash_flow` | Движение денежных средств за период |
| `get_trial_balance` | Оборотно-сальдовая ведомость по счетам |
| `get_cost_structure` | Структура себестоимости по статьям затрат |
| `get_product_cost_structure` | Затраты и прибыль в разрезе SKU/offerId |
| `get_margin_analytics` | KPI и динамика маржинальности |
| `list_journal_entries` | **Проводки журнала за период** (фильтры: документ, операция, план, счёт, аналитики; лимит) |
| `delete_journal_entries` | Удаление проводок периода (write, ADMIN; по умолчанию dryRun) |
| `list_journal_analytics` | Значения аналитик журнала по всем пространствам пользователя |
| `list_report_analytics` | Справочник аналитик для фильтра P&L |
| `build_financial_report` | Отчёт в виде таблицы/диаграммы (ReportView) |
| `list_report_views` | Справочник видов отчётов и диаграмм |
| `import_ozon_finance` | Импорт начислений Ozon (write) |
| `import_ozon_fbo` | Импорт отправлений FBO (write) |
| `import_first_mile_batches` | Регистрация партий первой мили (write) |
| `list_first_mile_batches` | Остатки партий FIFO |
| `upsert_product_prices` | Закупочные цены (write) |
| `list_product_prices` | Закупочные цены |
| `analyze_document_file` | Распознавание типа документа по заголовкам |
| `ensure_typical_operations` | Копирование типовых операций (write) |
| `extend_typical_operations` | Расширение операций аналитиками (write) |
| `list_document_types` | Профили табличных типов документов |
| `preview_document_import` | Предпросмотр импорта (dry-run) |
| `import_document_rows` | Импорт строк документа (write) |
| `ensure_report_policy` | Применить политику по типу отчёта (write) |
| `get_report_context` | Сохранённый контекст отчёта 1С |
| `save_report_context` | Сохранить период/организацию (write) |
| `get_data_coverage` | Покрытие данных за период |
| `list_report_templates` | Шаблоны раскладки 1С |
| `save_report_template` | Сохранить шаблон (write) |
| `delete_report_template` | Удалить шаблон (write) |
| `preview_report_template` | Предпросмотр импорта с шаблоном |
| `import_report_rows` | Импорт с шаблоном (write) |
| `get_inventory_balance` | Остатки субледжера запасов |
| `rebuild_inventory_subledger` | Пересобрать FIFO-слои (write, ADMIN) |
| `get_account_balances` | Снапшоты сальдо/оборотов по счетам |
| `rebuild_account_balances` | Пересобрать снапшоты (write, ADMIN) |
| `get_ledger_integrity` | Проверка целостности журнала |
| `list_journal_events` | Журнал аудита изменений |
| `list_accounting_periods` | Учётные периоды |
| `create_accounting_period` | Создать период (write, ADMIN) |
| `close_accounting_period` | Закрыть период (write, ADMIN) |
| `reopen_accounting_period` | Переоткрыть период (write, ADMIN) |
| `list_ozon_keys` | Ключи Ozon (метаданные, без секретов) |
| `check_ozon_keys` | Проверка методов ключей Ozon |
| `create_ozon_key` | Создать ключ Ozon (write) |
| `refresh_ozon_key` | Обновить срок действия ключа (write) |
| `delete_ozon_key` | Удалить ключ Ozon (write) |
| `list_currencies` | Справочник валют ISO 4217 |
| `list_exchange_rates` | Курсы ЦБ РФ на дату |
| `get_exchange_rate` | Курс валюты |
| `convert_to_rub` | Конвертация суммы в RUB |
| `list_llm_tariffs` | Тарифы LLM-моделей |
| `sync_exchange_rates` | Обновить курсы (platform ADMIN) |
| `sync_llm_tariffs` | Обновить тарифы LLM (platform ADMIN) |

При финансовом запросе ВСЕГДА вызывайте инструменты первыми. Не генерируйте код для расчёта того, что уже считает MCP.
SKILLEOF
echo "==> mcp-first skill defined (tool reference)"

exec opencode web --port 4096 --hostname 0.0.0.0
