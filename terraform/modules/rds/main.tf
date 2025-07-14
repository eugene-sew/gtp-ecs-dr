resource "aws_db_subnet_group" "main" {
  name       = "${var.environment}-bmdb-subnet-group"
  subnet_ids = var.subnet_ids

  tags = {
    Name        = "${var.environment}-bmdb-subnet-group"
    Environment = var.environment
  }
}

resource "aws_security_group" "rds" {
  name        = "${var.environment}-bmdb-rds-sg"
  description = "Allow database traffic from ECS tasks"
  vpc_id      = var.vpc_id

  ingress {
    description     = "MySQL from private subnets"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    cidr_blocks     = ["10.0.0.0/16"]  # Allow from VPC CIDR
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.environment}-bmdb-rds-sg"
    Environment = var.environment
  }
}

resource "aws_db_instance" "main" {
  identifier             = "${var.environment}-bmdb-instance"
  allocated_storage      = var.db_allocated_storage
  engine                 = "mysql"
  engine_version         = "8.0"
  instance_class         = var.db_instance_class
  db_name                = var.db_name
  username               = var.db_username
  password               = var.db_password
  parameter_group_name   = "default.mysql8.0"
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  skip_final_snapshot    = true
  multi_az               = var.environment == "prod" ? true : false
  backup_retention_period = var.environment == "prod" ? 7 : 1
  storage_encrypted      = true
  storage_type           = "gp2"  # Explicitly specify cheaper general purpose SSD
  performance_insights_enabled = var.environment == "prod" ? true : false  # Disable for dev to save costs
  monitoring_interval    = var.environment == "prod" ? 60 : 0  # Enhanced monitoring in prod only
  deletion_protection    = var.environment == "prod" ? true : false  # Protect prod but allow easy deletion in dev
  
  # Cost optimization for dev - allow auto stop/start during off hours
  copy_tags_to_snapshot = true
  
  tags = {
    Name        = "${var.environment}-bmdb-instance"
    Environment = var.environment
    # Adding automation tags for potential future auto-start/stop Lambda
    AutoStop    = var.environment == "prod" ? "false" : "true"
  }
}

# Update the secret with the RDS host address
resource "aws_secretsmanager_secret_version" "update_db_host" {
  secret_id     = var.secrets_arn
  secret_string = jsonencode({
    DATABASE_HOST     = aws_db_instance.main.address
    DATABASE_NAME     = var.db_name
    DATABASE_USER     = var.db_username
    DATABASE_PASSWORD = var.db_password
  })

  depends_on = [aws_db_instance.main]
}
