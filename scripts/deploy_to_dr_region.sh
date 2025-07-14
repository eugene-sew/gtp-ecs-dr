#!/bin/bash
# Script to deploy ECS task definitions to disaster recovery region

# Default configuration (can be overridden by environment variables)
SOURCE_REGION=${SOURCE_REGION:-"eu-west-1"}
DR_REGION=${DR_REGION:-"eu-central-1"}
ENVIRONMENT=${ENVIRONMENT:-"dev"}
APP_NAME=${APP_NAME:-"bmdb"}  # Just 'bmdb' without environment prefix
TASK_DEF_DIR=${OUTPUT_DIR:-"../task-definitions"}

# DR configuration
DR_ENV="${ENVIRONMENT}-dr"

# Show configuration
echo "Configuration:"
echo "  Source Region: $SOURCE_REGION"
echo "  DR Region: $DR_REGION"
echo "  Environment: $ENVIRONMENT"
echo "  DR Environment: $DR_ENV"
echo "  Application: $APP_NAME"

echo "Deploying ECS resources to DR region ($DR_REGION)..."

# Check if task definition file exists
TASK_DEF_FILE="$TASK_DEF_DIR/${ENVIRONMENT}-${APP_NAME}-task-definition-clean.json"
if [ ! -f "$TASK_DEF_FILE" ]; then
  echo "Error: Task definition file not found: $TASK_DEF_FILE"
  echo "Please run extract_task_definitions.sh first."
  exit 1
fi

# Fix region references in the task definition for cross-region compatibility
echo "Preparing task definition for $DR_REGION..."
DR_TASK_DEF_FILE="$TASK_DEF_DIR/${ENVIRONMENT}-${APP_NAME}-task-definition-dr.json"

# Create a copy with region replaced in all ARNs
cat "$TASK_DEF_FILE" | sed "s/$SOURCE_REGION/$DR_REGION/g" > "$DR_TASK_DEF_FILE"
echo "Task definition prepared for DR region: $DR_TASK_DEF_FILE"

# Register the task definition in the DR region
echo "Registering task definition in $DR_REGION..."
TASK_DEF_ARN=$(aws ecs register-task-definition --region $DR_REGION --cli-input-json file://$DR_TASK_DEF_FILE --query 'taskDefinition.taskDefinitionArn' --output text)

if [ -z "$TASK_DEF_ARN" ]; then
  echo "Error: Failed to register task definition in DR region."
  exit 1
fi

echo "Successfully registered task definition in DR region: $TASK_DEF_ARN"

# Check if DR cluster exists, create if it doesn't
DR_CLUSTER_NAME="${DR_ENV}-${APP_NAME}-cluster"
CLUSTER_EXISTS=$(aws ecs list-clusters --region $DR_REGION --query "contains(clusterArns, '*/$DR_CLUSTER_NAME')" --output text)

if [ "$CLUSTER_EXISTS" != "true" ]; then
  echo "Creating ECS cluster in DR region..."
  aws ecs create-cluster --region $DR_REGION --cluster-name "$DR_CLUSTER_NAME" --settings "name=containerInsights,value=disabled"
  echo "ECS cluster created: $DR_CLUSTER_NAME"
else
  echo "ECS cluster already exists in DR region."
fi

# Update service if it exists, otherwise provide instructions
DR_SERVICE_NAME="${DR_ENV}-${APP_NAME}-service"
SERVICE_EXISTS=$(aws ecs list-services --region $DR_REGION --cluster "$DR_CLUSTER_NAME" --query "contains(serviceArns, '*/$DR_SERVICE_NAME')" --output text)

if [ "$SERVICE_EXISTS" == "true" ]; then
  echo "Updating ECS service in DR region with new task definition..."
  aws ecs update-service --region $DR_REGION --cluster "$DR_CLUSTER_NAME" --service "$DR_SERVICE_NAME" --task-definition $TASK_DEF_ARN --force-new-deployment
  echo "ECS service updated in DR region."
else
  echo "INFO: ECS service does not exist in DR region."
  echo "To create a service, you need to have supporting infrastructure (VPC, subnets, security groups, etc.)."
  echo "Consider using Terraform to create the complete DR infrastructure."
fi

# Log the deployment
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
echo "$TIMESTAMP: Deployed $TASK_DEF_ARN to $DR_REGION" >> $TASK_DEF_DIR/dr_deployments.log

echo "Deployment to DR region completed."
exit 0
