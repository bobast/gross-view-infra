# Vault server configuration — shared by docker-compose and K8s.
# Keep in sync with k8s/base/vault-entrypoint-configmap.yaml (data.vault-config.hcl).
storage "file" {
  path = "/vault/data"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}

api_addr      = "http://127.0.0.1:8200"
disable_mlock = true
ui            = true