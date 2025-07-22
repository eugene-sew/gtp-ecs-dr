#!/bin/bash
# DR Deactivation Script - Scales down services in DR region after primary region is restored

# Default configuration (can be overridden by environment variables)
DR_REGION=${DR_REGION:-"eu-central-1"}
SOURCE_REGION=${SOURCE_REGION:-"eu-west-1"}
ENVIRONMENT=${ENVIRONMENT:-"dev"}
APP_NAME=${APP_NAME:-"bmdb"}
PRIMARY_DESIRED_COUNT=${PRIMARY_DESIRED_COUNT:-2}  # Number of tasks to run in primary region
DNS_TTL=${DNS_TTL:-60}  # TTL for DNS changes in seconds
SYNC_DATA=${SYNC_DATA:-"false"}  # Whether to attempt syncing data back to primary database

# Environment configuration
DR_ENV="${ENVIRONMENT}-dr"
DR_CLUSTER_NAME="${DR_ENV}-${APP_NAME}-cluster"
DR_SERVICE_NAME="${DR_ENV}-${APP_NAME}-service"
PRIMARY_CLUSTER_NAME="${ENVIRONMENT}-${APP_NAME}-cluster"
PRIMARY_SERVICE_NAME="${ENVIRONMENT}-${APP_NAME}-service"
PRIMARY_DB_IDENTIFIER="${ENVIRONMENT}-${APP_NAME}-db"
DR_DB_IDENTIFIER="${ENVIRONMENT}-dr-${APP_NAME}-db"
PRIMARY_SECRET_NAME="${ENVIRONMENT}-${APP_NAME}/database-credentials"
DR_SECRET_NAME="${DR_ENV}-${APP_NAME}/database-credentials"

# Show configuration
echo "DR DEACTIVATION - FAILBACK TO PRIMARY"
echo "============================"
echo "Configuration:"
echo "  Primary Region: $SOURCE_REGION"
echo "  DR Region: $DR_REGION"
echo "  Environment: $ENVIRONMENT"
echo "  DR Environment: $DR_ENV"
echo "  Application: $APP_NAME"
echo "  Sync DB Data Back: $SYNC_DATA"
echo "============================"
echo "WARNING: This will initiate failback to the primary region!"
echo "Press CTRL+C within 5 seconds to abort..."
sleep 5

echo "Proceeding with DR deactivation..."

# Step 1: Verify primary region infrastructure is available
echo "Verifying ECS resources in primary region ($SOURCE_REGION)..."

PRIMARY_CLUSTER_EXISTS=$(aws ecs describe-clusters --region $SOURCE_REGION --clusters $PRIMARY_CLUSTER_NAME --query 'clusters[0].status' --output text 2>/dev/null)
if [ "$PRIMARY_CLUSTER_EXISTS" != "ACTIVE" ]; then
  echo "Error: ECS cluster '$PRIMARY_CLUSTER_NAME' does not exist or is not active in $SOURCE_REGION."
  echo "Please restore primary region infrastructure before failback."
  exit 1
fi

PRIMARY_SERVICE_EXISTS=$(aws ecs describe-services --region $SOURCE_REGION --cluster $PRIMARY_CLUSTER_NAME --services $PRIMARY_SERVICE_NAME --query 'services[0].status' --output text 2>/dev/null)
if [ "$PRIMARY_SERVICE_EXISTS" != "ACTIVE" ]; then
  echo "Error: ECS service '$PRIMARY_SERVICE_NAME' does not exist or is not active in $SOURCE_REGION."
  echo "Please restore primary region infrastructure before failback."
  exit 1
fi

# Verify primary DB exists and is available
echo "Verifying primary database in $SOURCE_REGION..."
PRIMARY_DB_STATUS=$(aws rds describe-db-instances --db-instance-identifier $PRIMARY_DB_IDENTIFIER --region $SOURCE_REGION --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null)
if [ "$PRIMARY_DB_STATUS" != "available" ]; then
  echo "Warning: Primary database '$PRIMARY_DB_IDENTIFIER' is not available in $SOURCE_REGION (status: $PRIMARY_DB_STATUS)."
  echo "The primary database must be in 'available' state for failback."
  echo "Continue anyway? (y/n)"
  read -r CONTINUE
  if [ "$CONTINUE" != "y" ]; then
    exit 1
  fi
fi

# Step 2: Scale up the primary region ECS service
echo "Scaling up ECS service in primary region to $PRIMARY_DESIRED_COUNT tasks..."

PRIMARY_UPDATE_RESULT=$(aws ecs update-service --region $SOURCE_REGION --cluster $PRIMARY_CLUSTER_NAME --service $PRIMARY_SERVICE_NAME --desired-count $PRIMARY_DESIRED_COUNT --force-new-deployment)
if [ $? -ne 0 ]; then
  echo "Error: Failed to update primary ECS service."
  exit 1
fi

# Step 3: Get ALB information for DNS update in primary region
PRIMARY_ALB_DNS=$(aws ecs describe-services --region $SOURCE_REGION --cluster $PRIMARY_CLUSTER_NAME --services $PRIMARY_SERVICE_NAME --query 'services[0].loadBalancers[0].loadBalancerName' --output text 2>/dev/null)
if [ -n "$PRIMARY_ALB_DNS" ]; then
  PRIMARY_ALB_HOSTNAME=$(aws elbv2 describe-load-balancers --region $SOURCE_REGION --names $PRIMARY_ALB_DNS --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null)
  echo "Primary Load Balancer DNS: $PRIMARY_ALB_HOSTNAME"
  echo ""
  echo "IMPORTANT: Update your DNS records to point back to $PRIMARY_ALB_HOSTNAME"
  echo "Example Route 53 command:"
  echo "aws route53 change-resource-record-sets --hosted-zone-id YOUR_ZONE_ID --change-batch '{\"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"your-app.example.com\",\"Type\":\"CNAME\",\"TTL\":$DNS_TTL,\"ResourceRecords\":[{\"Value\":\"$PRIMARY_ALB_HOSTNAME\"}]}}]}'"
fi

# Step 4: Wait for primary region to be ready
echo "Monitoring primary service deployment (press CTRL+C to exit monitoring)..."
aws ecs describe-services --region $SOURCE_REGION --cluster $PRIMARY_CLUSTER_NAME --services $PRIMARY_SERVICE_NAME --query 'services[0].{Status:status,DesiredCount:desiredCount,RunningCount:runningCount,PendingCount:pendingCount}'
echo ""
echo "Waiting for primary tasks to start (this may take a few minutes)..."
sleep 10

# Loop until desired count matches running count or timeout occurs in primary region
TIMEOUT=300 # 5 minutes timeout
START_TIME=$(date +%s)
while true; do
  CURRENT_TIME=$(date +%s)
  ELAPSED=$((CURRENT_TIME - START_TIME))
  
  if [ $ELAPSED -gt $TIMEOUT ]; then
    echo "Timeout reached while waiting for primary tasks to start."
    break
  fi
  
  SERVICE_STATUS=$(aws ecs describe-services --region $SOURCE_REGION --cluster $PRIMARY_CLUSTER_NAME --services $PRIMARY_SERVICE_NAME --query 'services[0].{DesiredCount:desiredCount,RunningCount:runningCount,PendingCount:pendingCount}' --output json)
  DESIRED=$(echo $SERVICE_STATUS | jq -r '.DesiredCount')
  RUNNING=$(echo $SERVICE_STATUS | jq -r '.RunningCount')
  PENDING=$(echo $SERVICE_STATUS | jq -r '.PendingCount')
  
  echo "Primary Status: Desired=$DESIRED, Running=$RUNNING, Pending=$PENDING"
  
  if [ "$RUNNING" -eq "$DESIRED" ] && [ "$PENDING" -eq 0 ]; then
    echo "All primary tasks are running successfully!"
    break
  fi
  
  sleep 10
done

# Step 5: After primary is ready, scale down DR
echo "Primary region is ready. Scaling down DR region to 0 tasks..."
DR_UPDATE_RESULT=$(aws ecs update-service --region $DR_REGION --cluster $DR_CLUSTER_NAME --service $DR_SERVICE_NAME --desired-count 0)
if [ $? -ne 0 ]; then
  echo "Warning: Failed to scale down DR ECS service."
else
  echo "Successfully scaled down DR region to 0 tasks."
fi

# Step 6: Handle database failback if requested
if [ "$SYNC_DATA" == "true" ]; then
  echo ""
  echo "Database failback preparation..."
  
  # Check if DR database is available and was promoted (standalone)
  echo "Checking DR database status..."
  DR_DB_STATUS=$(aws rds describe-db-instances --db-instance-identifier $DR_DB_IDENTIFIER --region $DR_REGION --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null)
  
  if [ "$DR_DB_STATUS" != "available" ]; then
    echo "Warning: DR database is not in available state (status: $DR_DB_STATUS). Skipping data sync."
  else
    echo "DR database is available. Initiating automated data sync..."
    
    # Get the path to the sync script
    SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
    SYNC_SCRIPT="$SCRIPT_DIR/sync_dr_to_primary.sh"
    
    if [ -f "$SYNC_SCRIPT" ] && [ -x "$SYNC_SCRIPT" ]; then
      echo "Running database synchronization script..."
      
      # Export environment variables needed by the sync script
      export DR_REGION=$DR_REGION
      export SOURCE_REGION=$SOURCE_REGION
      export ENVIRONMENT=$ENVIRONMENT
      export APP_NAME=$APP_NAME
      
      # Execute the script with current environment variables
      "$SYNC_SCRIPT"
      
      if [ $? -ne 0 ]; then
        echo "Error: Database synchronization failed. Check the output for details."
        echo "You may need to run the sync_dr_to_primary.sh script manually."
      else
        echo "Database synchronization completed successfully."
      fi
    else
      echo "Error: Database sync script not found or not executable: $SYNC_SCRIPT"
      echo "Please ensure sync_dr_to_primary.sh exists in the same directory and is executable."
      
      # Fallback to displaying manual instructions
      echo "Manual synchronization instructions:"
      
      # Get database endpoints
      DR_DB_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier $DR_DB_IDENTIFIER --region $DR_REGION --query 'DBInstances[0].Endpoint.Address' --output text)
      PRIMARY_DB_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier $PRIMARY_DB_IDENTIFIER --region $SOURCE_REGION --query 'DBInstances[0].Endpoint.Address' --output text)
      
      # Get database credentials from Secrets Manager
      DR_SECRET_ARN=$(aws secretsmanager list-secrets --region $DR_REGION --query "SecretList[?Name=='$DR_SECRET_NAME'].ARN" --output text)
      PRIMARY_SECRET_ARN=$(aws secretsmanager list-secrets --region $SOURCE_REGION --query "SecretList[?Name=='$PRIMARY_SECRET_NAME'].ARN" --output text)
      
      DR_DB_USER=$(aws secretsmanager get-secret-value --secret-id $DR_SECRET_ARN --region $DR_REGION --query 'SecretString' --output text | jq -r '.DATABASE_USER')
      DR_DB_NAME=$(aws secretsmanager get-secret-value --secret-id $DR_SECRET_ARN --region $DR_REGION --query 'SecretString' --output text | jq -r '.DATABASE_NAME')
      
      PRIMARY_DB_USER=$(aws secretsmanager get-secret-value --secret-id $PRIMARY_SECRET_ARN --region $SOURCE_REGION --query 'SecretString' --output text | jq -r '.DATABASE_USER')
      PRIMARY_DB_NAME=$(aws secretsmanager get-secret-value --secret-id $PRIMARY_SECRET_ARN --region $SOURCE_REGION --query 'SecretString' --output text | jq -r '.DATABASE_NAME')
      
      echo "1. Create a dump from the DR database:"
      echo "   mysqldump -h $DR_DB_ENDPOINT -u $DR_DB_USER -p $DR_DB_NAME > dr_dump.sql"
      echo ""
      echo "2. Restore to the primary database:"
      echo "   mysql -h $PRIMARY_DB_ENDPOINT -u $PRIMARY_DB_USER -p $PRIMARY_DB_NAME < dr_dump.sql"
    fi
  fi
fi

echo ""
echo "DR DEACTIVATION COMPLETE"
echo "======================="
echo "Primary environment is now active with $PRIMARY_DESIRED_COUNT tasks running"
echo "DR environment has been scaled down to 0 tasks"
echo "Remember to update your DNS records if not using Route 53 automated updates"
echo ""
echo "Database Failback Steps:"
if [ "$SYNC_DATA" == "true" ]; then
  echo "1. Data sync from DR to primary was attempted automatically"
else
  echo "1. To sync data from DR to primary, run this script with SYNC_DATA=true"
fi
echo "2. Once data is synced, re-create the cross-region read replica in the DR region using Terraform:"
echo "   terraform apply -var=\"enable_dr=true\" -var=\"enable_db_replica=true\""
echo ""
echo "For additional database synchronization options:"
echo "./sync_dr_to_primary.sh --help"
echo "3. Verify that replication is working correctly"
echo ""
echo "Note: When re-creating the cross-region read replica, you'll need to apply Terraform with:"
echo "terraform apply -var=\"enable_dr=true\""
echo "This will re-establish the DR database replication."
