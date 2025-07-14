# DR Module variables
variable "environment" {
  description = "Environment name (dev, prod)"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for DR VPC"
  type        = string
  default     = "10.1.0.0/16"
}

variable "availability_zones" {
  description = "Availability zones in DR region"
  type        = list(string)
}

variable "private_subnets" {
  description = "Private subnet CIDR blocks for DR region"
  type        = list(string)
  default     = ["10.1.1.0/24", "10.1.2.0/24"]
}

variable "public_subnets" {
  description = "Public subnet CIDR blocks for DR region"
  type        = list(string)
  default     = ["10.1.3.0/24", "10.1.4.0/24"]
}

variable "app_image" {
  description = "Docker image for the application"
  type        = string
}

variable "app_port" {
  description = "Port exposed by the application"
  type        = number
}

variable "fargate_cpu" {
  description = "CPU units for the Fargate task"
  type        = number
}

variable "fargate_memory" {
  description = "Memory for the Fargate task"
  type        = number
}

variable "db_name" {
  description = "Database name"
  type        = string
}

variable "db_username" {
  description = "Database username"
  type        = string
}

variable "db_password" {
  description = "Database password"
  type        = string
  sensitive   = true
}

variable "secrets_arn" {
  description = "ARN of the secret where database credentials are stored"
  type        = string
  default     = ""  # Will be updated during DR activation
}

# Optional DB parameters
variable "create_rds" {
  description = "Whether to create an RDS instance in DR region"
  type        = bool
  default     = false
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "Allocated storage for the database"
  type        = number
  default     = 20
}

# Business hours variables for scheduling
variable "business_hours_start" {
  description = "Start time for business hours (format: HH:MM)"
  type        = string
  default     = "08:00"
}

variable "business_hours_end" {
  description = "End time for business hours (format: HH:MM)"
  type        = string
  default     = "18:00"
}

variable "business_days" {
  description = "Days of the week considered business days"
  type        = list(string)
  default     = ["MON", "TUE", "WED", "THU", "FRI"]
}

variable "source_db_instance_id" {
  description = "ID of the source RDS instance in the primary region for creating a cross-region replica"
  type        = string
  default     = ""
}

variable "app_name" {
  description = "Name of the application"
  type        = string
  default     = "bmdb"
}

variable "enable_db_replica" {
  description = "Whether to create a cross-region read replica of the primary database"
  type        = bool
  default     = false
}
