#!/bin/sh
set -e

# gross-view-handler entrypoint (docker-compose).
# Imports the self-signed gross-view.local certificate into the JVM truststore so
# Nimbus (OAuth2 Resource Server) can fetch the Keycloak JWKS over
# https://gross-view.local/sso/realms/gross-view-realm/... (nginx terminates TLS).
# Without this, token validation fails with SunCertPathBuilderException.
CACERTS="${JAVA_HOME}/lib/security/cacerts"
CERT_FILE=/etc/gross-view/certs/gross-view.local.crt

if [ -n "${JAVA_HOME:-}" ] && [ -f "$CERT_FILE" ] && [ -f "$CACERTS" ]; then
  keytool -importcert -noprompt -alias "gross-view-local" \
    -file "$CERT_FILE" -keystore "$CACERTS" -storepass changeit >/dev/null 2>&1 || true
fi

exec java -jar /app/app.jar