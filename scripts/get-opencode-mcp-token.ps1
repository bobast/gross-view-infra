<#
.SYNOPSIS
    Issues a Keycloak client_credentials token for the opencode-agent service account.

.DESCRIPTION
    The deployed (shared) opencode agent presents this bearer token to the gross-view
    MCP server (/api/mcp). The token binds the MCP session (workspace_id at initialize)
    to the service account identity, which is expected to be a member of the workspace
    the agent serves. Requires the `opencode-agent` confidential client (service
    account, realm role MCP) to exist in the realm — see docs/opencode-mcp-integration.md.

    Reads from the environment (docker compose .env):
      KEYCLOAK_URL                 e.g. https://gross-view.local/sso
      OPENCODE_AGENT_CLIENT_ID     default: opencode-agent
      OPENCODE_AGENT_CLIENT_SECRET

.OUTPUTS
    Prints the access token. Paste it into .env as OPENCODE_MCP_TOKEN and restart
    the opencode service (docker compose up -d opencode).
.EXAMPLE
    PS> .\scripts\get-opencode-mcp-token.ps1
#>
$ErrorActionPreference = 'Stop'

$issuer   = $env:KEYCLOAK_URL
$clientId = if ($env:OPENCODE_AGENT_CLIENT_ID) { $env:OPENCODE_AGENT_CLIENT_ID } else { 'opencode-agent' }
$secret   = $env:OPENCODE_AGENT_CLIENT_SECRET

if (-not $issuer) {
    throw 'KEYCLOAK_URL is not set (e.g. source .env: KEYCLOAK_URL=https://gross-view.local/sso).'
}
if (-not $secret) {
    throw 'OPENCODE_AGENT_CLIENT_SECRET is not set.'
}

$tokenUri = "$issuer/realms/gross-view-realm/protocol/openid-connect/token"
$body = "grant_type=client_credentials&client_id=$([uri]::EscapeDataString($clientId))&client_secret=$([uri]::EscapeDataString($secret))"

$resp = Invoke-RestMethod -Method Post -Uri $tokenUri `
    -ContentType 'application/x-www-form-urlencoded' -Body $body
Write-Output $resp.access_token