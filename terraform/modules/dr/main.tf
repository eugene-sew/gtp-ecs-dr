# DR Module - creates mirror infrastructure in the DR region

# VPC in DR region
module "vpc" {
  source             = "../vpc"
  providers = {
    aws = aws.dr
  }
  environment        = "${var.environment}-dr"
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
  private_subnets    = var.private_subnets
  public_subnets     = var.public_subnets
}

# Optional RDS instance in DR region
module "rds" {
  count  = var.create_rds ? 1 : 0
  source = "../rds"
  
  providers = {
    aws = aws.dr
  }
  
  environment        = "${var.environment}-dr"
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.private_subnet_ids
  db_name            = var.db_name
  db_username        = var.db_username
  db_password        = var.db_password
  db_instance_class  = var.db_instance_class
  db_allocated_storage = var.db_allocated_storage
  secrets_arn        = var.secrets_arn
}

# ECS cluster in DR region (standby mode)
module "ecs" {
  source = "../ecs"
  providers = {
    aws = aws.dr
  }
  
  environment       = "${var.environment}-dr"
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnet_ids
  private_subnet_ids = module.vpc.private_subnet_ids
  app_image         = var.app_image
  app_port          = var.app_port
  app_count         = 0  # Start with 0 tasks in DR to minimize costs
  fargate_cpu       = var.fargate_cpu
  fargate_memory    = var.fargate_memory
  secrets_arn       = aws_secretsmanager_secret.dr_db_secret.arn  # Use the DR region secret
  db_host           = var.create_rds ? module.rds[0].db_address : ""
  db_name           = var.db_name
  db_username       = var.db_username
  db_password       = var.db_password
  region            = data.aws_region.dr.id  # Use DR region for the ECS module
  
  # Cost optimization features for DR
  enable_scheduled_scaling = true
  business_hours_start     = var.business_hours_start
  business_hours_end       = var.business_hours_end
  business_days            = var.business_days
}

# Output the DR region resources
output "vpc_id" {
  value = module.vpc.vpc_id
}

output "ecs_cluster_name" {
  value = module.ecs.cluster_name
}

output "ecs_service_name" {
  value = module.ecs.service_name
}

# Let's check if this output exists in the ECS module
# If not, we'll need to add it or remove this output
output "task_definition_arn" {
  value = module.ecs.task_definition_arn
}

output "db_address" {
  value = var.create_rds ? module.rds[0].db_address : "No RDS created in DR region"
}

output "ecs_security_group_id" {
  description = "ID of the security group used by ECS tasks in DR region"
  value       = module.ecs.ecs_security_group_id
}

output "db_secret_id" {
  description = "ID of the DR database credentials secret"
  value       = aws_secretsmanager_secret.dr_db_secret.id
}
