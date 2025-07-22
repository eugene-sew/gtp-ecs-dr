#!/bin/bash
# Fix DR region permissions and ensure cross-region secrets access works correctly

# Default configuration
SOURCE_REGION=${SOURCE_REGION:-"eu-west-1"}
DR_REGION=${DR_REGION:-"eu-central-1"}
ENVIRONMENT=${ENVIRONMENT:-"dev"}
APP_NAME=${APP_NAME:-"bmdb"}

# DR configuration
DR_ENV="${ENVIRONMENT}-dr"
TASK_DEF_DIR="../task-definitions"
DR_CLUSTER_NAME="${DR_ENV}-${APP_NAME}-cluster"
DR_SERVICE_NAME="${DR_ENV}-${APP_NAME}-service"

echo "DR Region Permissions Fix"
echo "========================"
echo "Configuration:"
echo "  Source Region: $SOURCE_REGION"
echo "  DR Region: $DR_REGION"
echo "  Environment: $ENVIRONMENT"
echo "  DR Environment: $DR_ENV"
echo "  Application: $APP_NAME"
echo "========================"

# Step 1: Extract needed secret values from the source region
echo "Extracting database credentials from Secrets Manager..."
SECRET_ARN=$(aws secretsmanager list-secrets --region $SOURCE_REGION --query "SecretList[?Name=='${ENVIRONMENT}-bmdb/database-credentials'].ARN" --output text)

if [ -z "$SECRET_ARN" ]; then
  echo "Error: Could not find secret ARN for database credentials."
  exit 1
fi

# Get values from the secret
echo "Reading secrets from $SECRET_ARN..."
SECRET_STRING=$(aws secretsmanager get-secret-value --region $SOURCE_REGION --secret-id $SECRET_ARN --query 'SecretString' --output text)

# Extract values from JSON
DB_HOST=$(echo $SECRET_STRING | jq -r '.DATABASE_HOST')
DB_USER=$(echo $SECRET_STRING | jq -r '.DATABASE_USER')
DB_PASSWORD=$(echo $SECRET_STRING | jq -r '.DATABASE_PASSWORD')
DB_NAME=$(echo $SECRET_STRING | jq -r '.DATABASE_NAME')

if [ -z "$DB_HOST" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASSWORD" ] || [ -z "$DB_NAME" ]; then
  echo "Error: Failed to extract all database credentials from the secret."
  exit 1
fi

# Step 2: Create a new simplified task definition with environment variables
echo "Creating a new task definition with environment variables..."

cat > "${TASK_DEF_DIR}/${ENVIRONMENT}-${APP_NAME}-task-definition-env.json" << EOL
{
  "containerDefinitions": [
    {
      "name": "${APP_NAME}",
      "image": "344837150589.dkr.ecr.${DR_REGION}.amazonaws.com/ecli-bmdb-app:latest",
      "cpu": 0,
      "portMappings": [
        {
          "containerPort": 80,
          "hostPort": 80,
          "protocol": "tcp"
        }
      ],
      "essential": true,
      "environment": [
        {
          "name": "DATABASE_HOST",
          "value": "${DB_HOST}"
        },
        {
          "name": "DATABASE_USER",
          "value": "${DB_USER}"
        },
        {
          "name": "DATABASE_PASSWORD",
          "value": "${DB_PASSWORD}"
        },
        {
          "name": "DATABASE_NAME",
          "value": "${DB_NAME}"
        }
      ],
      "mountPoints": [],
      "volumesFrom": [],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/${DR_ENV}-${APP_NAME}",
          "awslogs-region": "${DR_REGION}",
          "awslogs-stream-prefix": "ecs"
        }
      }
    }
  ],
  "family": "${ENVIRONMENT}-${APP_NAME}",
  "executionRoleArn": "arn:aws:iam::344837150589:role/${DR_ENV}-${APP_NAME}-execution-role",
  "networkMode": "awsvpc",
  "volumes": [],
  "placementConstraints": [],
  "requiresCompatibilities": [
    "FARGATE"
  ],
  "cpu": "256",
  "memory": "512"
}
EOL

DR_TASK_DEF_FILE="${TASK_DEF_DIR}/${ENVIRONMENT}-${APP_NAME}-task-definition-env.json"
echo "Task definition prepared for DR region: $DR_TASK_DEF_FILE"

# Step 3: Register the task definition in the DR region
echo "Registering task definition in $DR_REGION..."
TASK_DEF_ARN=$(aws ecs register-task-definition --region $DR_REGION --cli-input-json "file://$DR_TASK_DEF_FILE" --query 'taskDefinition.taskDefinitionArn' --output text)

if [ -z "$TASK_DEF_ARN" ]; then
  echo "Error: Failed to register task definition in DR region."
  exit 1
fi

echo "Successfully registered task definition in DR region: $TASK_DEF_ARN"

# Step 4: Check if DR service exists and update it
SERVICE_EXISTS=$(aws ecs list-services --region $DR_REGION --cluster $DR_CLUSTER_NAME --query "contains(serviceArns, '*/$DR_SERVICE_NAME')" --output text)

if [ "$SERVICE_EXISTS" == "true" ]; then
  echo "Updating ECS service in DR region with new task definition..."
  aws ecs update-service --region $DR_REGION --cluster $DR_CLUSTER_NAME --service $DR_SERVICE_NAME --task-definition $TASK_DEF_ARN
  echo "Service updated successfully."
else
  echo "INFO: ECS service does not exist in DR region."
  echo "To create a service, use Terraform to deploy the complete DR infrastructure."
fi

echo "DR region permissions fix completed."
echo "You should now be able to scale up tasks in the DR region with proper database access."
