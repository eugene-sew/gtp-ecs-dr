/**
 * Variables for the monitoring module
 */

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
}

variable "app_name" {
  description = "Application name"
  type        = string
}

variable "primary_region" {
  description = "AWS region for primary resources"
  type        = string
  default     = "eu-west-1"
}

variable "dr_region" {
  description = "AWS region for DR resources"
  type        = string
  default     = "eu-central-1"
}

variable "enable_dr" {
  description = "Whether DR resources are enabled"
  type        = bool
  default     = true
}

variable "primary_alb_name" {
  description = "Name or ARN suffix of the primary ALB"
  type        = string
}

variable "dr_alb_name" {
  description = "Name or ARN suffix of the DR ALB"
  type        = string
  default     = ""
}

variable "dr_target_group_name" {
  description = "Name or ARN of the DR target group"
  type        = string
  default     = ""
}

variable "minimum_healthy_tasks" {
  description = "Minimum number of healthy ECS tasks required"
  type        = number
  default     = 1
}

variable "alarm_email" {
  description = "Email address to send CloudWatch alarms to"
  type        = string
  default     = ""
}
