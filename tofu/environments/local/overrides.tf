# Local-profile overrides. Everything here is a deliberate deviation from
# a production posture, and each line says why.
#
# NOT loaded by OpenTofu. OpenTofu only evaluates .tf files that belong to a
# module it was told to load, and this directory is not a module (there is
# deliberately no backend.tf here, since a second backend block in a module is
# a hard error). Later tasks reference these locals through an explicit
# `source = "./environments/local"` module call if they need them.
locals {
  vault_dev_mode                 = true # single unseal key, in-memory storage: disposable by design
  prometheus_retention           = "2d" # 30d retention is a production value; 2d keeps the laptop usable
  prometheus_persistence_enabled = false
  atlantis_replica_count         = 1
  ministack_replica_count        = 1
}
