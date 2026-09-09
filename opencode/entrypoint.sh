#!/bin/sh
set -e

# opencode entrypoint (docker-compose).
# Registers the gross-view MCP server for the deployed agent by rendering
# /root/.config/opencode/opencode.json from env:
#   OPENCODE_MCP_URL   - gross-view handler MCP address (default http://host.docker.internal:8082/api/mcp)
#   OPENCODE_MCP_TOKEN - service-account bearer token (see scripts/get-opencode-mcp-token.ps1).
# If no token is set the MCP server is NOT registered (stale config is removed).

CONFIG_DIR=/root/.config/opencode
if [ -n "${OPENCODE_MCP_TOKEN:-}" ]; then
  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG_DIR/opencode.json" <<EOF
{
  "mcp": {
    "gross-view": {
      "type": "remote",
      "url": "${OPENCODE_MCP_URL:-http://host.docker.internal:8082/api/mcp}",
      "headers": { "Authorization": "Bearer ${OPENCODE_MCP_TOKEN}" }
    }
  }
}
EOF
  echo "==> gross-view MCP registered for opencode (url=${OPENCODE_MCP_URL:-http://host.docker.internal:8082/api/mcp})"
else
  echo "==> OPENCODE_MCP_TOKEN is not set - gross-view MCP NOT registered"
  rm -f "$CONFIG_DIR/opencode.json"
fi

exec opencode web --port 4096 --hostname 0.0.0.0