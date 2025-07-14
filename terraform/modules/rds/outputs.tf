output "db_endpoint" {
  description = "The endpoint of the database"
  value       = aws_db_instance.main.endpoint
}

output "db_address" {
  description = "The hostname of the database instance"
  value       = aws_db_instance.main.address
}

output "db_name" {
  description = "The name of the database"
  value       = aws_db_instance.main.db_name
}

output "db_port" {
  description = "The port of the database"
  value       = aws_db_instance.main.port
}

output "db_identifier" {
  description = "The identifier of the database instance"
  value       = aws_db_instance.main.identifier
}
