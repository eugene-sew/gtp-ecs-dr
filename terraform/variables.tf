variable "aws_region" {
  description = "The AWS region to deploy resources"
  type        = string
  default     = "eu-west-1"
}

variable "dr_region" {
  description = "Disaster recovery AWS region"
  type        = string
  default     = "eu-central-1"
}

variable "enable_dr" {
  description = "Whether to enable disaster recovery infrastructure"
  type        = bool
  default     = false
}

variable "environment" {
  description = "Environment name (e.g. dev, prod)"
  type        = string
  default     = "dev"
}

variable "app_name" {
  description = "Application name used for resource naming"
  type        = string
  default     = "bmdb"
}

# VPC Variables
variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of availability zones"
  type        = list(string)
  default     = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]
}

variable "private_subnets" {
  description = "List of private subnet CIDR blocks"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "public_subnets" {
  description = "List of public subnet CIDR blocks"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
}

# DR region configuration
variable "vpc_cidr_dr" {
  description = "CIDR block for the DR region VPC"
  type        = string
  default     = "10.1.0.0/16"  # Different CIDR from primary region
}

variable "availability_zones_dr" {
  description = "Availability zones in the DR region"
  type        = list(string)
  default     = ["eu-central-1a", "eu-central-1b"]
}

variable "private_subnets_dr" {
  description = "Private subnet CIDR blocks for DR region"
  type        = list(string)
  default     = ["10.1.1.0/24", "10.1.2.0/24"]
}

variable "public_subnets_dr" {
  description = "Public subnet CIDR blocks for DR region"
  type        = list(string)
  default     = ["10.1.3.0/24", "10.1.4.0/24"]
}

# RDS Variables
variable "db_name" {
  description = "Name of the database"
  type        = string
  default     = "bmdb"
}

variable "db_username" {
  description = "Username for the database"
  type        = string
  sensitive   = true
}

variable "db_password" {
  description = "Password for the database"
  type        = string
  sensitive   = true
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "Allocated storage for the database (GB)"
  type        = number
  default     = 20
}

# ECS Variables
variable "app_image" {
  description = "Docker image for the application"
  type        = string
  default     = "344837150589.dkr.ecr.eu-west-1.amazonaws.com/ecli-bmdb-app:latest"
}

variable "app_port" {
  description = "Port exposed by the application"
  type        = number
  default     = 80
}

variable "app_count" {
  description = "Number of docker containers to run"
  type        = number
  default     = 1
}

variable "fargate_cpu" {
  description = "Fargate instance CPU units"
  type        = string
  default     = "256"
}

variable "fargate_memory" {
  description = "Fargate instance memory"
  type        = string
  default     = "512"
}

# DR Automation Variables
variable "sync_schedule" {
  description = "Schedule expression for task definition synchronization (cron or rate expression)"
  type        = string
  default     = "cron(0 0 ? * MON *)" # Every Monday at midnight UTC
}
