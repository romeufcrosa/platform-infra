terraform {
  backend "local" {
    # State lives beside the configuration. Phase 1 teaches PR-driven
    # applies, not backend architecture; the move to S3 + DynamoDB
    # locking is recorded in docs/adr/0006-state-backend.md.
    path = "environments/local/terraform.tfstate"
  }
}
