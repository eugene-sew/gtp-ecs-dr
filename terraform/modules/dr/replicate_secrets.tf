# Replicate secrets from primary region to DR region

# Get secret from primary region - using data source
data "aws_secretsmanager_secret" "primary_db_secret" {
  provider = aws.primary
  arn      = var.secrets_arn
}

data "aws_secretsmanager_secret_version" "primary_db_secret_version" {
  provider  = aws.primary
  secret_id = data.aws_secretsmanager_secret.primary_db_secret.id
}

# Create replica in DR region with same name/values
resource "aws_secretsmanager_secret" "dr_db_secret" {
  provider    = aws.dr
  name        = "${var.environment}-dr-bmdb/database-credentials"
  description = "Database credentials for ${var.environment}-dr-bmdb app (DR region replica)"
  
  tags = {
    Name        = "${var.environment}-dr-bmdb-db-credentials"
    Environment = "${var.environment}-dr"
    IsReplica   = "true"
    SourceRegion = data.aws_region.primary.id
  }
}

resource "aws_secretsmanager_secret_version" "dr_db_secret_version" {
  provider      = aws.dr
  secret_id     = aws_secretsmanager_secret.dr_db_secret.id
  secret_string = data.aws_secretsmanager_secret_version.primary_db_secret_version.secret_string
}

# Output the DR secret ARN for use in ECS task definitions
output "dr_secret_arn" {
  value = aws_secretsmanager_secret.dr_db_secret.arn
}

# Get region information
data "aws_region" "primary" {
  provider = aws.primary
}

data "aws_region" "dr" {
  provider = aws.dr
}
