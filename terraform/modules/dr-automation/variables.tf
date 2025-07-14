variable "environment" {
  description = "Environment name (e.g. dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "primary_region" {
  description = "AWS region for primary deployment"
  type        = string
  default     = "eu-west-1"
}

variable "dr_region" {
  description = "AWS region for disaster recovery"
  type        = string
  default     = "eu-central-1"
}

variable "app_name" {
  description = "Application name"
  type        = string
  default     = "bmdb"
}

variable "sync_schedule" {
  description = "Schedule expression for task definition synchronization (cron or rate expression)"
  type        = string
  default     = "cron(0 0 ? * MON *)" # Every Monday at midnight UTC
}
