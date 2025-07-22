#!/bin/bash
# Fix DR region permissions and ensure cross-region secrets access works correctly

# Default configuration
SOURCE_REGION=${SOURCE_REGION:-"eu-west-1"}
DR_REGION=${DR_REGION:-"eu-central-1"}
ENVIRONMENT=${ENVIRONMENT:-"dev"}
APP_NAME=${APP_NAME:-"bmdb"}
APP_PORT=${APP_PORT:-"80"}
CPU=${CPU:-"256"}
MEMORY=${MEMORY:-"512"}

# DR configuration
DR_ENV="${ENVIRONMENT}-dr"
DR_CLUSTER_NAME="${DR_ENV}-${APP_NAME}-cluster"
DR_SERVICE_NAME="${DR_ENV}-${APP_NAME}-service"
TASK_DEF_DIR="../task-definitions"
DR_TASK_DEF_FILE="$TASK_DEF_DIR/${DR_ENV}-${APP_NAME}-task-definition.json"

# Create task definitions directory if it doesn't exist
mkdir -p $TASK_DEF_DIR

echo "DR Region Permissions Fix"
echo "========================"
echo "Configuration:"
echo "  Source Region: $SOURCE_REGION"
echo "  DR Region: $DR_REGION"
echo "  Environment: $ENVIRONMENT"
echo "  DR Environment: $DR_ENV"
echo "  Application: $APP_NAME"
echo "========================"

# Step 1: Find the current task definition to get the image - but use original source region image
CURRENT_TASK_DEF_ARN=$(aws ecs list-task-definitions --region $SOURCE_REGION --family-prefix $ENVIRONMENT-$APP_NAME --sort DESC --status ACTIVE --max-items 1 --query 'taskDefinitionArns[0]' --output text)

if [ -z "$CURRENT_TASK_DEF_ARN" ] || [ "$CURRENT_TASK_DEF_ARN" == "None" ]; then
  echo "Warning: No task definition found. Using default image."
  APP_IMAGE="$APP_NAME:latest"
else
  echo "Found task definition: $CURRENT_TASK_DEF_ARN"
  # Get the image from the task definition and use it directly from source region
  APP_IMAGE=$(aws ecs describe-task-definition --region $SOURCE_REGION --task-definition $CURRENT_TASK_DEF_ARN --query 'taskDefinition.containerDefinitions[0].image' --output text)
  echo "Using source region image: $APP_IMAGE"
  
  # We'll leave the image URL as is, referencing the source region's ECR
  # ECS can pull from cross-region ECR repositories as long as the execution role has permissions
fi

# Step 2: Extract needed secret values from the source region
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
PRIMARY_DB_HOST=$(echo $SECRET_STRING | jq -r '.DATABASE_HOST')
DB_USER=$(echo $SECRET_STRING | jq -r '.DATABASE_USER')
DB_PASSWORD=$(echo $SECRET_STRING | jq -r '.DATABASE_PASSWORD')
DB_NAME=$(echo $SECRET_STRING | jq -r '.DATABASE_NAME')

# Check if there's a DR region database already provisioned
echo "Checking for RDS instance in DR region..."
DR_DB_INSTANCE=$(aws rds describe-db-instances --region $DR_REGION --query "DBInstances[?DBInstanceIdentifier=='${DR_ENV}-${APP_NAME}-instance'].Endpoint.Address" --output text)

# Determine which DB host to use
if [ -n "$DR_DB_INSTANCE" ]; then
  echo "Found DR region database: $DR_DB_INSTANCE"
  DB_HOST=$DR_DB_INSTANCE
else
  echo "WARNING: No database found in DR region. Using primary region database: $PRIMARY_DB_HOST"
  echo "         In a real disaster scenario, this would not be accessible."
  DB_HOST=$PRIMARY_DB_HOST
fi

if [ -z "$DB_HOST" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASSWORD" ] || [ -z "$DB_NAME" ]; then
  echo "Error: Failed to extract all database credentials from the secret."
  exit 1
fi

# Step 3: Create a new task definition from scratch with environment variables
echo "Creating a new task definition with environment variables..."

# Get the execution role ARN for the DR region
DR_EXECUTION_ROLE="arn:aws:iam::$(aws sts get-caller-identity --query 'Account' --output text):role/${DR_ENV}-${APP_NAME}-execution-role"
echo "Using execution role: $DR_EXECUTION_ROLE"

# Create a simpler task definition with no secret references
cat > $DR_TASK_DEF_FILE << EOF
{
  "family": "${DR_ENV}-${APP_NAME}",
  "networkMode": "awsvpc",
  "executionRoleArn": "${DR_EXECUTION_ROLE}",
  "containerDefinitions": [
    {
      "name": "${APP_NAME}",
      "image": "${APP_IMAGE}",
      "essential": true,
      "portMappings": [
        {
          "containerPort": ${APP_PORT},
          "hostPort": ${APP_PORT},
          "protocol": "tcp"
        }
      ],
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
  "requiresCompatibilities": ["FARGATE"],
  "volumes": [],
  "placementConstraints": [],
  "cpu": "${CPU}",
  "memory": "${MEMORY}"
}
EOF

echo "Task definition prepared for DR region: $DR_TASK_DEF_FILE"

# Step 4: Register the task definition in the DR region
echo "Registering task definition in $DR_REGION..."
TASK_DEF_ARN=$(aws ecs register-task-definition --region $DR_REGION --cli-input-json file://$DR_TASK_DEF_FILE --query 'taskDefinition.taskDefinitionArn' --output text)

if [ -z "$TASK_DEF_ARN" ]; then
  echo "Error: Failed to register task definition in DR region."
  exit 1
fi

echo "Successfully registered task definition in DR region: $TASK_DEF_ARN"

# Step 5: Update execution role in the DR region with comprehensive ECS permissions
echo "Updating IAM execution role permissions in DR region..."

# Create an inline policy to allow ECS task to access required services including cross-region ECR
POLICY_JSON=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage"
      ],
      "Resource": [
        "arn:aws:ecr:${DR_REGION}:${ACCOUNT_ID}:repository/*",
        "arn:aws:ecr:${SOURCE_REGION}:${ACCOUNT_ID}:repository/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogStream",
        "logs:CreateLogGroup",
        "logs:PutLogEvents"
      ],
      "Resource": "*"
    }
  ]
}
EOF
)

# Create or update the inline policy for the execution role
aws iam put-role-policy --role-name "${DR_ENV}-${APP_NAME}-execution-role" --policy-name "ecs-execution-policy" --policy-document "$POLICY_JSON"

echo "IAM execution role updated with comprehensive ECS permissions."

# We're using environment variables directly in the task definition, no need for SSM parameters
echo "Using direct environment variables in task definition, skipping SSM parameter creation."

# Step 7: Check if DR service exists and update it
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
