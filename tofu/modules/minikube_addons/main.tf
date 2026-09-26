# WHAT THIS ACTUALLY ASSERTS — read before trusting it as a drift signal.
#
# This module compares the `addons` list the caller passes in against a literal
# recorded right here. BOTH SIDES ARE LITERALS IN THIS REPOSITORY. It does not
# read the cluster, because minikube's addon state is not exposed through the
# Kubernetes API and OpenTofu has no `data` source that can see it.
#
# So this assertion can only fail if someone edits one of the two literals and
# forgets the other. It CANNOT detect an addon that was disabled on the running
# cluster, and it is not a drift signal for the cluster's real state.
#
# The only thing that can observe real addon state is
# `scripts/setup-minikube.sh`, which enables the addons and is the single entry
# point for the cluster. If you want to know whether the cluster still matches
# the baseline, run `minikube addons list -p platform` and compare — that check
# belongs in a shell script, not here.
#
# A caller-wiring assertion is still worth having: it guarantees the root keeps
# passing the documented baseline, so a later edit to the call site has to be a
# deliberate one. That is what this is for.
#
# An OpenTofu `check` block reports a failed assertion as a Warning, not an
# error: `tofu plan` still exits 0 (verified against OpenTofu 1.7.0 on
# 2026-09-26). So this is a *signal*, not a gate — do not write CI that relies
# on the exit code. Anything that must hard-fail belongs in a resource
# `precondition`, or in the shell script.
locals {
  expected_addons = toset(["ingress", "metrics-server"])
}

check "addons_match" {
  assert {
    condition     = toset(var.addons) == local.expected_addons
    error_message = <<-EOT
      The addons passed by the caller no longer match the baseline recorded in
      modules/minikube_addons/main.tf. Update one or the other deliberately.

      NOTE: this check compares two literals in this repository. It does NOT
      read the cluster and cannot detect an addon disabled at runtime. To check
      real addon state, run: minikube addons list -p platform
    EOT
  }
}
