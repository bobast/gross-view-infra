#!/usr/bin/env bash
# Installs the project's self-signed certificate (certs/gross-view.local.crt) into the
# HOST trust stores, so the browser/curl/git/JVM running on the host trust https://gross-view.local
# without a "self-signed certificate" warning.
#
# What it touches:
#   Debian/Ubuntu : /usr/local/share/ca-certificates/gross-view-local.crt + update-ca-certificates
#                   (→ /etc/ssl/certs/ca-certificates.crt, used by curl, git, node, python, wget)
#   RHEL/Fedora   : /etc/pki/ca-trust/source/anchors/gross-view-local.crt + update-ca-trust
#   NSS db        : ~/.pki/nssdb (Firefox + Chrome/Chromium on Linux) — needs `certutil`
#                   (sudo apt install libnss3-tools); skipped silently when not installed
#   JVM           : JDK cacerts (only with --jvm) — for the host-run handler in debug mode
#
# Containers are NOT affected: nginx/opencode/handler consume certs/ directly
# (NODE_EXTRA_CA_CERTS, keytool in handler/entrypoint.sh).
#
# Usage:
#   sudo ./scripts/install-cert-system-trust.sh              # install (idempotent)
#   sudo ./scripts/install-cert-system-trust.sh --jvm        # + JDK cacerts (host-run handler)
#   sudo ./scripts/install-cert-system-trust.sh --uninstall  # remove everywhere
#
# After a certificate re-issue (generate-self-signed-cert.sh --force) re-run this script —
# the trust stores pin the old fingerprint.

set -euo pipefail

CERT_DIR="${CERT_DIR:-certs}"
DOMAIN="${DOMAIN:-gross-view.local}"
CRT="${CERT_DIR}/${DOMAIN}.crt"

# Store aliases/names. Keep them stable so --uninstall can find what --install wrote.
CERT_NAME="gross-view-local"   # file base name (must end with .crt on Debian)
NSS_NICK="gross-view.local (gross-view self-signed local dev)"
JVM_ALIAS="gross-view-local"

uninstall=0
with_jvm=0
with_nss=1

for arg in "$@"; do
  case "$arg" in
    --uninstall|--remove) uninstall=1 ;;
    --jvm) with_jvm=1 ;;
    --no-nss) with_nss=0 ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $arg (try --help)" >&2; exit 2 ;;
  esac
done

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: must run as root (the system trust stores are root-owned)." >&2
  echo "  sudo $0 $*" >&2
  exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "ERROR: openssl not found — cannot read $CRT." >&2
  exit 1
fi

# --- pick the platform trust store -------------------------------------------------------
if [[ -d /usr/local/share/ca-certificates ]] && command -v update-ca-certificates >/dev/null 2>&1; then
  STORE=debian
  STORE_FILE="/usr/local/share/ca-certificates/${CERT_NAME}.crt"
  UPDATE_CMD="update-ca-certificates"
elif [[ -d /etc/pki/ca-trust/source/anchors ]] && command -v update-ca-trust >/dev/null 2>&1; then
  STORE=rhel
  STORE_FILE="/etc/pki/ca-trust/source/anchors/${CERT_NAME}.crt"
  UPDATE_CMD="update-ca-trust"
else
  echo "ERROR: no supported system trust store found (expected update-ca-certificates or update-ca-trust)." >&2
  exit 1
fi

# --- system trust store ------------------------------------------------------------------
if [[ $uninstall -eq 1 ]]; then
  if [[ -f "$STORE_FILE" ]]; then
    rm -f "$STORE_FILE"
    echo "Removed $STORE_FILE"
  else
    echo "Nothing to remove: $STORE_FILE is absent."
  fi
  $UPDATE_CMD >/dev/null
  echo "System trust store rebuilt ($UPDATE_CMD)."
else
  if [[ ! -s "$CRT" ]]; then
    echo "ERROR: $CRT is missing or empty." >&2
    echo "Generate it first:  ./scripts/generate-self-signed-cert.sh" >&2
    exit 1
  fi

  echo "Installing $CRT into the system trust store ($STORE)..."
  openssl x509 -in "$CRT" -noout -subject -issuer -dates -fingerprint -sha256

  # Skip the whole rebuild when the file is already byte-identical.
  if [[ -f "$STORE_FILE" ]] && cmp -s "$CRT" "$STORE_FILE"; then
    echo "Already up to date in $STORE_FILE — skipping copy and $UPDATE_CMD."
  else
    install -m 644 "$CRT" "$STORE_FILE"
    $UPDATE_CMD
    echo "Installed: $STORE_FILE"
  fi
fi

# --- NSS db (Firefox / Chrome on Linux) --------------------------------------------------
NSS_DIR="${NSS_DB:-$HOME/.pki/nssdb}"
# Running via sudo means $HOME is root's; use the invoking user's home instead.
if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
  NSS_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
  NSS_DIR="${NSS_DB:-$NSS_HOME/.pki/nssdb}"
fi

if [[ $with_nss -eq 1 ]] && command -v certutil >/dev/null 2>&1; then
  mkdir -p "$NSS_DIR"
  if [[ ! -f "$NSS_DIR/cert9.db" ]]; then
    echo "Initializing NSS database in $NSS_DIR ..."
    certutil -d "sql:$NSS_DIR" -N >/dev/null
  fi
  # C,, = trusted CA for SSL (C), trusted CA for email (empty), trusted for code signing (empty)
  if [[ $uninstall -eq 1 ]]; then
    certutil -d "sql:$NSS_DIR" -D -n "$NSS_NICK" 2>/dev/null \
      && echo "Removed from NSS db: $NSS_NICK" \
      || echo "Not present in NSS db: $NSS_NICK"
  else
    # -A errors when the nickname already exists; delete first to make it idempotent.
    certutil -d "sql:$NSS_DIR" -D -n "$NSS_NICK" >/dev/null 2>&1 || true
    certutil -d "sql:$NSS_DIR" -A -t "C,," -n "$NSS_NICK" -i "$CRT"
    echo "Imported into NSS db ($NSS_DIR): $NSS_NICK"
  fi
elif [[ $with_nss -eq 1 && $uninstall -eq 0 ]]; then
  echo "NOTE: certutil not found — browsers (Firefox/Chrome on Linux) keep using the NSS db."
  echo "      sudo apt install libnss3-tools   # then re-run this script"
fi

# --- JVM truststore (optional, host-run handler) ------------------------------------------
if [[ $with_jvm -eq 1 ]]; then
  if ! command -v keytool >/dev/null 2>&1; then
    echo "ERROR: --jvm requested but keytool not found (install a JDK or drop --jvm)." >&2
    exit 1
  fi
  CACERTS=""
  for home in "${JAVA_HOME:-}" /usr/lib/jvm/*; do
    if [[ -n "$home" && -f "$home/lib/security/cacerts" ]]; then
      CACERTS="$home/lib/security/cacerts"
      break
    fi
  done
  if [[ -z "$CACERTS" ]]; then
    echo "ERROR: --jvm requested but no cacerts found (JAVA_HOME, /usr/lib/jvm/*/lib/security/cacerts)." >&2
    exit 1
  fi
  if [[ $uninstall -eq 1 ]]; then
    keytool -delete -alias "$JVM_ALIAS" -keystore "$CACERTS" -storepass changeit >/dev/null \
      && echo "Removed JVM alias $JVM_ALIAS from $CACERTS" \
      || echo "JVM alias $JVM_ALIAS not present in $CACERTS"
  else
    keytool -importcert -noprompt -alias "$JVM_ALIAS" -file "$CRT" \
      -keystore "$CACERTS" -storepass changeit >/dev/null
    echo "Imported into JVM truststore: $CACERTS (alias $JVM_ALIAS, password changeit)"
    echo "NOTE: restart any JVM process (host-run handler) to pick up the new truststore."
  fi
fi

# --- verification -------------------------------------------------------------------------
if [[ $uninstall -eq 0 ]]; then
  echo
  echo "Verification:"
  for bundle in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt; do
    [[ -f "$bundle" ]] || continue
    if openssl verify -CAfile "$bundle" "$CRT" >/dev/null 2>&1; then
      echo "  OK: $CRT chains to a trusted anchor in $bundle"
    else
      echo "  FAIL: $CRT is not trusted via $bundle"
    fi
  done

  if getent hosts "$DOMAIN" >/dev/null 2>&1; then
    code="$(timeout 5 openssl s_client -connect "${DOMAIN}:443" -servername "$DOMAIN" </dev/null 2>/dev/null \
      | grep -m1 'Verify return code' || true)"
    if [[ -n "$code" ]]; then
      echo "  Live TLS handshake with https://${DOMAIN}: $code"
    else
      echo "  Live TLS check skipped (nginx not reachable on ${DOMAIN}:443)."
    fi
  else
    echo "  Live TLS check skipped: $DOMAIN is not in /etc/hosts (see README)."
  fi
fi

echo
if [[ $uninstall -eq 1 ]]; then
  echo "Done — the certificate is no longer trusted by the host."
else
  echo "Done — curl/git/node/python and browsers now trust https://${DOMAIN}."
  echo "Re-run this script after every '${DOMAIN}' certificate re-issue."
  echo "Containers are unaffected: they read certs/ directly (nginx, NODE_EXTRA_CA_CERTS in"
  echo "opencode, JVM truststore in handler/entrypoint.sh)."
fi