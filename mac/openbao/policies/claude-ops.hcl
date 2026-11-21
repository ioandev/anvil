# Claude's automation identity (AppRole "claude"): read-only, and only the ops folder. Every read is in the audit log.
path "secret/data/ops/*" {
  capabilities = ["read"]
}
path "secret/metadata/ops/*" {
  capabilities = ["read", "list"]
}
path "secret/metadata/ops" {
  capabilities = ["list"]
}
