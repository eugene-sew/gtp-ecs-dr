#!/bin/bash
# DR Activation Script - Scales up services in DR region during failover

# Default configuration (can be overridden by environment variables)
DR_REGION=${DR_REGION:-"eu-central-1"}
ENVIRONMENT=${ENVIRONMENT:-"dev"}
APP_NAME=${APP_NAME:-"bmdb"}
DESIRED_COUNT=${DESIRED_COUNT:-2}  # Number of tasks to run in DR
DNS_TTL=${DNS_TTL:-60}  # TTL for DNS changes in seconds
PROMOTE_DB=${PROMOTE_DB:-"true"}  # Whether to promote the database read replica

# DR configuration
DR_ENV="${ENVIRONMENT}-dr"
DR_CLUSTER_NAME="${DR_ENV}-${APP_NAME}-cluster"
DR_SERVICE_NAME="${DR_ENV}-${APP_NAME}-service"
DR_DB_IDENTIFIER="${ENVIRONMENT}-dr-${APP_NAME}-db"
DR_SECRET_NAME="${DR_ENV}-${APP_NAME}/database-credentials"

# Show configuration
echo "DR ACTIVATION - FAILOVER MODE"
echo "============================"
echo "Configuration:"
echo "  DR Region: $DR_REGION"
echo "  Environment: $ENVIRONMENT"
echo "  DR Environment: $DR_ENV"
echo "  Application: $APP_NAME"
echo "  Desired Task Count: $DESIRED_COUNT"
echo "  Promote Database: $PROMOTE_DB"
echo "============================"
echo "WARNING: This will initiate a failover to the DR region!"
echo "Press CTRL+C within 5 seconds to abort..."
sleep 5

echo "Proceeding with DR activation..."

# Step 1: Verify ECS cluster and service exist in DR region
echo "Verifying ECS resources in DR region ($DR_REGION)..."

CLUSTER_EXISTS=$(aws ecs describe-clusters --region $DR_REGION --clusters $DR_CLUSTER_NAME --query 'clusters[0].status' --output text 2>/dev/null)
if [ "$CLUSTER_EXISTS" != "ACTIVE" ]; then
  echo "Error: ECS cluster '$DR_CLUSTER_NAME' does not exist or is not active in $DR_REGION."
  echo "Run terraform apply -var=\"enable_dr=true\" to create DR infrastructure first."
  exit 1
fi

SERVICE_EXISTS=$(aws ecs describe-services --region $DR_REGION --cluster $DR_CLUSTER_NAME --services $DR_SERVICE_NAME --query 'services[0].status' --output text 2>/dev/null)
if [ "$SERVICE_EXISTS" != "ACTIVE" ]; then
  echo "Error: ECS service '$DR_SERVICE_NAME' does not exist or is not active in $DR_REGION."
  echo "Run terraform apply -var=\"enable_dr=true\" to create DR infrastructure first."
  exit 1
fi

# Step 2: Verify latest task definition is registered in DR region
TASK_DEF_FAMILY="${ENVIRONMENT}-${APP_NAME}"
TASK_DEF_EXISTS=$(aws ecs describe-task-definition --region $DR_REGION --task-definition $TASK_DEF_FAMILY --query 'taskDefinition.status' --output text 2>/dev/null)
if [ "$TASK_DEF_EXISTS" != "ACTIVE" ]; then
  echo "Error: Task definition for '$TASK_DEF_FAMILY' does not exist in $DR_REGION."
  echo "Run deploy_to_dr_region.sh to register task definitions first."
  exit 1
fi

# Step 3: Verify IAM roles and permissions are in place
TASK_DEF_ARN=$(aws ecs describe-services --region $DR_REGION --cluster $DR_CLUSTER_NAME --services $DR_SERVICE_NAME --query 'services[0].taskDefinition' --output text)
EXECUTION_ROLE_ARN=$(aws ecs describe-task-definition --region $DR_REGION --task-definition $TASK_DEF_ARN --query 'taskDefinition.executionRoleArn' --output text)

if [ -z "$EXECUTION_ROLE_ARN" ]; then
  echo "Warning: Task execution role ARN could not be determined. IAM permissions may not be correctly set up."
else
  echo "Task execution role is configured: $EXECUTION_ROLE_ARN"
fi

# Step 4: Scale up the ECS service
echo "Scaling up ECS service in DR region to $DESIRED_COUNT tasks..."

UPDATE_RESULT=$(aws ecs update-service --region $DR_REGION --cluster $DR_CLUSTER_NAME --service $DR_SERVICE_NAME --desired-count $DESIRED_COUNT --force-new-deployment)
if [ $? -ne 0 ]; then
  echo "Error: Failed to update ECS service."
  exit 1
fi

# Step 5: Get ALB information for DNS update
DR_ALB_DNS=$(aws ecs describe-services --region $DR_REGION --cluster $DR_CLUSTER_NAME --services $DR_SERVICE_NAME --query 'services[0].loadBalancers[0].loadBalancerName' --output text 2>/dev/null)
if [ -n "$DR_ALB_DNS" ]; then
  DR_ALB_HOSTNAME=$(aws elbv2 describe-load-balancers --region $DR_REGION --names $DR_ALB_DNS --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null)
  echo "DR Load Balancer DNS: $DR_ALB_HOSTNAME"
  echo ""
  echo "IMPORTANT: Update your DNS records to point to $DR_ALB_HOSTNAME"
  echo "Example Route 53 command:"
  echo "aws route53 change-resource-record-sets --hosted-zone-id YOUR_ZONE_ID --change-batch '{\"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"your-app.example.com\",\"Type\":\"CNAME\",\"TTL\":$DNS_TTL,\"ResourceRecords\":[{\"Value\":\"$DR_ALB_HOSTNAME\"}]}}]}'"
fi

# Step 6: Monitor deployment
echo "Monitoring service deployment (press CTRL+C to exit monitoring)..."
aws ecs describe-services --region $DR_REGION --cluster $DR_CLUSTER_NAME --services $DR_SERVICE_NAME --query 'services[0].{Status:status,DesiredCount:desiredCount,RunningCount:runningCount,PendingCount:pendingCount}'
echo ""
echo "Waiting for tasks to start (this may take a few minutes)..."
sleep 10

# Loop until desired count matches running count or timeout occurs
TIMEOUT=300 # 5 minutes timeout
START_TIME=$(date +%s)
while true; do
  CURRENT_TIME=$(date +%s)
  ELAPSED=$((CURRENT_TIME - START_TIME))
  
  if [ $ELAPSED -gt $TIMEOUT ]; then
    echo "Timeout reached while waiting for tasks to start."
    break
  fi
  
  SERVICE_STATUS=$(aws ecs describe-services --region $DR_REGION --cluster $DR_CLUSTER_NAME --services $DR_SERVICE_NAME --query 'services[0].{DesiredCount:desiredCount,RunningCount:runningCount,PendingCount:pendingCount}' --output json)
  DESIRED=$(echo $SERVICE_STATUS | jq -r '.DesiredCount')
  RUNNING=$(echo $SERVICE_STATUS | jq -r '.RunningCount')
  PENDING=$(echo $SERVICE_STATUS | jq -r '.PendingCount')
  
  echo "Status: Desired=$DESIRED, Running=$RUNNING, Pending=$PENDING"

  # Check for database connection issues in the tasks
  if [ "$RUNNING" -gt 0 ]; then
    TASK_ARN=$(aws ecs list-tasks --cluster $DR_CLUSTER_NAME --region $DR_REGION --query 'taskArns[0]' --output text)
    if [ -n "$TASK_ARN" ] && [ "$TASK_ARN" != "None" ]; then
      TASK_ID=$(echo $TASK_ARN | cut -d'/' -f3)
      echo "Checking logs for database connection issues in task $TASK_ID..."
      
      # Get the most recent logs
      LOG_STREAM=$(aws logs describe-log-streams --log-group-name "/ecs/$DR_ENV-$APP_NAME" --region $DR_REGION --log-stream-name-prefix "ecs/bmdb/$TASK_ID" --query 'logStreams[0].logStreamName' --output text)
      
      if [ -n "$LOG_STREAM" ] && [ "$LOG_STREAM" != "None" ]; then
        DB_CONNECTION_ERROR=$(aws logs get-log-events --log-group-name "/ecs/$DR_ENV-$APP_NAME" --log-stream-name "$LOG_STREAM" --region $DR_REGION --limit 20 --query 'events[*].message' --output text | grep -i "connection\|mysqli\|database" | grep -i "error\|exception\|timeout" | head -n 1)
        
        if [ -n "$DB_CONNECTION_ERROR" ]; then
          echo "Database connection error detected:"
          echo "$DB_CONNECTION_ERROR"
          
          if [ "$PROMOTE_DB" == "true" ]; then
            echo ""
            echo "Database error detected. Initiating database promotion..."
            ./promote_dr_database.sh
          else
            echo ""
            echo "WARNING: Database connection error detected but PROMOTE_DB is set to false."
            echo "If this is a real DR event, you may want to run ./promote_dr_database.sh manually."
          fi
        fi
      fi
    fi
  fi
  
  if [ "$RUNNING" -eq "$DESIRED" ] && [ "$PENDING" -eq 0 ]; then
    echo "All tasks are running successfully!"
    break
  fi
  
  sleep 10
done

echo ""
echo "DR ACTIVATION COMPLETE"
echo "======================="
echo "DR Environment is now active with $RUNNING tasks running"

# Final instructions based on database status
if [ "$PROMOTE_DB" == "true" ]; then
  DB_STATUS=$(aws rds describe-db-instances --db-instance-identifier $DR_DB_IDENTIFIER --region $DR_REGION --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null)
  
  if [ "$DB_STATUS" == "available" ]; then
    DB_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier $DR_DB_IDENTIFIER --region $DR_REGION --query 'DBInstances[0].Endpoint.Address' --output text)
    echo "Database Status: $DB_STATUS"
    echo "Database Endpoint: $DB_ENDPOINT"
  else
    echo "Database Status: $DB_STATUS (may still be completing promotion)"
    echo "Run 'aws rds describe-db-instances --db-instance-identifier $DR_DB_IDENTIFIER --region $DR_REGION' to check status"
  fi
fi

echo ""
echo "Remember to update your DNS records if not using Route 53 automated updates"
echo "To return to normal operations, run the deactivate_dr.sh script after primary region is restored"
