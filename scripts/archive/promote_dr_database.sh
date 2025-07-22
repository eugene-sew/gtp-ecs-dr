#!/bin/bash
# This script promotes the RDS read replica in the DR region to be a standalone primary database
# Run this during a DR event after the primary region's database is unavailable

# Default configuration (can be overridden by environment variables)
DR_REGION=${DR_REGION:-"eu-central-1"}
ENVIRONMENT=${ENVIRONMENT:-"dev"}
APP_NAME=${APP_NAME:-"bmdb"}

# DR configuration
DR_ENV="${ENVIRONMENT}-dr"
DR_DB_IDENTIFIER="${ENVIRONMENT}-dr-${APP_NAME}-db"
DR_CLUSTER_NAME="${DR_ENV}-${APP_NAME}-cluster"
DR_SERVICE_NAME="${DR_ENV}-${APP_NAME}-service"
DR_SECRET_NAME="${DR_ENV}-${APP_NAME}/database-credentials"

# Show configuration
echo "RDS DR PROMOTION - FAILOVER MODE"
echo "============================"
echo "Configuration:"
echo "  DR Region: $DR_REGION"
echo "  Environment: $ENVIRONMENT"
echo "  DR Environment: $DR_ENV"
echo "  DB Identifier: $DR_DB_IDENTIFIER"
echo "============================"
echo "WARNING: This will promote the read replica to a standalone database!"
echo "The replication link will be broken permanently."
echo "Press CTRL+C within 5 seconds to abort..."
sleep 5

echo "Proceeding with RDS promotion..."

# Step 1: Check if the replica exists
echo "Checking for read replica in DR region..."
DB_STATUS=$(aws rds describe-db-instances --db-instance-identifier $DR_DB_IDENTIFIER --region $DR_REGION --query 'DBInstances[0].StatusInfos[?Status==`replication`].Status' --output text 2>/dev/null)

if [ -z "$DB_STATUS" ]; then
  echo "Error: Read replica '$DR_DB_IDENTIFIER' does not exist in $DR_REGION or is not in replication mode."
  echo "Make sure you've deployed the cross-region read replica with Terraform first."
  exit 1
fi

echo "Read replica found with status: $DB_STATUS"

# Step 2: Promote the read replica
echo "Promoting read replica to standalone database..."
aws rds promote-read-replica --db-instance-identifier $DR_DB_IDENTIFIER --region $DR_REGION

# Step 3: Wait for promotion to complete
echo "Waiting for promotion to complete (this may take several minutes)..."

MAX_WAIT_TIME=600  # 10 minutes timeout
START_TIME=$(date +%s)

while true; do
  CURRENT_TIME=$(date +%s)
  ELAPSED=$((CURRENT_TIME - START_TIME))
  
  if [ $ELAPSED -gt $MAX_WAIT_TIME ]; then
    echo "Timeout waiting for promotion to complete."
    echo "Please check the status manually with: aws rds describe-db-instances --db-instance-identifier $DR_DB_IDENTIFIER --region $DR_REGION"
    exit 1
  fi
  
  DB_STATUS=$(aws rds describe-db-instances --db-instance-identifier $DR_DB_IDENTIFIER --region $DR_REGION --query 'DBInstances[0].StatusInfos[?Status==`replication`].Status' --output text 2>/dev/null)
  INSTANCE_STATUS=$(aws rds describe-db-instances --db-instance-identifier $DR_DB_IDENTIFIER --region $DR_REGION --query 'DBInstances[0].DBInstanceStatus' --output text)
  
  echo "Current status: Instance=$INSTANCE_STATUS, Replication=$DB_STATUS"
  
  # If the replication status is empty and the instance is available, promotion is complete
  if [ -z "$DB_STATUS" ] && [ "$INSTANCE_STATUS" = "available" ]; then
    echo "Promotion completed successfully!"
    break
  fi
  
  sleep 30  # Check every 30 seconds
done

# Step 4: Get the new endpoint
DB_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier $DR_DB_IDENTIFIER --region $DR_REGION --query 'DBInstances[0].Endpoint.Address' --output text)
echo "New primary database endpoint: $DB_ENDPOINT"

# Step 5: Update the Secrets Manager secret with the new endpoint
echo "Updating database connection information in Secrets Manager..."

# Get current secret values
SECRET_ARN=$(aws secretsmanager list-secrets --region $DR_REGION --query "SecretList[?Name=='$DR_SECRET_NAME'].ARN" --output text)

if [ -z "$SECRET_ARN" ]; then
  echo "Error: Secret '$DR_SECRET_NAME' not found in region $DR_REGION"
  exit 1
fi

# Get current secret value
SECRET_VALUE=$(aws secretsmanager get-secret-value --secret-id $SECRET_ARN --region $DR_REGION --query 'SecretString' --output text)

# Update the host field in the JSON
UPDATED_SECRET=$(echo $SECRET_VALUE | jq --arg new_host "$DB_ENDPOINT" '.DATABASE_HOST = $new_host')

# Update the secret
aws secretsmanager update-secret --secret-id $SECRET_ARN --secret-string "$UPDATED_SECRET" --region $DR_REGION

if [ $? -eq 0 ]; then
  echo "Secret updated successfully with new database endpoint."
else
  echo "Error updating secret. Please update the database endpoint manually."
  exit 1
fi

# Step 6: Restart the ECS tasks to pick up the new database endpoint
echo "Restarting ECS tasks to pick up new database connection..."
aws ecs update-service --cluster $DR_CLUSTER_NAME --service $DR_SERVICE_NAME --force-new-deployment --region $DR_REGION

if [ $? -eq 0 ]; then
  echo "ECS service updated successfully. Tasks will restart with the new database endpoint."
else
  echo "Error updating ECS service. Please restart the service manually."
  exit 1
fi

echo ""
echo "RDS DR PROMOTION COMPLETE"
echo "========================="
echo "The read replica has been promoted to a standalone database."
echo "New database endpoint: $DB_ENDPOINT"
echo "ECS tasks are being restarted to use the new database."
echo ""
echo "Note: When the primary region is restored, you will need to:"
echo "1. Set up a new replication from the primary to DR, or"
echo "2. Restore data from the DR database back to the primary."
echo ""
