# Records the addon set this project expects. Applied by
# scripts/setup-minikube.sh, which is the only component that can observe the
# real cluster. This module asserts that a caller passes the list recorded
# here — it does NOT assert anything about the cluster itself, because minikube
# addon state is not exposed through the Kubernetes API and OpenTofu has no
# data source that could read it.
#
# Concretely: both sides of the comparison below are literals in this
# repository, so the check can only fail if someone edits one of the two and
# forgets the other. It cannot detect an addon disabled on the running cluster.
# What it genuinely catches is a caller wiring the wrong list in — worth having,
# and much less than "detects drift". To check the cluster's real state, run
# `minikube addons list -p platform`; that check belongs in a shell script.
#
# An OpenTofu `check` block reports a failed assertion as a Warning, not an
# error: `tofu plan` still exits 0 (verified against OpenTofu 1.7.0 on
# 2026-09-26). So even a real failure is a signal, not a gate — do not write CI
# that relies on the exit code. Anything that must hard-fail belongs in a
# `precondition` inside a resource, or in the shell script.
locals {
  expected_addons = toset(["ingress", "metrics-server"])
}

check "addons_match" {
  assert {
    condition     = toset(var.addons) == local.expected_addons
    error_message = "Caller passed an addon list that differs from this module's recorded baseline (ingress, metrics-server). This is a wiring mismatch, not cluster drift."
  }
}
