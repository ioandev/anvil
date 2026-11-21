# Credentials come from the environment:
#   SCW_ACCESS_KEY, SCW_SECRET_KEY, SCW_DEFAULT_PROJECT_ID
provider "scaleway" {
  zone   = var.zone
  region = var.region
}

provider "cloudflare" {
  # null (not "") when unset: the provider regex-validates the attribute even
  # when no cloudflare resources exist, and "" fails that validation.
  api_token = var.cloudflare_api_token != "" ? var.cloudflare_api_token : null
}
