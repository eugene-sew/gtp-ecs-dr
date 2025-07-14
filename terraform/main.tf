# Provider configurations are in providers.tf

# VPC Module
module "vpc" {
  source = "./modules/vpc"
  
  environment       = var.environment
  vpc_cidr          = var.vpc_cidr
  availability_zones = var.availability_zones
  public_subnets    = var.public_subnets
  private_subnets   = var.private_subnets
}

# Secrets Manager Module
module "secrets" {
  source = "./modules/secrets"
  
  environment       = var.environment
  db_username       = var.db_username
  db_password       = var.db_password
  db_name           = var.db_name
}


# RDS Module
module "rds" {
  source = "./modules/rds"
  
  environment       = var.environment
  vpc_id            = module.vpc.vpc_id
  subnet_ids        = module.vpc.private_subnet_ids
  db_name           = var.db_name
  db_username       = var.db_username
  db_password       = var.db_password
  db_instance_class = var.db_instance_class
  db_allocated_storage = var.db_allocated_storage
  secrets_arn       = module.secrets.secret_arn
}

# ECS Module
module "ecs" {
  source = "./modules/ecs"
  
  environment       = var.environment
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnet_ids
  private_subnet_ids = module.vpc.private_subnet_ids
  app_image         = var.app_image
  app_port          = var.app_port
  app_count         = var.app_count
  fargate_cpu       = var.fargate_cpu
  fargate_memory    = var.fargate_memory
  secrets_arn       = module.secrets.secret_arn
  db_host           = module.rds.db_address
  db_name           = var.db_name
  db_username       = var.db_username
  db_password       = var.db_password
  
  # Cost optimization features
  enable_scheduled_scaling = var.environment == "dev" ? true : false  # Enable scheduled scaling for dev
  business_hours_start    = "08:00" 
  business_hours_end      = "18:00" 
  business_days           = ["MON", "TUE", "WED", "THU", "FRI"]
  
  depends_on        = [module.rds]
}

# Disaster Recovery Module (conditionally created)
module "dr" {
  source = "./modules/dr"
  count  = var.enable_dr ? 1 : 0  # Only create if DR is enabled
  
  providers = {
    aws.primary = aws
    aws.dr = aws.dr
  }
  
  # General configuration
  environment        = var.environment
  vpc_cidr           = var.vpc_cidr_dr
  availability_zones = ["${var.dr_region}a", "${var.dr_region}b"]
  private_subnets    = var.private_subnets_dr
  public_subnets     = var.public_subnets_dr
  
  # Application settings (same as primary region)
  app_image          = var.app_image
  app_port           = var.app_port
  fargate_cpu        = var.fargate_cpu
  fargate_memory     = var.fargate_memory
  
  # Database settings
  db_name            = var.db_name
  db_username        = var.db_username
  db_password        = var.db_password
  db_instance_class  = var.db_instance_class
  db_allocated_storage = var.db_allocated_storage
  secrets_arn        = module.secrets.secret_arn  # Use the same secret ARN as primary region
  create_rds         = false  # We use cross-region read replica instead
  
  # RDS Cross-Region Read Replica settings
  source_db_instance_id = module.rds.db_identifier
  app_name           = var.app_name
  enable_db_replica  = true  # Enable cross-region read replica for DR
  
  # Business hours for cost optimization
  business_hours_start = "08:00"
  business_hours_end   = "18:00"
  business_days        = ["MON", "TUE", "WED", "THU", "FRI"]
}

# DR Automation Module (conditionally created)
module "dr_automation" {
  source = "./modules/dr-automation"
  count  = var.enable_dr ? 1 : 0  # Only create if DR is enabled
  
  # Region configuration
  primary_region    = var.aws_region
  dr_region         = var.dr_region
  
  # Application configuration
  environment       = var.environment
  app_name          = var.app_name
  
  # Schedule - default is weekly on Monday at midnight UTC
  sync_schedule     = var.sync_schedule
}
