# Reference copy of the root module's backend settings (see tofu/backend.tf).
#
# NOT loaded by OpenTofu. `tofu init` reads only the backend block inside
# the root module; this file is documentation. It exists so the per-environment
# values are readable in one place and so a future switch to a remote backend
# has an obvious home. The values must be kept in sync with tofu/backend.tf by
# hand — that duplication is the deliberate cost of not yet having a remote
# backend to parameterize per environment.
path = "environments/local/terraform.tfstate"
