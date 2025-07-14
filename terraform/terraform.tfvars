# Database credentials (sensitive)
db_username          = "admin"
db_password          = "lkAOU3mMeVmHaMowegm0INBxThwNaH6SuU0IcGbL"
db_name              = "bmdb"

# Application settings
aws_region           = "eu-west-1"
environment          = "dev"

# VPC settings
vpc_cidr             = "10.0.0.0/16"
availability_zones   = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]
private_subnets      = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
public_subnets       = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

# RDS settings
db_instance_class    = "db.t3.micro"
db_allocated_storage = 20

# ECS settings
app_image            = "344837150589.dkr.ecr.eu-west-1.amazonaws.com/ecli-bmdb-app:latest"
app_port             = 80
app_count            = 1
fargate_cpu          = "256"
fargate_memory       = "512"