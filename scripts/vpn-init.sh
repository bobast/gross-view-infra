#!/usr/bin/env bash
# Generates the WireGuard SERVER keys of the vpn-gateway pod and stores them in the
# cluster Secret `vpn-gateway-keys` (namespace `gross-view`).
#
# Why keys are created here and not inside the pod: a tunnel key must not exist in
# git, in a ConfigMap, or in a pod log. The Secret is the only copy — the operator
# generates it once, and nobody else can read it except through kubectl.
#
# After this script, add developers with ./scripts/vpn-peer.sh <name>.
#
# Usage:
#   ./scripts/vpn-init.sh                 # create the Secret if it does not exist
#   ./scripts/vpn-init.sh --force         # ROTATE the server keys (invalidates every
#                                         #   existing peer config — re-add all peers)
#   ./scripts/vpn-init.sh --print-only    # write keys into ./vpn/ and skip the cluster
#                                         #   (air-gapped flow, then kubectl create secret)
#
# Env overrides: NAMESPACE (gross-view), SECRET_NAME (vpn-gateway-keys),
#                SERVER_ADDRESS (10.13.13.1/24), LISTEN_PORT (43210),
#                OUT_DIR (vpn), WG_BIN (wg).
#
# Requires locally EITHER the `wg` tool (wireguard-tools: apt/dnf/brew install
# wireguard-tools) OR openssl >= 1.1.1 with X25519 support — scripts/lib-wg-keys.sh
# picks the backend, so no sudo is needed when only openssl is present.
# There is no CLUSTER-side fallback on purpose — a private key that is generated
# inside the cluster would have to travel back out through a pod log.

set -euo pipefail

# shellcheck source=scripts/lib-wg-keys.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-wg-keys.sh"

NAMESPACE="${NAMESPACE:-gross-view}"
SECRET_NAME="${SECRET_NAME:-vpn-gateway-keys}"
SERVER_ADDRESS="${SERVER_ADDRESS:-10.13.13.1/24}"
LISTEN_PORT="${LISTEN_PORT:-43210}"
OUT_DIR="${OUT_DIR:-vpn}"
WG_BIN="${WG_BIN:-wg}"

force=0
print_only=0
for arg in "$@"; do
  case "$arg" in
    --force|-f) force=1 ;;
    --print-only) print_only=1 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $arg (try --help)" >&2; exit 2 ;;
  esac
done

KEYGEN_BACKEND="$(wg_keygen_require)"
echo "Key generator: ${KEYGEN_BACKEND}"

if [[ "$print_only" -eq 0 ]]; then
  command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl not found (or use --print-only)." >&2; exit 1; }
  if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    if [[ "$force" -eq 0 ]]; then
      echo "Secret $SECRET_NAME already exists in namespace $NAMESPACE — nothing to do."
      echo "Read the server public key with:"
      echo "  kubectl get secret vpn-gateway-keys -n $NAMESPACE -o jsonpath='{.data.server_publickey}' | base64 -d; echo"
      echo "Rotation (breaks all peers):  ./scripts/vpn-init.sh --force"
      exit 0
    fi
    echo "WARNING: --force replaces the server keys. Every developer must re-import"
    echo "         a fresh config from ./scripts/vpn-peer.sh <name> --reissue."
    read -r -p "Continue? [y/N] " reply
    [[ "$reply" == "y" || "$reply" == "Y" ]] || { echo "Aborted."; exit 1; }
  fi
fi

WORKDIR="$(mktemp -d)"
chmod 700 "$WORKDIR"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

echo "Generating WireGuard server keys (${SERVER_ADDRESS}, listen ${LISTEN_PORT}/udp)..."
wg_gen_keypair "$WORKDIR/keys"
install -m 600 "$WORKDIR/keys/priv" "$WORKDIR/server_privatekey"
install -m 600 "$WORKDIR/keys/pub"  "$WORKDIR/server_publickey"

server_pub="$(cat "$WORKDIR/server_publickey")"
echo "Server public key: ${server_pub}"

if [[ "$print_only" -eq 1 ]]; then
  mkdir -p "$OUT_DIR"
  install -m 600 "$WORKDIR"/server_* "$OUT_DIR"/
  echo "Keys written to ${OUT_DIR}/ (gitignored)."
  echo "Create the Secret yourself:"
  echo "  kubectl create secret generic $SECRET_NAME -n $NAMESPACE \\"
  echo "    --from-file=server_privatekey=$OUT_DIR/server_privatekey \\"
  echo "    --from-file=server_publickey=$OUT_DIR/server_publickey"
  exit 0
fi

kubectl create secret generic "$SECRET_NAME" -n "$NAMESPACE" \
  --from-file=server_privatekey="$WORKDIR/server_privatekey" \
  --from-file=server_publickey="$WORKDIR/server_publickey" \
  --dry-run=client -o yaml > "$WORKDIR/secret.yaml"

if [[ "$force" -eq 1 ]]; then
  # Apply only the two server keys; peer keys in the live Secret must survive.
  kubectl apply -f "$WORKDIR/secret.yaml" >/dev/null
  echo "Secret $SECRET_NAME updated in namespace $NAMESPACE."
else
  kubectl create -f "$WORKDIR/secret.yaml" >/dev/null 2>&1 || kubectl replace -f "$WORKDIR/secret.yaml" >/dev/null
  echo "Secret $SECRET_NAME created in namespace $NAMESPACE."
fi

cat <<EOF

Next steps
  1. Add a developer:
       ./scripts/vpn-peer.sh <name>
     It generates the client keypair locally, adds the public key to the Secret
     and writes ./vpn/<name>.conf — copy that file to the laptop (600, never commit).
  2. Deploy the gateway (needs the Secret to exist, otherwise pods stay Pending):
       kubectl apply -k .
  3. Activate it:
       kubectl -n $NAMESPACE rollout restart deployment/vpn-gateway
       kubectl -n $NAMESPACE logs deployment/vpn-gateway -c wireguard -f
     strategy Recreate frees hostPort before the new pod starts, so a plain
     rollout restart works on a single node; scale 0 -> 1 stays as fallback.

Endpoint: <public IP of worker-192.168.132.5>:${LISTEN_PORT}/udp
EOF