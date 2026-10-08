#!/usr/bin/env bash
# Shared WireGuard key generation for scripts/vpn-init.sh and scripts/vpn-peer.sh.
#
# This file is SOURCED, never executed. It provides two backends:
#
#   wg       — wireguard-tools (`wg genkey` / `wg pubkey`); preferred
#              when installed.
#   openssl  — fallback so that keys can be generated on a machine without
#              wireguard-tools (no sudo required): `openssl genpkey -algorithm X25519`
#              produces the same thing — a raw 32-byte X25519 scalar plus its public
#              key, base64-encoded with padding, which IS the wireguard key format.
#              (PKCS#8 DER for X25519 ends with the 32-byte scalar, SPKI DER ends with
#              the 32-byte public key; the kernel clamps the scalar itself, so the
#              keys need no extra clamping. Verified against a reference X25519
#              implementation — RFC 7748 vectors.)
#
# Keys are ALWAYS generated on the operator's own machine, never inside the cluster:
# a private key born in a pod would have to be extracted back out through pod logs.

# Prints the backend to use: wg | openssl | none
wg_keygen_backend() {
  if command -v "${WG_BIN:-wg}" >/dev/null 2>&1; then
    echo wg
  elif command -v openssl >/dev/null 2>&1 && openssl genpkey -algorithm X25519 >/dev/null 2>&1; then
    echo openssl
  else
    echo none
  fi
}

# Fails with installation hints when neither backend is available.
wg_keygen_require() {
  local backend
  backend="$(wg_keygen_backend)"
  if [ "$backend" = none ]; then
    {
      echo "ERROR: no WireGuard key generator found. Install either:"
      echo "  wireguard-tools (preferred):"
      echo "    Debian/Ubuntu: sudo apt install wireguard-tools"
      echo "    RHEL/Fedora:   sudo dnf install wireguard-tools"
      echo "    macOS:         brew install wireguard-tools"
      echo "  or openssl >= 1.1.1 with X25519 support:"
      echo "    Debian/Ubuntu: sudo apt install openssl"
    } >&2
    exit 1
  fi
  printf '%s\n' "$backend"
}

# wg_gen_keypair <outdir> — writes <outdir>/priv, <outdir>/pub,
# each 0600, base64 with padding, newline-terminated (identical layout for both backends).
# No preshared key is generated: the setup dropped PSK entirely (see
# docs/vpn-access-k8s.md) — security rests on X25519 alone.
wg_gen_keypair() {
  local outdir="$1" backend pem
  mkdir -p "$outdir"
  chmod 700 "$outdir"
  backend="$(wg_keygen_backend)"

  case "$backend" in
    wg)
      "${WG_BIN:-wg}" genkey > "$outdir/priv"
      "${WG_BIN:-wg}" pubkey < "$outdir/priv" > "$outdir/pub"
      ;;
    openssl)
      pem="$outdir/priv.pem"
      openssl genpkey -algorithm X25519 -out "$pem" 2>/dev/null
      openssl pkey -in "$pem" -outform DER 2>/dev/null \
        | tail -c 32 | openssl base64 -A > "$outdir/priv"
      openssl pkey -in "$pem" -pubout -outform DER 2>/dev/null \
        | tail -c 32 | openssl base64 -A > "$outdir/pub"
      rm -f "$pem"
      ;;
    *)
      echo "ERROR: no key generator backend available" >&2
      return 1
      ;;
  esac

  chmod 600 "$outdir/priv" "$outdir/pub"
  # openssl base64 -A emits no trailing newline; wg does. Normalise both.
  # NB: use `if`, not `[ ... ] && ...` — the latter would leave status 1 in the
  # file that already ends with a newline, the function would return 1 and
  # `set -e` in the caller would abort right after key generation.
  for f in priv pub; do
    if [ -n "$(tail -c 1 "$outdir/$f")" ]; then
      printf '\n' >> "$outdir/$f"
    fi
  done
  return 0
}
