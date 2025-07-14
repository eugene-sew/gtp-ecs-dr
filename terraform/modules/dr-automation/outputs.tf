output "lambda_function_name" {
  description = "Name of the Lambda function that synchronizes task definitions"
  value       = aws_lambda_function.task_def_sync.function_name
}

output "lambda_function_arn" {
  description = "ARN of the Lambda function that synchronizes task definitions"
  value       = aws_lambda_function.task_def_sync.arn
}

output "event_rule_name" {
  description = "Name of the EventBridge rule that schedules the sync"
  value       = aws_cloudwatch_event_rule.task_def_sync_schedule.name
}

output "event_rule_schedule" {
  description = "Schedule expression for the task definition sync"
  value       = var.sync_schedule
}
