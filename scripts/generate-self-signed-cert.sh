#!/usr/bin/env bash
# Generates a self-signed TLS certificate for gross-view.local into certs/.
#
# Consumers (docker-compose):
#   nginx     — /etc/nginx/certs/gross-view.local.{crt,key} (nginx/gross-view.local.conf)
#   opencode  — NODE_EXTRA_CA_CERTS=/etc/ssl/gross-view/certs/gross-view.local.crt (trusts the same cert)
#   handler   — handler/entrypoint.sh imports the .crt into the JVM truststore
#
# The certificate is self-signed AND marked CA:TRUE, so the .crt works as its own
# trust anchor (Node NODE_EXTRA_CA_CERTS / keytool -importcert accept it without a
# separate CA file). If you regenerate it, re-import it into the JVM truststore
# (handler container) and restart opencode — both pin the file at startup.
#
# Usage:
#   ./scripts/generate-self-signed-cert.sh            # generate if missing/expiring
#   ./scripts/generate-self-signed-cert.sh --force    # always regenerate
#
# Env overrides: CERT_DIR (default: certs), DOMAIN (default: gross-view.local),
#                DAYS (default: 825), NGINX_IP (default: 172.28.0.4 — nginx container IP).
#
# NOTE: certs/ is gitignored and must contain FILES, not directories — a directory
# named gross-view.local.crt breaks both the nginx and the opencode bind mounts.

set -euo pipefail

CERT_DIR="${CERT_DIR:-certs}"
DOMAIN="${DOMAIN:-gross-view.local}"
DAYS="${DAYS:-825}"
NGINX_IP="${NGINX_IP:-172.28.0.4}"
RENEW_WINDOW_DAYS=30

KEY="${CERT_DIR}/${DOMAIN}.key"
CRT="${CERT_DIR}/${DOMAIN}.crt"

force=0
for arg in "$@"; do
  case "$arg" in
    --force|-f) force=1 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $arg (try --help)" >&2; exit 2 ;;
  esac
done

# Skip regeneration when a usable certificate is already present.
if [[ $force -eq 0 && -s "$CRT" && -s "$KEY" ]]; then
  if openssl x509 -in "$CRT" -noout -checkend $((RENEW_WINDOW_DAYS * 86400)) >/dev/null 2>&1; then
    echo "Certificate $CRT is present and valid for more than ${RENEW_WINDOW_DAYS} days — nothing to do."
    echo "Use --force to regenerate."
    openssl x509 -in "$CRT" -noout -subject -dates
    exit 0
  fi
  echo "Certificate $CRT expires within ${RENEW_WINDOW_DAYS} days — regenerating."
fi

mkdir -p "$CERT_DIR"
if [[ ! -w "$CERT_DIR" ]]; then
  echo "ERROR: $CERT_DIR is not writable by $(id -un). It is usually owned by root." >&2
  echo "Run with sudo, or fix ownership first:" >&2
  echo "  sudo chown \"\$(id -u):\$(id -g)\" $CERT_DIR" >&2
  exit 1
fi

# A directory where a file is expected breaks the bind mounts in docker-compose.yml.
for f in "$CRT" "$KEY"; do
  if [[ -d "$f" ]]; then
    echo "ERROR: $f is a directory, but a file is required." >&2
    echo "Remove it:  sudo rm -rf $f" >&2
    exit 1
  fi
done

conf="$(mktemp)"
trap 'rm -f "$conf"' EXIT
cat >"$conf" <<EOF
[req]
distinguished_name = dn
x509_extensions    = v3_ext
prompt             = no

[dn]
C  = RU
ST = Local
L  = Local
O  = gross-view
OU = infra (self-signed, local dev)
CN = ${DOMAIN}

[v3_ext]
basicConstraints = critical, CA:TRUE
keyUsage         = critical, digitalSignature, keyEncipherment, keyCertSign
extendedKeyUsage = serverAuth
subjectAltName   = @alt_names

[alt_names]
DNS.1 = ${DOMAIN}
DNS.2 = localhost
DNS.3 = host.docker.internal
IP.1  = 127.0.0.1
IP.2  = ${NGINX_IP}
EOF

echo "Generating self-signed certificate for ${DOMAIN} (${DAYS} days) into ${CERT_DIR}/ ..."
openssl req -x509 -newkey rsa:2048 -sha256 -nodes \
  -days "$DAYS" \
  -keyout "$KEY" \
  -out "$CRT" \
  -config "$conf" 2>/dev/null

chmod 600 "$KEY"
chmod 644 "$CRT"

echo
openssl x509 -in "$CRT" -noout -subject -issuer -dates -ext subjectAltName
echo
if openssl verify -CAfile "$CRT" "$CRT" >/dev/null 2>&1; then
  echo "Self-check OK: $CRT verifies against itself (usable as its own trust anchor)."
else
  echo "WARNING: openssl verify failed for $CRT against itself." >&2
fi
echo
echo "Files:"
ls -l "$CRT" "$KEY"
echo
echo "Next steps:"
echo "  docker-compose up -d nginx      # start/restart the proxy with the new cert"
echo "  docker-compose up -d opencode   # recreate: it pins the CA file at container creation"
echo "  (handler container) re-run handler/entrypoint.sh to re-import the cert into the JVM truststore"
echo "  Browsers/JVM will warn about the self-signed issuer — that is expected locally."