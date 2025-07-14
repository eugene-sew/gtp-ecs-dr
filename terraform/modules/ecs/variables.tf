variable "environment" {
  description = "Environment name (e.g. dev, prod)"
  type        = string
}

variable "vpc_id" {
  description = "The ID of the VPC"
  type        = string
}

variable "public_subnet_ids" {
  description = "List of public subnet IDs"
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs"
  type        = list(string)
}

variable "app_image" {
  description = "Docker image for the application"
  type        = string
}

variable "app_port" {
  description = "Port exposed by the application"
  type        = number
}

variable "region" {
  description = "AWS region where resources will be created"
  type        = string
  default     = "eu-west-1"  # Default to primary region
}

variable "app_count" {
  description = "Number of docker containers to run"
  type        = number
}

variable "fargate_cpu" {
  description = "Fargate instance CPU units"
  type        = string
}

variable "enable_scheduled_scaling" {
  description = "Whether to enable scheduled scaling for cost savings during off-hours"
  type        = bool
  default     = false
}

variable "business_hours_start" {
  description = "Start time for business hours in UTC (format: HH:MM)"
  type        = string
  default     = "08:00"
}

variable "business_hours_end" {
  description = "End time for business hours in UTC (format: HH:MM)"
  type        = string
  default     = "18:00"
}

variable "business_days" {
  description = "Days of the week considered business days"
  type        = list(string)
  default     = ["MON", "TUE", "WED", "THU", "FRI"]
}

variable "fargate_memory" {
  description = "Fargate instance memory"
  type        = string
}

variable "secrets_arn" {
  description = "ARN of the secret where database credentials are stored"
  type        = string
}

variable "db_host" {
  description = "Database host address"
  type        = string
}

variable "db_name" {
  description = "Name of the database"
  type        = string
}

variable "db_username" {
  description = "Username for the database"
  type        = string
}

variable "db_password" {
  description = "Password for the database"
  type        = string
  sensitive   = true
}
