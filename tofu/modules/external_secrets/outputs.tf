output "crd_names" {
  description = "CRDs the operator installs — asserted by the verify script."
  value = [
    "clustersecretstores.external-secrets.io",
    "externalsecrets.external-secrets.io",
    "secretstores.external-secrets.io",
  ]
}
