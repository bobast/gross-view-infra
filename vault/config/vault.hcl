# Vault server configuration for gross-view infrastructure

storage "file" {
  path = "/vault/data"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1  # Disable TLS for local development
  # In production, enable TLS:
  # tls_cert_file = "/vault/config/tls/vault.crt"
  # tls_key_file  = "/vault/config/tls/vault.key"
}

# API address for client connections
api_addr = "http://0.0.0.0:8200"

# Cluster address (for HA setup)
# cluster_addr = "http://0.0.0.0:8201"

# Enable Vault UI
ui = true

# Log level: trace, debug, info, warn, error
log_level = "info"

# Disable mlock (not needed in Docker, requires IPC_LOCK capability)
disable_mlock = true
