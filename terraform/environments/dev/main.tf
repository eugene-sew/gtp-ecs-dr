provider "aws" {
  region = var.aws_region
}

module "bmdb_infrastructure" {
  source = "../../"
  
  environment          = var.environment
  aws_region           = var.aws_region
  
  # VPC settings
  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  private_subnets      = var.private_subnets
  public_subnets       = var.public_subnets
  
  # RDS settings
  db_name              = var.db_name
  db_username          = var.db_username
  db_password          = var.db_password
  db_instance_class    = var.db_instance_class
  db_allocated_storage = var.db_allocated_storage
  
  # ECS settings
  app_image            = var.app_image
  app_port             = var.app_port
  app_count            = var.app_count
  fargate_cpu          = var.fargate_cpu
  fargate_memory       = var.fargate_memory
}
