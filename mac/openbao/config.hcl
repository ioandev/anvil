# OpenBao server config (Mac mini). Auto-unseal with a static key file, Raft storage, plain HTTP on loopback only
# (Tailscale serve terminates TLS: https://${ANVIL_HOME_TAILNET_HOST}:${ANVIL_HOME_BAO_PORT}).
ui            = true
disable_mlock = true   # Docker Desktop VM; mlock isn't available

storage "raft" {
  path    = "/openbao/file"
  node_id = "mac-mini"
}

listener "tcp" {
  address     = "0.0.0.0:8200"   # inside the container; the host maps 127.0.0.1:${ANVIL_HOME_BAO_PORT} to it
  tls_disable = true
}

api_addr     = "https://${ANVIL_HOME_TAILNET_HOST}:${ANVIL_HOME_BAO_PORT}"
cluster_addr = "http://127.0.0.1:8201"

# Auto-unlock: the 32-byte key in ./seal.key unseals OpenBao on every start. Whoever has this key AND the data volume
# can read everything: it lives only on the Mac (FileVault) and, encrypted with SOPS, in the ${ANVIL_NAME} repo.
seal "static" {
  current_key_id = "20261027"
  current_key    = "file:///openbao/seal/seal.key"
}

# Audit log: every request (who read which secret, when), with secret values HMAC'd, never in clear.
# Declared here because OpenBao 2.7 refuses to enable audit devices through the API.
audit "file" "file" {
  description = "every request, secrets hashed"
  options {
    file_path = "/openbao/file/audit.log"
  }
}
