# Records the addon set the cluster is expected to have. Applied by
# scripts/setup-minikube.sh; this module WARNS on drift if the expected list
# and the module input ever diverge.
#
# An OpenTofu `check` block reports a failed assertion as a Warning, not an
# error: `tofu plan` still exits 0 (verified against OpenTofu 1.7.0 on
# 2026-09-26). So this is a *signal*, not a gate — do not write CI that relies
# on the exit code to catch addon drift. Anything that must hard-fail belongs
# in a `precondition` inside a resource, or in the shell script.
locals {
  expected_addons = toset(["ingress", "metrics-server"])
}

check "addons_match" {
  assert {
    condition     = toset(var.addons) == local.expected_addons
    error_message = "Addon set drifted from the documented baseline (ingress, metrics-server)."
  }
}
