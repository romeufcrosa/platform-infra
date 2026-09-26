# Local-profile overrides. Everything here is a deliberate deviation from
# a production posture, and each line says why.
#
# This file is LIVE, not documentation. It is the subject of the Phase 1 Atlantis
# exit criterion ("open a PR editing this file, read the plan comment"), so
# editing a value here must produce a non-empty `tofu plan` diff. That works
# because this directory is a real module: `outputs.tf` alongside this file
# forwards each local as a module output, and the root consumes
# `module.local.*`. A file no tool reads cannot be the subject of a plan review.
#
# Still no `backend.tf` here: this is a module, not a root, and a second
# backend block in the root module is a hard error.
locals {
  vault_dev_mode                 = true # single unseal key, in-memory storage: disposable by design
  prometheus_retention           = "2d" # 30d retention is a production value; 2d keeps the laptop usable
  prometheus_persistence_enabled = false
  atlantis_replica_count         = 1
  ministack_replica_count        = 1
}
