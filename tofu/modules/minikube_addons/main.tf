# Records the addon set the cluster is expected to have. Applied by
# scripts/setup-minikube.sh; this module fails the plan if the expected
# list and the module input ever drift apart.
locals {
  expected_addons = toset(["registry", "ingress", "metrics-server"])
}

check "addons_match" {
  assert {
    condition     = toset(var.addons) == local.expected_addons
    error_message = "Addon set drifted from the documented baseline (registry, ingress, metrics-server)."
  }
}
