#!/bin/bash
# Script to extract ECS task definitions and save them to the infrastructure repo

# Default configuration (can be overridden by environment variables)
SOURCE_REGION=${SOURCE_REGION:-"eu-west-1"}
DR_REGION=${DR_REGION:-"eu-central-1"}
ENVIRONMENT=${ENVIRONMENT:-"dev"}
APP_NAME=${APP_NAME:-"bmdb"}
OUTPUT_DIR=${OUTPUT_DIR:-"../task-definitions"}

# Derived values (following Terraform naming conventions)
CLUSTER_NAME="${ENVIRONMENT}-${APP_NAME}-cluster"
SERVICE_NAME="${ENVIRONMENT}-${APP_NAME}-service"

# Show configuration
echo "Configuration:"
echo "  Source Region: $SOURCE_REGION"
echo "  DR Region: $DR_REGION"
echo "  Environment: $ENVIRONMENT"
echo "  Application: $APP_NAME"
echo "  Cluster: $CLUSTER_NAME"
echo "  Service: $SERVICE_NAME"

# Create output directory if it doesn't exist
mkdir -p $OUTPUT_DIR

echo "Extracting task definitions from $SOURCE_REGION..."

# Get the current task definition ARN from the service
TASK_DEF_ARN=$(aws ecs describe-services --region $SOURCE_REGION --cluster $CLUSTER_NAME --services $SERVICE_NAME --query 'services[0].taskDefinition' --output text)

if [ -z "$TASK_DEF_ARN" ]; then
  echo "Error: Could not retrieve task definition ARN."
  exit 1
fi

echo "Found task definition: $TASK_DEF_ARN"
TASK_DEF_NAME=$(echo $TASK_DEF_ARN | cut -d "/" -f 2 | cut -d ":" -f 1)
TASK_DEF_REVISION=$(echo $TASK_DEF_ARN | cut -d ":" -f 2)

# Extract the task definition to JSON file
echo "Extracting task definition $TASK_DEF_NAME:$TASK_DEF_REVISION to JSON..."
FULL_OUTPUT_NAME="$OUTPUT_DIR/${ENVIRONMENT}-${APP_NAME}-task-definition-latest.json"
CLEAN_OUTPUT_NAME="$OUTPUT_DIR/${ENVIRONMENT}-${APP_NAME}-task-definition-clean.json"

aws ecs describe-task-definition --region $SOURCE_REGION --task-definition $TASK_DEF_ARN --query 'taskDefinition' > "$FULL_OUTPUT_NAME"

# Remove the read-only fields that can't be included when registering a new task definition
echo "Cleaning task definition for reuse..."
CLEANED_DEF=$(cat "$FULL_OUTPUT_NAME" | jq 'del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy, .deregisteredAt, .deregisteredReason)')
echo $CLEANED_DEF > "$CLEAN_OUTPUT_NAME"

echo "Task definition saved to $CLEAN_OUTPUT_NAME"

echo "Saving service definition..."
aws ecs describe-services --region $SOURCE_REGION --cluster $CLUSTER_NAME --services $SERVICE_NAME > $OUTPUT_DIR/$SERVICE_NAME-config.json

echo "Task definition and service configuration extracted successfully to $OUTPUT_DIR/"
echo "You can now commit these files to version control."

# Generate a timestamp for version tracking
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
echo $TIMESTAMP > $OUTPUT_DIR/last_extracted.txt

exit 0
