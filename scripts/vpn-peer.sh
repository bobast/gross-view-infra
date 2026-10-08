#!/usr/bin/env bash
# Manages the WireGuard peers of the vpn-gateway pod: adds a developer, lists the
# current ones, or revokes one. See docs/vpn-access-k8s.md.
#
# Model: the SERVER keeps only the public part of a peer plus the tunnel address
# (no preshared keys — the setup dropped PSK entirely). The private key of a peer
# is created here on the developer's own machine and written to ./vpn/<name>.conf
# (0600, gitignored) — it never leaves that machine and never enters the cluster.
#
# Usage:
#   ./scripts/vpn-peer.sh add <name>              # register + write ./vpn/<name>.conf
#   ./scripts/vpn-peer.sh add <name> --reissue   # new keypair/address for the same name
#   ./scripts/vpn-peer.sh list                    # who has access
#   ./scripts/vpn-peer.sh remove <name>           # revoke access immediately
#
# Env overrides: NAMESPACE (gross-view), SECRET_NAME (vpn-gateway-keys),
#                ENDPOINT (200.165.239.108:43210 — public IP of the k8s worker),
#                TUNNEL_PREFIX (10.13.13), SERVER_ADDRESS (10.13.13.1/24),
#                PEER_RANGE (2-50), MTU (1380), OUT_DIR (vpn), WG_BIN (wg).
#
# Requires a kubectl context pointing at the cluster, and locally EITHER the `wg`
# tool (wireguard-tools) OR openssl >= 1.1.1 (X25519) — scripts/lib-wg-keys.sh
# picks the backend, so no sudo is needed when only openssl is present.

set -euo pipefail

# shellcheck source=scripts/lib-wg-keys.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-wg-keys.sh"

NAMESPACE="${NAMESPACE:-gross-view}"
SECRET_NAME="${SECRET_NAME:-vpn-gateway-keys}"
ENDPOINT="${ENDPOINT:-200.165.239.108:43210}"
TUNNEL_PREFIX="${TUNNEL_PREFIX:-10.13.13}"
SERVER_ADDRESS="${SERVER_ADDRESS:-10.13.13.1/24}"
PEER_FIRST="${PEER_FIRST:-2}"
PEER_LAST="${PEER_LAST:-50}"
MTU="${MTU:-1380}"
OUT_DIR="${OUT_DIR:-vpn}"
WG_BIN="${WG_BIN:-wg}"

# Temp dir for key material (see cmd_add) — cleaned up on any exit path.
PEER_WORKDIR=""
# The `if` (not `[[ ]] && ...`): with an empty PEER_WORKDIR the function would
# return 1 and the EXIT trap would turn a successful run into exit code 1.
cleanup_workdir() { if [[ -n "$PEER_WORKDIR" ]]; then rm -rf "$PEER_WORKDIR"; fi; }
trap cleanup_workdir EXIT

usage() { sed -n '2,24p' "$0"; }

b64url() { base64 | tr -d '\n'; }
b64decode() { printf '%s' "$1" | base64 -d; }

require_tools() {
  command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl not found." >&2; exit 1; }
  # Fails with install hints when neither wireguard-tools nor openssl is available.
  wg_keygen_require >/dev/null
}

# Prints "key<TAB>base64-value" for every entry of the Secret.
secret_keys() {
  kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" \
    -o go-template='{{range $k, $v := .data}}{{$k}}{{"\t"}}{{$v}}{{"\n"}}{{end}}'
}

secret_value() {
  local want="$1" line key value
  while IFS=$'\t' read -r key value; do
    if [[ "$key" == "$want" ]]; then
      b64decode "$value"
      return 0
    fi
  done < <(secret_keys)
  return 1
}

secret_exists() { kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" >/dev/null 2>&1; }

cmd_list() {
  require_tools
  if ! secret_exists; then
    echo "Secret $SECRET_NAME not found in $NAMESPACE — run ./scripts/vpn-init.sh first."
    return 1
  fi
  local name address pubkey
  printf '%-16s %-15s %s\n' "PEER" "TUNNEL ADDRESS" "PUBLIC KEY"
  while IFS=$'\t' read -r name address pubkey; do
    [[ -n "$name" ]] || continue
    printf '%-16s %-15s %s\n' "$name" "$(b64decode "$address")" "$(b64decode "$pubkey")"
  done < <(secret_keys | awk -F'\t' '
    $1 ~ /^peer_.*_address$/     { split($1, a, "_"); addr[a[2]] = $2 }
    $1 ~ /^peer_.*_publickey$/   { split($1, b, "_"); pub[b[2]]  = $2 }
    END { for (n in addr) if (n in pub) printf "%s\t%s\t%s\n", n, addr[n], pub[n] }' | sort)
  echo
  echo "Endpoint: ${ENDPOINT} (server ${SERVER_ADDRESS%%/*})"
}

cmd_add() {
  local name="$1" reissue=0
  shift
  for arg in "$@"; do
    case "$arg" in
      --reissue) reissue=1 ;;
      *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
  done
  require_tools

  if [[ ! "$name" =~ ^[a-z0-9][a-z0-9_-]{0,20}$ ]]; then
    echo "ERROR: peer name must match [a-z0-9][a-z0-9_-]{0,20} (it becomes Secret key names)." >&2
    exit 2
  fi
  if ! secret_exists; then
    echo "Secret $SECRET_NAME not found in $NAMESPACE — run ./scripts/vpn-init.sh first." >&2
    exit 1
  fi

  local server_pub
  server_pub="$(secret_value server_publickey)" || {
    echo "ERROR: Secret has no server_publickey key — recreate it with ./scripts/vpn-init.sh --force" >&2
    exit 1
  }

  if [[ "$reissue" -eq 0 ]] && secret_value "peer_${name}_publickey" >/dev/null 2>&1; then
    echo "Peer '${name}' is already registered. Use 'add ${name} --reissue' for a fresh config," >&2
    echo "or 'remove ${name}' first. Existing clients keep working until then." >&2
    exit 1
  fi

  # Pick the first free tunnel address.
  local used addr octet
  used="$(secret_keys | awk -F'\t' '$1 ~ /^peer_.*_address$/ {print $2}' | while read -r v; do b64decode "$v"; done)"
  addr=""
  for ((octet = PEER_FIRST; octet <= PEER_LAST; octet++)); do
    if ! grep -qx "${TUNNEL_PREFIX}.${octet}" <<< "$used"; then
      addr="${TUNNEL_PREFIX}.${octet}"
      break
    fi
  done
  if [[ -z "$addr" ]]; then
    echo "ERROR: no free address left in ${TUNNEL_PREFIX}.${PEER_FIRST}-${PEER_LAST}." >&2
    exit 1
  fi

  # The temp dir must be GLOBAL: the EXIT trap runs after cmd_add returned, when a
  # local variable would already be unset (`set -u` would then abort the script with
  # "workdir: unbound variable" and a non-zero exit code).
  PEER_WORKDIR="$(mktemp -d)"
  local workdir="$PEER_WORKDIR"
  wg_gen_keypair "$workdir"

  local patch
  patch=$(cat <<JSON
{"data":{"peer_${name}_publickey":"$(b64url < "$workdir/pub")","peer_${name}_address":"$(printf '%s' "$addr" | b64url)"}}
JSON
)
  kubectl patch secret "$SECRET_NAME" -n "$NAMESPACE" --type=merge -p "$patch" >/dev/null

  mkdir -p "$OUT_DIR"
  local conf="$OUT_DIR/${name}.conf"
  install -m 600 /dev/null "$conf"
  cat > "$conf" <<CONF
# WireGuard client config for the gross-view cluster VPN.
# Created by scripts/vpn-peer.sh — DO NOT COMMIT, DO NOT SEND BY MAIL.
# NOTE: the in-tunnel proxy ports (10.13.13.1:15432 postgres, 10.13.13.1:18200
# vault) were removed from the manifests 2026-10-07 — nothing listens inside
# the tunnel yet, see docs/vpn-access-k8s.md.

[Interface]
PrivateKey = $(cat "$workdir/priv")
Address = ${addr}/32
MTU = ${MTU}

[Peer]
PublicKey = ${server_pub}
Endpoint = ${ENDPOINT}
# Only the gateway itself is routable: the pod and service CIDRs of the cluster
# are NOT reachable by design (see docs/vpn-access-k8s.md).
AllowedIPs = ${SERVER_ADDRESS%%/*}/32
PersistentKeepalive = 25
CONF

  echo "Peer '${name}' registered at ${addr} (public key $(cat "$workdir/pub"))."
  echo "Client config: ${conf} (0600)"
  cat <<CONF2

On the laptop:
  scp ${conf} you@host:/tmp/${name}.conf
  sudo install -m 600 /tmp/${name}.conf /etc/wireguard/gross-view.conf
  sudo wg-quick up gross-view
  # check the tunnel
  sudo wg show
  # services: the in-tunnel proxy was removed from the manifests 2026-10-07,
  # so nothing listens inside the tunnel yet. When the proxy layer returns:
  #   psql -h ${SERVER_ADDRESS%%/*} -p 15432 -U <db-user> -d gross_view   # postgres
  #   curl -s http://${SERVER_ADDRESS%%/*}:18200/v1/sys/health             # vault
  # stop
  sudo wg-quick down gross-view

Then restart the gateway so it picks up the new peer:
  kubectl -n ${NAMESPACE} rollout restart deployment/vpn-gateway
(The Deployment uses strategy Recreate: the old pod releases hostPort before the
new one is created, so a plain rollout restart no longer hangs on a single node.
Fallback if the strategy ever reverts to RollingUpdate:
  kubectl -n ${NAMESPACE} scale deployment/vpn-gateway --replicas=0
  kubectl -n ${NAMESPACE} scale deployment/vpn-gateway --replicas=1 )
CONF2
}

cmd_remove() {
  local name="$1"
  require_tools
  if ! secret_exists; then
    echo "Secret $SECRET_NAME not found in $NAMESPACE." >&2
    exit 1
  fi
  if ! secret_value "peer_${name}_publickey" >/dev/null 2>&1; then
    echo "Peer '${name}' is not registered." >&2
    exit 1
  fi
  # presharedkey: legacy key from before PSK was dropped — always cleared.
  # endpoint/keepalive: optional per-peer keys (see docs/vpn-access-k8s.md),
  # cleared too so `remove` really empties every key of the peer.
  kubectl patch secret "$SECRET_NAME" -n "$NAMESPACE" --type=merge -p \
    "{\"data\":{\"peer_${name}_publickey\":null,\"peer_${name}_presharedkey\":null,\"peer_${name}_address\":null,\"peer_${name}_endpoint\":null,\"peer_${name}_keepalive\":null}}" >/dev/null
  echo "Peer '${name}' removed from Secret ${SECRET_NAME}."
  echo "Delete the client config too:  rm -f ${OUT_DIR}/${name}.conf"
  echo "Revocation takes effect after a gateway restart:"
  echo "  kubectl -n ${NAMESPACE} rollout restart deployment/vpn-gateway"
  echo "(strategy Recreate — no hostPort deadlock; scale 0 -> 1 stays as fallback)"
}

[[ $# -ge 1 ]] || { usage; exit 2; }
command="$1"; shift
case "$command" in
  add)
    [[ $# -ge 1 ]] || { echo "Usage: $0 add <name> [--reissue]" >&2; exit 2; }
    cmd_add "$@"
    ;;
  list) cmd_list ;;
  remove|rm)
    [[ $# -ge 1 ]] || { echo "Usage: $0 remove <name>" >&2; exit 2; }
    cmd_remove "$@"
    ;;
  -h|--help|help) usage ;;
  *) echo "Unknown command: $command" >&2; usage; exit 2 ;;
esac