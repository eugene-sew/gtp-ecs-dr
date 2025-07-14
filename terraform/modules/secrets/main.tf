resource "aws_secretsmanager_secret" "database_credentials" {
  name        = "${var.environment}-bmdb/database-credentials"
  description = "Database credentials for ${var.environment} environment"

  tags = {
    Environment = var.environment
    Name        = "${var.environment}-database-credentials"
  }
}

resource "aws_secretsmanager_secret_version" "database_credentials" {
  secret_id = aws_secretsmanager_secret.database_credentials.id
  secret_string = jsonencode({
    DATABASE_HOST     = "db_host_to_be_updated"  # This will be updated after RDS creation
    DATABASE_NAME     = var.db_name
    DATABASE_USER     = var.db_username
    DATABASE_PASSWORD = var.db_password
  })
}

# We'll need a policy that allows ECS tasks to read from Secrets Manager
resource "aws_iam_policy" "secrets_access" {
  name        = "${var.environment}-bmdb-secrets-access-policy"
  description = "Policy that allows access to the database secrets"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "secretsmanager:GetSecretValue",
        ]
        Effect = "Allow"
        Resource = [
          aws_secretsmanager_secret.database_credentials.arn
        ]
      }
    ]
  })
}
