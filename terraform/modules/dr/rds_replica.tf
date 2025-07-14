# Cross-Region Read Replica for RDS in the DR region

# Get AWS Account ID for ARN construction
data "aws_caller_identity" "current" {
  provider = aws
}

locals {
  dr_db_identifier = "${var.environment}-dr-${var.app_name}-db"
  dr_db_subnet_group_name = "${var.environment}-dr-${var.app_name}-subnet-group"
  # Construct the ARN for the source database
  source_db_arn = "arn:aws:rds:${data.aws_region.primary.id}:${data.aws_caller_identity.current.account_id}:db:${var.source_db_instance_id}"
}

# Create DB subnet group in DR region
resource "aws_db_subnet_group" "dr" {
  count       = var.enable_db_replica ? 1 : 0
  provider    = aws.dr
  name        = local.dr_db_subnet_group_name
  subnet_ids  = module.vpc.private_subnet_ids
  
  tags = {
    Name        = local.dr_db_subnet_group_name
    Environment = "${var.environment}-dr"
  }
}

# Security group for DR RDS instance
resource "aws_security_group" "dr_rds" {
  count       = var.enable_db_replica ? 1 : 0
  provider    = aws.dr
  name        = "${var.environment}-dr-${var.app_name}-rds-sg"
  description = "Security group for RDS instance in DR region"
  vpc_id      = module.vpc.vpc_id
  
  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    security_groups = [module.ecs.ecs_security_group_id]
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name        = "${var.environment}-dr-${var.app_name}-rds-sg"
    Environment = "${var.environment}-dr"
  }
}

# Create cross-region read replica
resource "aws_db_instance" "dr_replica" {
  count                   = var.enable_db_replica ? 1 : 0
  provider                = aws.dr
  identifier              = local.dr_db_identifier
  replicate_source_db     = local.source_db_arn
  instance_class          = var.db_instance_class
  vpc_security_group_ids  = [aws_security_group.dr_rds[0].id]
  db_subnet_group_name    = aws_db_subnet_group.dr[0].name
  publicly_accessible     = false
  skip_final_snapshot     = true
  apply_immediately       = true
  auto_minor_version_upgrade = false
  storage_encrypted       = true
  kms_key_id             = aws_kms_key.dr_rds_key[0].arn
  
  tags = {
    Name        = local.dr_db_identifier
    Environment = "${var.environment}-dr"
  }

  # Ignore changes to these attributes since they're controlled by the source DB
  lifecycle {
    ignore_changes = [
      engine,
      username,
      password,
      allocated_storage,
      max_allocated_storage,
      backup_retention_period,
      backup_window,
      maintenance_window,
      parameter_group_name,
      kms_key_id
    ]
  }
}

# Update the DR secrets manager with the DR database endpoint
resource "aws_secretsmanager_secret_version" "dr_db_secret_version_update" {
  count         = var.enable_db_replica ? 1 : 0
  provider      = aws.dr
  secret_id     = aws_secretsmanager_secret.dr_db_secret.id
  secret_string = jsonencode({
    DATABASE_HOST = aws_db_instance.dr_replica[0].address
    DATABASE_USER = jsondecode(data.aws_secretsmanager_secret_version.primary_db_secret_version.secret_string).DATABASE_USER
    DATABASE_PASSWORD = jsondecode(data.aws_secretsmanager_secret_version.primary_db_secret_version.secret_string).DATABASE_PASSWORD
    DATABASE_NAME = jsondecode(data.aws_secretsmanager_secret_version.primary_db_secret_version.secret_string).DATABASE_NAME
  })
  depends_on    = [aws_db_instance.dr_replica]
}

# Output the DR RDS endpoint
output "dr_db_endpoint" {
  description = "Endpoint of the DR RDS read replica"
  value       = var.enable_db_replica ? aws_db_instance.dr_replica[0].address : "No RDS replica created"
}

output "dr_db_identifier" {
  description = "Identifier of the DR RDS instance"
  value       = local.dr_db_identifier
}
