/**
 * CloudWatch Monitoring Module
 * 
 * This module sets up comprehensive monitoring for ECS Fargate services and RDS MySQL instances
 * with specific focus on disaster recovery requirements:
 * - RDS replication lag monitoring (critical for DR)
 * - ECS service health in both primary and DR regions
 * - Database performance metrics
 * - Load balancer metrics
 */

# SNS Topic for CloudWatch Alarms
resource "aws_sns_topic" "monitoring_alerts" {
  name = "${var.environment}-${var.app_name}-alerts"
}

# CloudWatch Dashboard for primary region resources
resource "aws_cloudwatch_dashboard" "primary_dashboard" {
  dashboard_name = "${var.environment}-${var.app_name}-dashboard"
  
  dashboard_body = jsonencode({
    widgets = [
      # ECS Service Health Widget
      {
        type = "metric"
        x = 0
        y = 0
        width = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ServiceName", "${var.environment}-${var.app_name}-service", "ClusterName", "${var.environment}-${var.app_name}-cluster", {"stat": "Average"}],
            ["AWS/ECS", "MemoryUtilization", "ServiceName", "${var.environment}-${var.app_name}-service", "ClusterName", "${var.environment}-${var.app_name}-cluster", {"stat": "Average"}]
          ]
          view = "timeSeries"
          stacked = false
          region = var.primary_region
          title = "ECS CPU and Memory Utilization (Primary)"
          period = 300
        }
      },
      
      # RDS Metrics Widget
      {
        type = "metric"
        x = 12
        y = 0
        width = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", "${var.environment}-${var.app_name}-db", {"stat": "Average"}],
            ["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", "${var.environment}-${var.app_name}-db", {"stat": "Average"}],
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", "${var.environment}-${var.app_name}-db", {"stat": "Average"}]
          ]
          view = "timeSeries"
          stacked = false
          region = var.primary_region
          title = "RDS Performance Metrics (Primary)"
          period = 300
        }
      },
      
      # ALB Metrics Widget
      {
        type = "metric"
        x = 0
        y = 6
        width = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_Target_2XX_Count", "LoadBalancer", var.primary_alb_name],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", var.primary_alb_name],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.primary_alb_name, {"stat": "Average"}]
          ]
          view = "timeSeries"
          stacked = false
          region = var.primary_region
          title = "ALB Performance Metrics (Primary)"
          period = 300
        }
      },
      
      # DR Region - RDS Replication Widget
      {
        type = "metric"
        x = 12
        y = 6
        width = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/RDS", "ReplicaLag", "DBInstanceIdentifier", "${var.environment}-dr-${var.app_name}-db", {"stat": "Average"}],
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", "${var.environment}-dr-${var.app_name}-db", {"stat": "Average"}]
          ]
          view = "timeSeries"
          stacked = false
          region = var.dr_region
          title = "RDS Replica Metrics (DR)"
          period = 300
          annotations = {
            horizontal = [
              {
                value = 300,
                label = "5 min lag warning",
                color = "#ff9900"
              },
              {
                value = 600,
                label = "10 min lag critical",
                color = "#d13212"
              }
            ]
          }
        }
      },
      
      # DR Region - ECS Service Status
      {
        type = "metric"
        x = 0
        y = 12
        width = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ServiceName", "${var.environment}-dr-${var.app_name}-service", "ClusterName", "${var.environment}-dr-${var.app_name}-cluster", {"stat": "Average"}],
            ["AWS/ECS", "MemoryUtilization", "ServiceName", "${var.environment}-dr-${var.app_name}-service", "ClusterName", "${var.environment}-dr-${var.app_name}-cluster", {"stat": "Average"}]
          ]
          view = "timeSeries"
          stacked = false
          region = var.dr_region
          title = "ECS Resource Utilization (DR)"
          period = 300
        }
      },
      
      # DR Region - ALB Status
      {
        type = "metric"
        x = 12
        y = 12
        width = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "LoadBalancer", var.dr_alb_name, {"stat": "Average"}],
            ["AWS/ApplicationELB", "UnHealthyHostCount", "LoadBalancer", var.dr_alb_name, {"stat": "Average"}]
          ]
          view = "timeSeries"
          stacked = false
          region = var.dr_region
          title = "ALB Target Health (DR)"
          period = 300
        }
      }
    ]
  })
}

# =======================================
# CloudWatch Alarms - Primary Region
# =======================================

# Primary ECS CPU High Utilization
resource "aws_cloudwatch_metric_alarm" "primary_ecs_cpu" {
  alarm_name          = "${var.environment}-${var.app_name}-primary-ecs-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "This alarm monitors ECS service CPU utilization"
  alarm_actions       = [aws_sns_topic.monitoring_alerts.arn]
  dimensions = {
    ClusterName = "${var.environment}-${var.app_name}-cluster"
    ServiceName = "${var.environment}-${var.app_name}-service"
  }
  provider = aws.primary
}

# Primary RDS CPU High Utilization
resource "aws_cloudwatch_metric_alarm" "primary_rds_cpu" {
  alarm_name          = "${var.environment}-${var.app_name}-primary-rds-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "This alarm monitors RDS CPU utilization"
  alarm_actions       = [aws_sns_topic.monitoring_alerts.arn]
  dimensions = {
    DBInstanceIdentifier = "${var.environment}-${var.app_name}-db"
  }
  provider = aws.primary
}

# Primary RDS Low Free Storage
resource "aws_cloudwatch_metric_alarm" "primary_rds_storage" {
  alarm_name          = "${var.environment}-${var.app_name}-primary-rds-low-storage"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 2147483648 # 2 GB in bytes
  alarm_description   = "This alarm monitors RDS free storage space"
  alarm_actions       = [aws_sns_topic.monitoring_alerts.arn]
  dimensions = {
    DBInstanceIdentifier = "${var.environment}-${var.app_name}-db"
  }
  provider = aws.primary
}

# Primary ALB 5XX Error Rate High
resource "aws_cloudwatch_metric_alarm" "primary_alb_5xx" {
  alarm_name          = "${var.environment}-${var.app_name}-primary-alb-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Sum"
  threshold           = 10
  alarm_description   = "This alarm monitors ALB 5XX errors"
  alarm_actions       = [aws_sns_topic.monitoring_alerts.arn]
  dimensions = {
    LoadBalancer = var.primary_alb_name
  }
  provider = aws.primary
}

# Primary ECS Service Health
resource "aws_cloudwatch_metric_alarm" "primary_ecs_health" {
  alarm_name          = "${var.environment}-${var.app_name}-primary-ecs-health"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "RunningTaskCount"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = var.minimum_healthy_tasks
  alarm_description   = "This alarm monitors ECS service health"
  alarm_actions       = [aws_sns_topic.monitoring_alerts.arn]
  dimensions = {
    ClusterName = "${var.environment}-${var.app_name}-cluster"
    ServiceName = "${var.environment}-${var.app_name}-service"
  }
  provider = aws.primary
}

# =======================================
# CloudWatch Alarms - DR Region
# =======================================

# RDS Replication Lag
resource "aws_cloudwatch_metric_alarm" "dr_replica_lag" {
  count               = var.enable_dr ? 1 : 0
  alarm_name          = "${var.environment}-${var.app_name}-dr-replica-lag"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "ReplicaLag"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 300 # 5 minutes
  alarm_description   = "This alarm monitors RDS replication lag to the DR region"
  alarm_actions       = [aws_sns_topic.monitoring_alerts.arn]
  dimensions = {
    DBInstanceIdentifier = "${var.environment}-dr-${var.app_name}-db"
  }
  provider = aws.dr
}

# DR ALB Health
resource "aws_cloudwatch_metric_alarm" "dr_alb_health" {
  count               = var.enable_dr ? 1 : 0
  alarm_name          = "${var.environment}-${var.app_name}-dr-alb-health"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Average"
  threshold           = 1
  alarm_description   = "This alarm monitors DR ALB target health"
  alarm_actions       = [aws_sns_topic.monitoring_alerts.arn]
  dimensions = {
    LoadBalancer = var.dr_alb_name
    TargetGroup  = var.dr_target_group_name
  }
  provider = aws.dr
}

# Composite alarm for overall DR health
resource "aws_cloudwatch_composite_alarm" "dr_health" {
  count             = var.enable_dr ? 1 : 0
  alarm_name        = "${var.environment}-${var.app_name}-dr-health"
  alarm_description = "Composite alarm for overall DR health"
  
  alarm_rule = "ALARM(${aws_cloudwatch_metric_alarm.dr_replica_lag[0].alarm_name})"
  
  alarm_actions = [aws_sns_topic.monitoring_alerts.arn]
  provider      = aws.dr
}

# CloudWatch Event Rule to trigger automated backups
resource "aws_cloudwatch_event_rule" "daily_task_definition_backup" {
  name                = "${var.environment}-${var.app_name}-task-definition-backup"
  description         = "Trigger daily backup of ECS task definitions"
  schedule_expression = "cron(0 1 * * ? *)" # 1 AM UTC every day
  provider            = aws.primary
}

# CloudWatch Event Target for the task definition backup
resource "aws_cloudwatch_event_target" "task_definition_backup_target" {
  rule      = aws_cloudwatch_event_rule.daily_task_definition_backup.name
  target_id = "TaskDefinitionBackup"
  arn       = aws_lambda_function.task_definition_backup.arn
  provider  = aws.primary
}

# Lambda function to run the task definition backup
resource "aws_lambda_function" "task_definition_backup" {
  function_name = "${var.environment}-${var.app_name}-task-definition-backup"
  handler       = "index.handler"
  role          = aws_iam_role.lambda_backup_role.arn
  runtime       = "python3.9"
  timeout       = 300
  memory_size   = 512
  
  filename      = "${path.module}/lambda/task_definition_backup.zip"
  source_code_hash = filebase64sha256("${path.module}/lambda/task_definition_backup.zip")
  
  environment {
    variables = {
      SOURCE_REGION = var.primary_region
      DR_REGION     = var.dr_region
      ENVIRONMENT   = var.environment
      APP_NAME      = var.app_name
      BACKUP_BUCKET = "${var.app_name}-${var.environment}-backups"
    }
  }
  
  provider = aws.primary
}

# IAM role for the Lambda backup function
resource "aws_iam_role" "lambda_backup_role" {
  name = "${var.environment}-${var.app_name}-lambda-backup-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
  
  provider = aws.primary
}

# IAM policy for the Lambda backup function
resource "aws_iam_role_policy" "lambda_backup_policy" {
  name = "${var.environment}-${var.app_name}-lambda-backup-policy"
  role = aws_iam_role.lambda_backup_role.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Effect   = "Allow"
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Action = [
          "ecs:ListTaskDefinitions",
          "ecs:DescribeTaskDefinition"
        ]
        Effect   = "Allow"
        Resource = "*"
      },
      {
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Effect   = "Allow"
        Resource = [
          "arn:aws:s3:::${var.app_name}-${var.environment}-backups",
          "arn:aws:s3:::${var.app_name}-${var.environment}-backups/*"
        ]
      }
    ]
  })
  
  provider = aws.primary
}
