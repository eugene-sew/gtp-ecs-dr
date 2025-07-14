# DR Task Definition Sync Automation Module
# This module creates a Lambda function that automatically synchronizes 
# task definitions between primary and DR regions on a schedule

locals {
  function_name = "${var.environment}-task-def-sync"
}

# Lambda function to synchronize task definitions
resource "aws_lambda_function" "task_def_sync" {
  function_name = local.function_name
  description   = "Automatically synchronizes ECS task definitions between primary and DR regions"
  role          = aws_iam_role.lambda_execution_role.arn
  handler       = "index.handler"
  runtime       = "python3.9"
  timeout       = 300 # 5 minutes
  memory_size   = 256

  filename = data.archive_file.lambda_package.output_path

  environment {
    variables = {
      SOURCE_REGION = var.primary_region
      DR_REGION     = var.dr_region
      ENVIRONMENT   = var.environment
      APP_NAME      = var.app_name
    }
  }

  tags = {
    Name        = local.function_name
    Environment = var.environment
  }
}

# Create Lambda deployment package
data "archive_file" "lambda_package" {
  type        = "zip"
  output_path = "${path.module}/files/lambda_package.zip"

  source {
    content  = file("${path.module}/files/index.py")
    filename = "index.py"
  }

  depends_on = [local_file.lambda_code]
}

# Lambda IAM role
resource "aws_iam_role" "lambda_execution_role" {
  name = "${local.function_name}-role"

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
}

# Lambda permissions policy
resource "aws_iam_policy" "lambda_permissions" {
  name        = "${local.function_name}-policy"
  description = "IAM policy for task definition sync Lambda function"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecs:DescribeServices",
          "ecs:DescribeTaskDefinition",
          "ecs:RegisterTaskDefinition",
          "ecs:UpdateService",
          "ecs:ListServices",
          "ecs:ListClusters",
          "ecs:CreateCluster"
        ]
        Resource = "*"
      }
    ]
  })
}

# Attach policy to role
resource "aws_iam_role_policy_attachment" "lambda_permissions_attachment" {
  role       = aws_iam_role.lambda_execution_role.name
  policy_arn = aws_iam_policy.lambda_permissions.arn
}

# EventBridge (CloudWatch Events) rule for scheduled execution
resource "aws_cloudwatch_event_rule" "task_def_sync_schedule" {
  name                = "${local.function_name}-schedule"
  description         = "Triggers task definition sync Lambda on schedule"
  schedule_expression = var.sync_schedule
}

# EventBridge target for Lambda
resource "aws_cloudwatch_event_target" "lambda_target" {
  rule      = aws_cloudwatch_event_rule.task_def_sync_schedule.name
  target_id = "LambdaFunction"
  arn       = aws_lambda_function.task_def_sync.arn
}

# Lambda permission to allow EventBridge to invoke it
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.task_def_sync.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.task_def_sync_schedule.arn
}

# Generate Lambda function code
resource "local_file" "lambda_code" {
  content  = <<-EOT
import boto3
import json
import os
import logging
from datetime import datetime

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Environment variables
SOURCE_REGION = os.environ.get('SOURCE_REGION', 'eu-west-1')
DR_REGION = os.environ.get('DR_REGION', 'eu-central-1')
ENVIRONMENT = os.environ.get('ENVIRONMENT', 'dev')
APP_NAME = os.environ.get('APP_NAME', 'bmdb')

# Derived values
CLUSTER_NAME = f"{ENVIRONMENT}-{APP_NAME}-cluster"
SERVICE_NAME = f"{ENVIRONMENT}-{APP_NAME}-service"
DR_CLUSTER_NAME = f"{ENVIRONMENT}-dr-{APP_NAME}-cluster"
DR_SERVICE_NAME = f"{ENVIRONMENT}-dr-{APP_NAME}-service"

def handler(event, context):
    """
    Lambda handler to synchronize ECS task definitions between regions
    """
    logger.info(f"Starting task definition sync from {SOURCE_REGION} to {DR_REGION}")
    logger.info(f"Environment: {ENVIRONMENT}, App: {APP_NAME}")
    
    try:
        # Get ECS clients for both regions
        source_ecs = boto3.client('ecs', region_name=SOURCE_REGION)
        dr_ecs = boto3.client('ecs', region_name=DR_REGION)
        
        # Step 1: Get current task definition from source region
        logger.info(f"Getting current task definition from {CLUSTER_NAME}/{SERVICE_NAME}")
        service_response = source_ecs.describe_services(
            cluster=CLUSTER_NAME,
            services=[SERVICE_NAME]
        )
        
        if not service_response['services']:
            logger.error(f"Service {SERVICE_NAME} not found in cluster {CLUSTER_NAME}")
            return {
                'statusCode': 404,
                'body': f"Service {SERVICE_NAME} not found"
            }
        
        task_def_arn = service_response['services'][0]['taskDefinition']
        logger.info(f"Found task definition: {task_def_arn}")
        
        # Step 2: Get task definition details
        task_def = source_ecs.describe_task_definition(
            taskDefinition=task_def_arn
        )['taskDefinition']
        
        # Step 3: Clean task definition by removing read-only fields
        clean_task_def = {
            'family': task_def['family'],
            'containerDefinitions': task_def['containerDefinitions'],
            'executionRoleArn': task_def.get('executionRoleArn', ''),
            'taskRoleArn': task_def.get('taskRoleArn', ''),
            'networkMode': task_def.get('networkMode', ''),
            'volumes': task_def.get('volumes', []),
            'placementConstraints': task_def.get('placementConstraints', []),
            'requiresCompatibilities': task_def.get('requiresCompatibilities', [])
        }
        
        # Add optional attributes only if they exist in the original task definition
        if 'cpu' in task_def:
            clean_task_def['cpu'] = task_def['cpu']
        if 'memory' in task_def:
            clean_task_def['memory'] = task_def['memory']
        
        # Step 4: Register task definition in DR region
        logger.info(f"Registering task definition in {DR_REGION}")
        dr_task_def_response = dr_ecs.register_task_definition(**clean_task_def)
        
        new_task_def_arn = dr_task_def_response['taskDefinition']['taskDefinitionArn']
        logger.info(f"Successfully registered task definition in DR region: {new_task_def_arn}")
        
        # Step 5: Check if DR service exists and update it
        try:
            dr_cluster_exists = False
            dr_service_exists = False
            
            # Check if DR cluster exists
            clusters = dr_ecs.list_clusters()
            for cluster_arn in clusters['clusterArns']:
                if DR_CLUSTER_NAME in cluster_arn:
                    dr_cluster_exists = True
                    break
            
            if not dr_cluster_exists:
                logger.info(f"Creating DR cluster: {DR_CLUSTER_NAME}")
                dr_ecs.create_cluster(clusterName=DR_CLUSTER_NAME)
                logger.info(f"Created DR cluster: {DR_CLUSTER_NAME}")
            
            # Check if DR service exists
            services = dr_ecs.list_services(cluster=DR_CLUSTER_NAME)
            for service_arn in services.get('serviceArns', []):
                if DR_SERVICE_NAME in service_arn:
                    dr_service_exists = True
                    break
            
            if dr_service_exists:
                logger.info(f"Updating DR service with new task definition")
                dr_ecs.update_service(
                    cluster=DR_CLUSTER_NAME,
                    service=DR_SERVICE_NAME,
                    taskDefinition=new_task_def_arn
                )
                logger.info(f"Updated DR service with task definition: {new_task_def_arn}")
            else:
                logger.info(f"DR service doesn't exist yet. Task definition is registered and ready.")
                
        except Exception as e:
            logger.warning(f"Could not update DR service: {str(e)}")
            logger.info("Task definition has been registered but service not updated")
        
        return {
            'statusCode': 200,
            'body': json.dumps({
                'message': 'Task definition sync completed successfully',
                'sourceTaskDefinition': task_def_arn,
                'drTaskDefinition': new_task_def_arn,
                'timestamp': datetime.now().isoformat()
            })
        }
        
    except Exception as e:
        logger.error(f"Error syncing task definitions: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({
                'message': f"Error syncing task definitions: {str(e)}",
                'timestamp': datetime.now().isoformat()
            })
        }
EOT
  filename = "${path.module}/files/index.py"

  # Ensure the directory exists
  depends_on = [local_file.ensure_dir]
}

# Ensure the files directory exists
resource "local_file" "ensure_dir" {
  content  = ""
  filename = "${path.module}/files/.gitkeep"

  # Create the directory if it doesn't exist
  provisioner "local-exec" {
    command = "mkdir -p ${path.module}/files"
  }
}
