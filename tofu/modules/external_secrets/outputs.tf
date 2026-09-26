output "crd_names" {
  description = "CRDs the operator installs — asserted by the verify script."

  # A chart version bump MUST update this list in the same commit. The CRD set
  # is part of the operator's API contract: the chart is what installs these
  # objects, and Task 12's verify script asserts against this list. The coupling
  # is the point, not an inconvenience — an accurate list is what turns "we
  # bumped the chart" into a reviewable diff instead of a silent contract change.
  #
  # Enumerated from the live cluster, not from memory or from the chart's docs:
  #
  #   kubectl --context platform get crd -o name \
  #     | sed 's|customresourcedefinition.apiextensions.k8s.io/||'
  #
  # Taken 2026-09-26 against external-secrets 0.9.11 (appVersion v0.9.11) with
  # installCRDs=true. This is the complete set — 11 CRDs, not the 3 an earlier
  # draft of this output listed. The other eight are the generator types
  # (`*.generators.external-secrets.io`) plus ClusterExternalSecret and
  # PushSecret.
  value = [
    "acraccesstokens.generators.external-secrets.io",
    "clusterexternalsecrets.external-secrets.io",
    "clustersecretstores.external-secrets.io",
    "ecrauthorizationtokens.generators.external-secrets.io",
    "externalsecrets.external-secrets.io",
    "fakes.generators.external-secrets.io",
    "gcraccesstokens.generators.external-secrets.io",
    "passwords.generators.external-secrets.io",
    "pushsecrets.external-secrets.io",
    "secretstores.external-secrets.io",
    "vaultdynamicsecrets.generators.external-secrets.io",
  ]
}
