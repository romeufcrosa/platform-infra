# Every provider targets kubeconfig context `platform` (Task 2's contract).
# The helm provider's nested kubernetes block is how helm_release finds the
# cluster, so it must not drift from the kubernetes provider's.
provider "helm" {
  kubernetes {
    config_path    = pathexpand("~/.kube/config")
    config_context = var.kube_context
  }
}

provider "kubernetes" {
  config_path    = pathexpand("~/.kube/config")
  config_context = var.kube_context
}

provider "random" {}
provider "tls" {}
provider "local" {}
