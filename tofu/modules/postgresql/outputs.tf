output "connection_string" {
  description = "PostgreSQL connection string for applications."
  value       = "postgresql://${var.postgres_user}:${var.postgres_password}@${helm_release.postgresql.name}-rw.${var.namespace}.svc.cluster.local:5432/${var.postgres_db}?sslmode=disable"
}

output "pgbouncer_connection_string" {
  description = "PgBouncer connection string for applications."
  value       = "postgresql://${var.postgres_user}:${var.postgres_password}@${helm_release.postgresql.name}-pgbouncer.${var.namespace}.svc.cluster.local:5433/${var.postgres_db}?sslmode=disable"
}