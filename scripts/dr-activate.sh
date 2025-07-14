#!/bin/bash
# Consolidated DR Activation Script
# This script handles the complete DR activation workflow:
# 1. Validates DR infrastructure
# 2. Scales up ECS services in DR region
# 3. Promotes RDS read replica to standalone primary (if enabled)
# 4. Updates DNS configuration
# 5. Monitors services until healthy

# Default configuration (can be overridden by environment variables)
DR_REGION=${DR_REGION:-"eu-central-1"}
SOURCE_REGION=${SOURCE_REGION:-"eu-west-1"}
ENVIRONMENT=${ENVIRONMENT:-"dev"}
APP_NAME=${APP_NAME:-"bmdb"}
DESIRED_COUNT=${DESIRED_COUNT:-1}  # Number of tasks to run in DR
DNS_TTL=${DNS_TTL:-60}  # TTL for DNS changes in seconds
PROMOTE_DB=${PROMOTE_DB:-"true"}  # Whether to promote the database read replica
SYNC_TASK_DEFS=${SYNC_TASK_DEFS:-"true"}  # Whether to sync task definitions from primary

# DR configuration
DR_ENV="${ENVIRONMENT}-dr"
DR_CLUSTER_NAME="${DR_ENV}-${APP_NAME}-cluster"
DR_SERVICE_NAME="${DR_ENV}-${APP_NAME}-service"
DR_DB_IDENTIFIER="${ENVIRONMENT}-dr-${APP_NAME}-db"
DR_SECRET_NAME="${DR_ENV}-${APP_NAME}/database-credentials"
DR_TASK_DEFINITION="${DR_ENV}-${APP_NAME}"
PRIMARY_TASK_DEFINITION="${ENVIRONMENT}-${APP_NAME}"

# Show configuration
echo "DR ACTIVATION - COMPREHENSIVE WORKFLOW"
echo "===================================="
echo "Configuration:"
echo "  Primary Region: $SOURCE_REGION"
echo "  DR Region: $DR_REGION"
echo "  Environment: $ENVIRONMENT"
echo "  DR Environment: $DR_ENV"
echo "  Application: $APP_NAME"
echo "  Desired Task Count: $DESIRED_COUNT"
echo "  Promote Database: $PROMOTE_DB"
echo "  Sync Task Definitions: $SYNC_TASK_DEFS"
echo "===================================="
echo "WARNING: This will initiate a full failover to the DR region!"
echo "Press CTRL+C within 5 seconds to abort..."
sleep 5

# Function to check if a resource exists
check_resource() {
  local resource_type=$1
  local identifier=$2
  local region=$3
  local command=$4
  
  echo "Checking $resource_type: $identifier in region $region..."
  eval "$command" > /dev/null 2>&1
  
  if [ $? -eq 0 ]; then
    echo "✅ $resource_type exists"
    return 0
  else
    echo "❌ $resource_type does not exist or is not accessible"
    return 1
  fi
}

# Step 1: Validate DR infrastructure
echo -e "\n📋 STEP 1: VALIDATING DR INFRASTRUCTURE"
echo "---------------------------------------"

# Check ECS cluster
check_resource "ECS cluster" "$DR_CLUSTER_NAME" "$DR_REGION" \
  "aws ecs describe-clusters --region $DR_REGION --clusters $DR_CLUSTER_NAME --query 'clusters[0].clusterName'"

if [ $? -ne 0 ]; then
  echo "❌ ERROR: DR ECS cluster not found. Please ensure DR infrastructure is provisioned."
  exit 1
fi

# Check DB read replica if we're planning to promote it
if [ "$PROMOTE_DB" == "true" ]; then
  check_resource "RDS read replica" "$DR_DB_IDENTIFIER" "$DR_REGION" \
    "aws rds describe-db-instances --region $DR_REGION --db-instance-identifier $DR_DB_IDENTIFIER --query 'DBInstances[0].DBInstanceIdentifier'"
  
  if [ $? -ne 0 ]; then
    echo "❌ ERROR: DR database not found. Please ensure DR infrastructure is provisioned."
    exit 1
  fi
  
  # Verify it's a read replica
  IS_REPLICA=$(aws rds describe-db-instances --region $DR_REGION --db-instance-identifier $DR_DB_IDENTIFIER --query 'DBInstances[0].ReadReplicaSourceDBInstanceIdentifier' --output text)
  
  if [ "$IS_REPLICA" == "None" ]; then
    echo "⚠️ WARNING: DR database is not a read replica. It may have been promoted already."
    PROMOTE_DB="false"
  fi
fi

# Step 2: Sync task definitions if enabled
if [ "$SYNC_TASK_DEFS" == "true" ]; then
  echo -e "\n📋 STEP 2: SYNCING TASK DEFINITIONS"
  echo "---------------------------------------"
  echo "Getting latest task definition from primary region..."
  
  # Get latest active task definition from primary region
  PRIMARY_TASK_ARN=$(aws ecs describe-services --region $SOURCE_REGION --cluster ${ENVIRONMENT}-${APP_NAME}-cluster \
    --services ${ENVIRONMENT}-${APP_NAME}-service --query 'services[0].taskDefinition' --output text)
  
  if [ -z "$PRIMARY_TASK_ARN" ] || [ "$PRIMARY_TASK_ARN" == "None" ]; then
    echo "⚠️ WARNING: No active task definition found in primary region. Skipping task definition sync."
  else
    echo "Latest primary task definition: $PRIMARY_TASK_ARN"
    
    # Get task definition details
    aws ecs describe-task-definition --region $SOURCE_REGION --task-definition "$PRIMARY_TASK_ARN" \
      --query 'taskDefinition' > /tmp/primary_task_def.json
    
    # Remove system fields
    jq 'del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy)' \
      /tmp/primary_task_def.json > /tmp/primary_task_def_cleaned.json
    
    # Update the family name for DR
    jq --arg family "$DR_TASK_DEFINITION" '.family = $family' \
      /tmp/primary_task_def_cleaned.json > /tmp/dr_task_def.json
    
    # Register in DR region
    DR_TASK_ARN=$(aws ecs register-task-definition --region $DR_REGION --cli-input-json file:///tmp/dr_task_def.json \
      --query 'taskDefinition.taskDefinitionArn' --output text)
    
    echo "✅ Registered task definition in DR region: $DR_TASK_ARN"
  fi
fi

# Step 3: Scale up ECS services in DR region
echo -e "\n📋 STEP 3: SCALING UP ECS SERVICES"
echo "---------------------------------------"
echo "Updating service to desired count: $DESIRED_COUNT"

aws ecs update-service --region $DR_REGION --cluster $DR_CLUSTER_NAME \
  --service $DR_SERVICE_NAME --desired-count $DESIRED_COUNT

if [ $? -ne 0 ]; then
  echo "❌ ERROR: Failed to update service desired count."
  exit 1
fi

echo "✅ Service desired count updated"

# Step 4: Promote DB if enabled
if [ "$PROMOTE_DB" == "true" ]; then
  echo -e "\n📋 STEP 4: PROMOTING RDS READ REPLICA"
  echo "---------------------------------------"
  echo "Starting promotion of read replica to standalone database..."
  
  # Promote the read replica
  aws rds promote-read-replica --region $DR_REGION --db-instance-identifier $DR_DB_IDENTIFIER
  
  if [ $? -ne 0 ]; then
    echo "❌ ERROR: Failed to promote read replica."
    exit 1
  fi
  
  echo "✅ Database promotion initiated"
  echo "Waiting for promotion to complete (this may take several minutes)..."
  
  # Wait for the DB instance to become available
  aws rds wait db-instance-available --region $DR_REGION --db-instance-identifier $DR_DB_IDENTIFIER
  
  if [ $? -ne 0 ]; then
    echo "⚠️ WARNING: Timed out waiting for database promotion. Check status manually."
  else
    echo "✅ Database promotion completed successfully"
  fi
  
  # Get the database endpoint
  DB_ENDPOINT=$(aws rds describe-db-instances --region $DR_REGION \
    --db-instance-identifier $DR_DB_IDENTIFIER \
    --query 'DBInstances[0].Endpoint.Address' --output text)
  
  echo "New database endpoint: $DB_ENDPOINT"
  
  # Update Secrets Manager with new endpoint
  echo "Updating database endpoint in Secrets Manager..."
  
  # Get current secret value
  SECRET_VALUE=$(aws secretsmanager get-secret-value --region $DR_REGION \
    --secret-id $DR_SECRET_NAME --query 'SecretString' --output text)
  
  if [ $? -ne 0 ]; then
    echo "⚠️ WARNING: Could not retrieve secret from Secrets Manager."
  else
    # Update the host in the secret
    UPDATED_SECRET=$(echo $SECRET_VALUE | jq --arg host "$DB_ENDPOINT" '.host = $host')
    
    # Update the secret
    aws secretsmanager update-secret --region $DR_REGION \
      --secret-id $DR_SECRET_NAME --secret-string "$UPDATED_SECRET"
    
    if [ $? -eq 0 ]; then
      echo "✅ Secret updated with new database endpoint"
      
      # Restart ECS tasks to pick up the new database endpoint
      echo "Restarting ECS tasks to use the new database endpoint..."
      
      # Force deployment to restart tasks
      aws ecs update-service --region $DR_REGION --cluster $DR_CLUSTER_NAME \
        --service $DR_SERVICE_NAME --force-new-deployment
      
      if [ $? -eq 0 ]; then
        echo "✅ ECS tasks are being restarted"
      else
        echo "⚠️ WARNING: Failed to restart ECS tasks. Manual restart may be required."
      fi
    else
      echo "⚠️ WARNING: Failed to update secret. Manual update may be required."
    fi
  fi
fi

# Step 5: Monitor services until healthy
echo -e "\n📋 STEP 5: MONITORING ECS SERVICES"
echo "---------------------------------------"
echo "Waiting for ECS tasks to reach desired count..."

# Loop until desired count matches running count or timeout occurs
TIMEOUT=300 # 5 minutes timeout
START_TIME=$(date +%s)
while true; do
  CURRENT_TIME=$(date +%s)
  ELAPSED_TIME=$((CURRENT_TIME - START_TIME))
  
  if [ $ELAPSED_TIME -ge $TIMEOUT ]; then
    echo "⚠️ WARNING: Timed out waiting for tasks to start."
    break
  fi
  
  SERVICE_JSON=$(aws ecs describe-services --region $DR_REGION \
    --cluster $DR_CLUSTER_NAME --services $DR_SERVICE_NAME \
    --query 'services[0]' --output json)
  
  RUNNING_COUNT=$(echo $SERVICE_JSON | jq -r '.runningCount')
  DESIRED_COUNT_CURRENT=$(echo $SERVICE_JSON | jq -r '.desiredCount')
  PENDING_COUNT=$(echo $SERVICE_JSON | jq -r '.pendingCount')
  
  echo "Tasks: $RUNNING_COUNT running, $PENDING_COUNT pending, $DESIRED_COUNT_CURRENT desired"
  
  if [ "$RUNNING_COUNT" == "$DESIRED_COUNT_CURRENT" ] && [ "$PENDING_COUNT" == "0" ]; then
    echo "✅ All tasks are running!"
    break
  fi
  
  echo "Waiting for tasks to start ($ELAPSED_TIME/$TIMEOUT seconds elapsed)..."
  sleep 10
done

# Get the load balancer DNS name
LB_DNS=$(aws elbv2 describe-load-balancers --region $DR_REGION \
  --query "LoadBalancers[?contains(LoadBalancerName, '${DR_ENV}-${APP_NAME}')].DNSName" \
  --output text)

echo -e "\n✅ DR ACTIVATION COMPLETE"
echo "===================================="
echo "Your application is now running in the DR region"
echo "Load balancer DNS: $LB_DNS"
echo ""
echo "DNS UPDATE ACTION REQUIRED:"
echo "  Update your DNS records to point to the DR load balancer"
echo "  Recommended TTL: $DNS_TTL seconds"
echo ""
echo "To monitor service health:"
echo "  aws ecs describe-services --region $DR_REGION --cluster $DR_CLUSTER_NAME --services $DR_SERVICE_NAME"
echo ""
echo "To deactivate DR and return to primary region when ready:"
echo "  ./dr-deactivate.sh"
echo "===================================="
