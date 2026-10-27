#!/usr/bin/env bash
# Rotates an LLM provider API key end-to-end: Vault -> ESO -> Secret -> opencode pod.
#
# Why a script: a key put into Vault does NOT reach the model. Three pull-based
# stages sit in between, and each of them silently keeps the old value:
#   1. ESO syncs `secret/gross-view` into the Secret `gross-view-secrets` only on
#      `refreshInterval` (1h) or on an explicit `force-sync` annotation, so right
#      after `vault kv patch` the Secret still holds the previous value;
#   2. `secretKeyRef` env vars are captured when the container is CREATED, so
#      updating the Secret alone changes nothing for the running pod;
#   3. nothing rolls the Deployment on a Secret change (no checksum annotation),
#      so the old value keeps being sent — with a bootstrap placeholder it
#      surfaces as a confusing "Your api key: ****_KEY is invalid" 401.
# This script does all three steps and verifies the result.
#
# Usage:
#   ./scripts/rotate-llm-key.sh <provider> --from-env     # key taken from $<PROVIDER>_API_KEY
#   ./scripts/rotate-llm-key.sh <provider>               # key is prompted for (not echoed)
#   ./scripts/rotate-llm-key.sh <provider> <api-key>     # key as an argument (lands in shell history)
#   ./scripts/rotate-llm-key.sh --list                   # state of every provider key
#
# Providers: deepseek openai anthropic openrouter google groq mistral xai
#
# Flags:
#   --from-env       read the new key from the environment instead of argv/prompt
#   --skip-restart   write to Vault + force ESO sync only, do not restart opencode
#   --dry-run        print what would happen, change nothing
#   --timeout <sec>  how long to wait for the ESO sync (default 180)
#
# Env overrides: NAMESPACE (gross-view), VAULT_DEPLOYMENT (vault), VAULT_MOUNT
#                (secret), VAULT_PATH (gross-view), ESO_NAME (gross-view-secrets),
#                SECRET_NAME (gross-view-secrets), DEPLOYMENT (opencode),
#                VAULT_TOKEN (read from /vault/data/init.json when unset),
#                VAULT_INIT_FILE (/vault/data/init.json).
#
# Requires a kubectl context pointing at the cluster. Bash only (the Windows
# deployment snippet in README is PowerShell, but this script is not).

set -euo pipefail

NAMESPACE="${NAMESPACE:-gross-view}"
VAULT_DEPLOYMENT="${VAULT_DEPLOYMENT:-vault}"
VAULT_MOUNT="${VAULT_MOUNT:-secret}"
VAULT_PATH="${VAULT_PATH:-gross-view}"
VAULT_INIT_FILE="${VAULT_INIT_FILE:-/vault/data/init.json}"
ESO_NAME="${ESO_NAME:-gross-view-secrets}"
SECRET_NAME="${SECRET_NAME:-gross-view-secrets}"
DEPLOYMENT="${DEPLOYMENT:-opencode}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-180}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-240}"

PROVIDERS=(deepseek openai anthropic openrouter google groq mistral xai)

DRY_RUN=0
SKIP_RESTART=0
FROM_ENV=0

usage() {
  sed -n '2,38p' "$0"
}

provider_known() {
  local p
  for p in "${PROVIDERS[@]}"; do
    [[ "$p" == "$1" ]] && return 0
  done
  return 1
}

# deepseek -> deepseek_api_key (Vault property) and DEEPSEEK_API_KEY (container env)
provider_vault_key() { printf '%s_api_key' "$1"; }
provider_env_var() { printf '%s_API_KEY' "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"; }

# Never print key material: first 6 + last 4 characters are enough to tell two
# keys apart without leaking the secret.
mask() {
  local v="$1"
  if [[ -z "$v" ]]; then
    printf '<empty>'
  elif [[ ${#v} -le 10 ]]; then
    printf '***'
  else
    printf '%s***%s' "${v:0:6}" "${v: -4}"
  fi
}

# Bootstrap seeds used to write non-empty placeholders (older clusters) or empty
# strings (current vault/entrypoint.sh). Both are reported as "not a real key".
is_placeholder() {
  local v="$1"
  [[ -z "$v" ]] && return 0
  case "$v" in
    changeme|change_me|REPLACE_WITH_*|*changeme*|*PLACEHOLDER*) return 0 ;;
  esac
  return 1
}

require_tools() {
  command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl not found." >&2; exit 1; }
  command -v base64 >/dev/null 2>&1 || { echo "ERROR: base64 not found." >&2; exit 1; }
}

secret_exists() { kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" >/dev/null 2>&1; }

# Base64 value of one Secret key (empty when the key is absent).
secret_b64() {
  local key="$1" out
  out="$(kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" \
    -o go-template="{{index .data \"${key}\"}}" 2>/dev/null || true)"
  [[ "$out" == "<no value>" ]] && out=""
  printf '%s' "$out"
}

secret_plain() {
  local b
  b="$(secret_b64 "$1")"
  [[ -n "$b" ]] || return 1
  printf '%s' "$b" | base64 -d
}

# The running opencode pod (env is read only when the container is created).
opencode_pod() {
  kubectl -n "$NAMESPACE" get pods -l "app.kubernetes.io/name=${DEPLOYMENT}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

pod_env() {
  local pod="$1" var="$2"
  [[ -n "$pod" ]] || { printf ''; return 0; }
  kubectl -n "$NAMESPACE" exec "$pod" -- printenv "$var" 2>/dev/null || true
}

# The Vault pod carries its own root token in init.json (auto-unseal bootstrap);
# VAULT_TOKEN wins when the caller has a personal (dev-policy) token.
resolve_vault_token() {
  if [[ -n "${VAULT_TOKEN:-}" ]]; then
    printf '%s' "$VAULT_TOKEN"
    return 0
  fi
  local t
  t="$(kubectl -n "$NAMESPACE" exec "deploy/${VAULT_DEPLOYMENT}" -c vault -- \
        sed -n 's/.*"root_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$VAULT_INIT_FILE" 2>/dev/null | head -n1)" || t=""
  if [[ -z "$t" ]]; then
    echo "ERROR: cannot read the Vault root token from ${VAULT_INIT_FILE}." >&2
    echo "       Either export VAULT_TOKEN or check that deploy/${VAULT_DEPLOYMENT} is Running." >&2
    return 1
  fi
  printf '%s' "$t"
}

wait_for_secret() {
  local vault_key="$1" key="$2" expected start
  expected="$(printf '%s' "$key" | base64 | tr -d '\n')"
  start=$SECONDS
  printf '==> waiting for Secret %s/%s to carry the new value' "$NAMESPACE" "$SECRET_NAME"
  while (( SECONDS - start < WAIT_TIMEOUT )); do
    if [[ "$(secret_b64 "$vault_key")" == "$expected" ]]; then
      printf ' (ok, %ss)\n' "$((SECONDS - start))"
      return 0
    fi
    sleep 3
  done
  printf ' (timeout)\n'
  echo "ERROR: the Secret did not update within ${WAIT_TIMEOUT}s. Diagnose with:" >&2
  echo "  kubectl -n ${NAMESPACE} describe externalsecret ${ESO_NAME}" >&2
  echo "  kubectl -n ${NAMESPACE} logs deploy/external-secrets -n external-secrets --tail=50" >&2
  return 1
}

cmd_list() {
  require_tools
  if ! secret_exists; then
    echo "Secret ${SECRET_NAME} not found in ${NAMESPACE} — is the cluster bootstrapped?" >&2
    exit 1
  fi
  local pod p vk ev sv ev_actual secret_col env_col state
  pod="$(opencode_pod)"

  printf '%-11s %-28s %-28s %s\n' "PROVIDER" "SECRET ${SECRET_NAME}" "ENV IN POD (${DEPLOYMENT})" "STATE"
  for p in "${PROVIDERS[@]}"; do
    vk="$(provider_vault_key "$p")"
    ev="$(provider_env_var "$p")"
    sv="$(secret_plain "$vk" || true)"
    ev_actual="$(pod_env "$pod" "$ev")"

    if [[ -z "$(secret_b64 "$vk")" ]]; then
      secret_col="<missing>"
      state="not seeded — put a real key"
    elif is_placeholder "$sv"; then
      secret_col="placeholder ($(mask "$sv"))"
      state="PLACEHOLDER — rotate with a real key"
    else
      secret_col="$(mask "$sv")"
      if [[ -z "$pod" ]]; then
        state="no running pod — rollout pending"
      elif [[ "$ev_actual" == "$sv" ]]; then
        state="ok"
      elif [[ -z "$ev_actual" ]]; then
        state="env unset in pod — restart ${DEPLOYMENT}"
      elif is_placeholder "$ev_actual"; then
        state="STALE env (placeholder) — restart ${DEPLOYMENT}"
      else
        state="STALE env ($(mask "$ev_actual")) — restart ${DEPLOYMENT}"
      fi
    fi

    if [[ -z "$pod" ]]; then
      env_col="<no pod>"
    elif [[ -z "$ev_actual" ]]; then
      env_col="<empty>"
    else
      env_col="$(mask "$ev_actual")"
    fi

    printf '%-11s %-28s %-28s %s\n' "$p" "$secret_col" "$env_col" "$state"
  done
  echo
  echo "STALE env is the classic 'key is in Vault but models still return 401' case:"
  echo "  ./scripts/rotate-llm-key.sh <provider> --from-env   # rewrites + restarts opencode"
}

cmd_rotate() {
  local provider="$1" key="$2" vk ev token out ver pod got
  vk="$(provider_vault_key "$provider")"
  ev="$(provider_env_var "$provider")"

  echo "==> provider ${provider}: Vault secret/${VAULT_PATH} ${vk} -> env ${ev}"

  if ! secret_exists; then
    echo "ERROR: Secret ${SECRET_NAME} not found in ${NAMESPACE}." >&2
    exit 1
  fi

  # --- 1. Vault (the source of truth; ESO owns the Secret) ------------------
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] vault kv patch -mount=${VAULT_MOUNT} ${VAULT_PATH} ${vk}=-   <key $(mask "$key"), ${#key} chars>"
  else
    token="$(resolve_vault_token)"
    # `=${vk}=-` makes Vault read the value from stdin: the key never shows up in
    # argv (and therefore not in the pod's process list or shell history).
    out="$(printf '%s' "$key" | kubectl -n "$NAMESPACE" exec -i "deploy/${VAULT_DEPLOYMENT}" -c vault -- \
      env VAULT_TOKEN="$token" vault kv patch -mount="$VAULT_MOUNT" "$VAULT_PATH" "${vk}=-")" || {
        echo "ERROR: vault kv patch failed." >&2
        exit 1
      }
    ver="$(printf '%s\n' "$out" | awk '$1=="version"{print $2}' | tail -n1)"
    echo "==> Vault: secret/${VAULT_PATH} updated (version ${ver:-?}), value $(mask "$key")"
  fi

  # --- 2. ESO: pull-модель, без force-sync ждать до refreshInterval (1h) ----
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] kubectl annotate externalsecret ${ESO_NAME} force-sync=<ts> --overwrite"
    echo "[dry-run] wait for ${SECRET_NAME}.${vk} == the new key (<= ${WAIT_TIMEOUT}s)"
  else
    kubectl -n "$NAMESPACE" annotate externalsecret "$ESO_NAME" "force-sync=$(date +%s)" --overwrite >/dev/null
    echo "==> ESO: force-sync requested on externalsecret/${ESO_NAME}"
    wait_for_secret "$vk" "$key"
  fi

  # --- 3. opencode: env is captured at container creation -------------------
  if [[ $SKIP_RESTART -eq 1 ]]; then
    echo "==> --skip-restart: the running pod still holds the OLD value. Apply it with:"
    echo "    kubectl -n ${NAMESPACE} rollout restart deployment/${DEPLOYMENT}"
    return 0
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] kubectl rollout restart deployment/${DEPLOYMENT} && rollout status"
    return 0
  fi

  kubectl -n "$NAMESPACE" rollout restart "deployment/${DEPLOYMENT}"
  kubectl -n "$NAMESPACE" rollout status "deployment/${DEPLOYMENT}" --timeout="${ROLLOUT_TIMEOUT}s"

  pod="$(opencode_pod)"
  got="$(pod_env "$pod" "$ev")"
  if [[ "$got" == "$key" ]]; then
    echo "==> verified: pod ${pod} ${ev}=$(mask "$got") (matches Vault/Secret)"
    echo "Done — repeat the previously failing model call."
    # opencode keeps MCP registrations in memory only: a restarted pod has an empty
    # GET /mcp until the handler registers the per-workspace server again. The
    # handler does that on the next request (gross-view-handler §12.13).
    echo "Note: opencode does not persist MCP registrations — the handler re-registers"
    echo "      the per-workspace server on the next assistant request. If the panel still"
    echo "      shows 'MCP servers not detected' (handler image without the 2026-10-27 fix):"
    echo "      kubectl -n ${NAMESPACE} rollout restart deployment/gross-view-api"
  else
    echo "WARN: pod ${pod} ${ev}=$(mask "$got") does not match the new key." >&2
    echo "      Check: kubectl -n ${NAMESPACE} get externalsecret ${ESO_NAME} -o wide" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# argv
# ---------------------------------------------------------------------------
[[ $# -ge 1 ]] || { usage; exit 2; }

case "$1" in
  -h|--help|help) usage; exit 0 ;;
  --list|list) cmd_list; exit 0 ;;
esac

provider=""
key=""
rest=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-env) FROM_ENV=1; shift ;;
    --skip-restart) SKIP_RESTART=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --timeout)
      [[ $# -ge 2 ]] || { echo "--timeout needs a value (seconds)" >&2; exit 2; }
      WAIT_TIMEOUT="$2"; shift 2 ;;
    -h|--help|help) usage; exit 0 ;;
    -*) echo "Unknown flag: $1" >&2; usage >&2; exit 2 ;;
    *)
      if [[ -z "$provider" ]]; then provider="$1"; else rest+=("$1"); fi
      shift ;;
  esac
done

[[ -n "$provider" ]] || { echo "ERROR: provider is required." >&2; usage >&2; exit 2; }
provider="$(printf '%s' "$provider" | tr '[:upper:]' '[:lower:]')"
if ! provider_known "$provider"; then
  echo "ERROR: unknown provider '${provider}'. Supported: ${PROVIDERS[*]}" >&2
  exit 2
fi

if [[ $FROM_ENV -eq 1 ]]; then
  [[ ${#rest[@]} -eq 0 ]] || { echo "ERROR: --from-env does not take a key argument." >&2; exit 2; }
  env_var="$(provider_env_var "$provider")"
  key="${!env_var:-}"
  [[ -n "$key" ]] || { echo "ERROR: ${env_var} is empty in this shell." >&2; exit 2; }
else
  if [[ ${#rest[@]} -ge 1 ]]; then
    key="${rest[0]}"
  else
    # No argv form on purpose: a key in the command line ends up in history/ps.
    read -r -s -p "New ${provider} API key (input hidden): " key
    echo
  fi
fi

if [[ -z "$key" ]]; then
  echo "ERROR: empty key." >&2
  exit 2
fi
if is_placeholder "$key"; then
  echo "ERROR: '$(mask "$key")' looks like a placeholder, refusing to write it." >&2
  exit 2
fi

require_tools
cmd_rotate "$provider" "$key"
