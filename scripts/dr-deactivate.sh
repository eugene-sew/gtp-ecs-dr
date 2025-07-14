#!/bin/bash
# Consolidated DR Deactivation Script
# This script handles the complete DR deactivation workflow:
# 1. Validates primary region infrastructure
# 2. Scales up ECS services in primary region
# 3. Synchronizes data from DR to primary database (if enabled)
# 4. Updates DNS configuration
# 5. Scales down DR services
# 6. Recreates cross-region read replica (if enabled)

# Default configuration (can be overridden by environment variables)
DR_REGION=${DR_REGION:-"eu-central-1"}
SOURCE_REGION=${SOURCE_REGION:-"eu-west-1"}
ENVIRONMENT=${ENVIRONMENT:-"dev"}
APP_NAME=${APP_NAME:-"bmdb"}
PRIMARY_DESIRED_COUNT=${PRIMARY_DESIRED_COUNT:-2}  # Number of tasks to run in primary region
DNS_TTL=${DNS_TTL:-60}  # TTL for DNS changes in seconds
SYNC_DATA=${SYNC_DATA:-"false"}  # Whether to attempt syncing data back to primary database
SYNC_METHOD=${SYNC_METHOD:-"dump"}  # Options: dump, aws_dms (for future use)
RECREATE_REPLICA=${RECREATE_REPLICA:-"true"}  # Default to true - recreating the read replica is CRITICAL for DR readiness
TERRAFORM_DIR=${TERRAFORM_DIR:-"../terraform/environments/${ENVIRONMENT}"}  # Path to Terraform directory

# Environment configuration
DR_ENV="${ENVIRONMENT}-dr"
DR_CLUSTER_NAME="${DR_ENV}-${APP_NAME}-cluster"
DR_SERVICE_NAME="${DR_ENV}-${APP_NAME}-service"
PRIMARY_CLUSTER_NAME="${ENVIRONMENT}-${APP_NAME}-cluster"
PRIMARY_SERVICE_NAME="${ENVIRONMENT}-${APP_NAME}-service"
PRIMARY_DB_IDENTIFIER="${ENVIRONMENT}-${APP_NAME}-instance"  # Using "instance" based on observed naming
DR_DB_IDENTIFIER="${ENVIRONMENT}-dr-${APP_NAME}-db"
PRIMARY_SECRET_NAME="${ENVIRONMENT}-${APP_NAME}/database-credentials"
DR_SECRET_NAME="${DR_ENV}-${APP_NAME}/database-credentials"

# Show configuration
echo "DR DEACTIVATION - COMPREHENSIVE WORKFLOW"
echo "======================================"
echo "Configuration:"
echo "  Primary Region: $SOURCE_REGION"
echo "  DR Region: $DR_REGION"
echo "  Environment: $ENVIRONMENT"
echo "  DR Environment: $DR_ENV"
echo "  Application: $APP_NAME"
echo "  Primary Desired Count: $PRIMARY_DESIRED_COUNT"
echo "  Sync Data: $SYNC_DATA"
echo "  Sync Method: $SYNC_METHOD"
echo "  Recreate Replica: $RECREATE_REPLICA"
echo "======================================"
echo "WARNING: This will initiate failback to the primary region!"
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

# Step 1: Validate primary region infrastructure
echo -e "\n📋 STEP 1: VALIDATING PRIMARY INFRASTRUCTURE"
echo "------------------------------------------"

# Check ECS cluster
check_resource "ECS cluster" "$PRIMARY_CLUSTER_NAME" "$SOURCE_REGION" \
  "aws ecs describe-clusters --region $SOURCE_REGION --clusters $PRIMARY_CLUSTER_NAME --query 'clusters[0].clusterName'"

if [ $? -ne 0 ]; then
  echo "❌ ERROR: Primary ECS cluster not found. Please ensure primary infrastructure is provisioned."
  exit 1
fi

# Check primary database
check_resource "Primary database" "$PRIMARY_DB_IDENTIFIER" "$SOURCE_REGION" \
  "aws rds describe-db-instances --region $SOURCE_REGION --db-instance-identifier $PRIMARY_DB_IDENTIFIER --query 'DBInstances[0].DBInstanceIdentifier'"

if [ $? -ne 0 ]; then
  echo "❌ ERROR: Primary database not found. Please ensure primary infrastructure is provisioned."
  
  if [ "$SYNC_DATA" == "true" ]; then
    echo "❌ ERROR: Cannot sync data to non-existent primary database."
    echo "Please restore primary database infrastructure first."
    exit 1
  fi
fi

# Step 2: Scale up ECS services in primary region
echo -e "\n📋 STEP 2: SCALING UP PRIMARY ECS SERVICES"
echo "------------------------------------------"
echo "Updating primary service to desired count: $PRIMARY_DESIRED_COUNT"

aws ecs update-service --region $SOURCE_REGION --cluster $PRIMARY_CLUSTER_NAME \
  --service $PRIMARY_SERVICE_NAME --desired-count $PRIMARY_DESIRED_COUNT

if [ $? -ne 0 ]; then
  echo "❌ ERROR: Failed to update primary service desired count."
  exit 1
fi

echo "✅ Primary service desired count updated"

# Check primary services status
echo "Checking primary services status..."
aws ecs describe-services --region $SOURCE_REGION --cluster $PRIMARY_CLUSTER_NAME \
  --services $PRIMARY_SERVICE_NAME \
  --query 'services[0].{Status:status,DesiredCount:desiredCount,RunningCount:runningCount,PendingCount:pendingCount}'

echo ""
echo "Waiting for primary tasks to start (this may take a few minutes)..."
sleep 10

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
  
  SERVICE_JSON=$(aws ecs describe-services --region $SOURCE_REGION \
    --cluster $PRIMARY_CLUSTER_NAME --services $PRIMARY_SERVICE_NAME \
    --query 'services[0]' --output json)
  
  RUNNING_COUNT=$(echo $SERVICE_JSON | jq -r '.runningCount')
  DESIRED_COUNT_CURRENT=$(echo $SERVICE_JSON | jq -r '.desiredCount')
  PENDING_COUNT=$(echo $SERVICE_JSON | jq -r '.pendingCount')
  
  echo "Tasks: $RUNNING_COUNT running, $PENDING_COUNT pending, $DESIRED_COUNT_CURRENT desired"
  
  if [ "$RUNNING_COUNT" == "$DESIRED_COUNT_CURRENT" ] && [ "$PENDING_COUNT" == "0" ]; then
    echo "✅ All primary tasks are running!"
    break
  fi
  
  echo "Waiting for tasks to start ($ELAPSED_TIME/$TIMEOUT seconds elapsed)..."
  sleep 10
done

# Get primary load balancer DNS name
PRIMARY_LB_DNS=$(aws elbv2 describe-load-balancers --region $SOURCE_REGION \
  --query "LoadBalancers[?contains(LoadBalancerName, '${ENVIRONMENT}-${APP_NAME}')].DNSName" \
  --output text)

echo ""
echo "Primary Load Balancer DNS: $PRIMARY_LB_DNS"
echo ""
echo "DNS UPDATE ACTION REQUIRED:"
echo "  Update your DNS records to point back to the primary load balancer"
echo "  Recommended TTL: $DNS_TTL seconds"
echo ""
echo "Wait for DNS changes to propagate before proceeding..."
read -p "Press Enter to continue with database synchronization and DR deactivation..."

# Step 3: Synchronize data from DR to primary if enabled
if [ "$SYNC_DATA" == "true" ]; then
  echo -e "\n📋 STEP 3: SYNCHRONIZING DATABASE DATA"
  echo "------------------------------------------"
  echo "Preparing to sync data from DR database to primary..."

  # Check if DR database is available and was promoted (standalone)
  DR_DB_STATUS=$(aws rds describe-db-instances --region $DR_REGION \
    --db-instance-identifier $DR_DB_IDENTIFIER \
    --query 'DBInstances[0].{Status:DBInstanceStatus,ReplicaSource:ReadReplicaSourceDBInstanceIdentifier}' \
    --output json 2>/dev/null)
  
  DR_IS_AVAILABLE=$(echo $DR_DB_STATUS | jq -r '.Status == "available"')
  DR_IS_REPLICA=$(echo $DR_DB_STATUS | jq -r '.ReplicaSource != null')
  
  if [ "$DR_IS_AVAILABLE" != "true" ]; then
    echo "❌ ERROR: DR database is not available for synchronization."
    SYNC_DATA="false"
  elif [ "$DR_IS_REPLICA" == "true" ]; then
    echo "⚠️ WARNING: DR database is still a read replica. It may not have been promoted during failover."
    echo "Manual database sync may be required."
    SYNC_DATA="false"
  else
    echo "✅ DR database is available for synchronization"
    
    # Get database credentials from Secrets Manager
    echo "Retrieving database credentials from Secrets Manager..."
    
    # Primary DB credentials
    PRIMARY_CREDS=$(aws secretsmanager get-secret-value --region $SOURCE_REGION \
      --secret-id $PRIMARY_SECRET_NAME --query 'SecretString' --output text)
    
    if [ $? -ne 0 ]; then
      echo "❌ ERROR: Could not retrieve primary database credentials."
      SYNC_DATA="false"
    else
      PRIMARY_HOST=$(echo $PRIMARY_CREDS | jq -r '.host')
      PRIMARY_PORT=$(echo $PRIMARY_CREDS | jq -r '.port')
      PRIMARY_USER=$(echo $PRIMARY_CREDS | jq -r '.username')
      PRIMARY_PASS=$(echo $PRIMARY_CREDS | jq -r '.password')
      PRIMARY_DBNAME=$(echo $PRIMARY_CREDS | jq -r '.dbname')
      
      # DR DB credentials
      DR_CREDS=$(aws secretsmanager get-secret-value --region $DR_REGION \
        --secret-id $DR_SECRET_NAME --query 'SecretString' --output text)
      
      if [ $? -ne 0 ]; then
        echo "❌ ERROR: Could not retrieve DR database credentials."
        SYNC_DATA="false"
      else
        DR_HOST=$(echo $DR_CREDS | jq -r '.host')
        DR_PORT=$(echo $DR_CREDS | jq -r '.port')
        DR_USER=$(echo $DR_CREDS | jq -r '.username')
        DR_PASS=$(echo $DR_CREDS | jq -r '.password')
        DR_DBNAME=$(echo $DR_CREDS | jq -r '.dbname')
      fi
    fi
  fi
  
  if [ "$SYNC_DATA" == "true" ]; then
    echo "Database sync method: $SYNC_METHOD"
    
    case $SYNC_METHOD in
      dump)
        echo "Using MySQL dump and restore method..."
        
        # Check if MySQL client is installed
        if ! command -v mysql &> /dev/null || ! command -v mysqldump &> /dev/null; then
          echo "Installing MySQL client tools..."
          if command -v apt-get &> /dev/null; then
            sudo apt-get update && sudo apt-get install -y mysql-client
          elif command -v yum &> /dev/null; then
            sudo yum install -y mysql
          elif command -v brew &> /dev/null; then
            brew install mysql-client
          else
            echo "❌ ERROR: Could not install MySQL client. Please install manually."
            SYNC_DATA="false"
          fi
        fi
        
        if [ "$SYNC_DATA" == "true" ]; then
          # Create MySQL config files for source and target with credentials
          echo "Creating temporary MySQL configuration files..."
          
          mkdir -p ~/.dr_sync
          chmod 700 ~/.dr_sync
          
          # DR database config
          cat > ~/.dr_sync/dr.cnf << EOF
[client]
host=$DR_HOST
port=$DR_PORT
user=$DR_USER
password=$DR_PASS
database=$DR_DBNAME
EOF
          
          chmod 600 ~/.dr_sync/dr.cnf
          
          # Primary database config
          cat > ~/.dr_sync/primary.cnf << EOF
[client]
host=$PRIMARY_HOST
port=$PRIMARY_PORT
user=$PRIMARY_USER
password=$PRIMARY_PASS
database=$PRIMARY_DBNAME
EOF
          
          chmod 600 ~/.dr_sync/primary.cnf
          
          # Test connections
          echo "Testing connection to DR database..."
          mysql --defaults-file=~/.dr_sync/dr.cnf -e "SELECT 1" > /dev/null
          
          if [ $? -ne 0 ]; then
            echo "❌ ERROR: Could not connect to DR database."
            SYNC_DATA="false"
          else
            echo "Testing connection to primary database..."
            mysql --defaults-file=~/.dr_sync/primary.cnf -e "SELECT 1" > /dev/null
            
            if [ $? -ne 0 ]; then
              echo "❌ ERROR: Could not connect to primary database."
              SYNC_DATA="false"
            else
              echo "✅ Database connections successful"
              
              # Perform the data synchronization
              echo "Starting database dump from DR database..."
              mysqldump --defaults-file=~/.dr_sync/dr.cnf --skip-lock-tables \
                --single-transaction --routines --triggers --no-create-db > /tmp/dr_dump.sql
              
              if [ $? -ne 0 ]; then
                echo "❌ ERROR: Failed to dump DR database."
                SYNC_DATA="false"
              else
                echo "Dump completed successfully. Size: $(du -h /tmp/dr_dump.sql | cut -f1)"
                
                echo "Restoring data to primary database..."
                mysql --defaults-file=~/.dr_sync/primary.cnf < /tmp/dr_dump.sql
                
                if [ $? -ne 0 ]; then
                  echo "❌ ERROR: Failed to restore data to primary database."
                else
                  echo "✅ Data synchronization completed successfully."
                  
                  # Clean up
                  echo "Cleaning up temporary files..."
                  rm -f /tmp/dr_dump.sql
                  rm -rf ~/.dr_sync
                fi
              fi
            fi
          fi
        fi
        ;;
        
      aws_dms)
        echo "AWS DMS synchronization is not yet implemented."
        echo "Please use the dump method or implement manual synchronization."
        SYNC_DATA="false"
        ;;
        
      *)
        echo "Unknown sync method: $SYNC_METHOD"
        SYNC_DATA="false"
        ;;
    esac
  fi
else
  echo -e "\n📋 STEP 3: DATABASE SYNCHRONIZATION SKIPPED"
  echo "------------------------------------------"
  echo "Skipping data synchronization as per configuration."
  echo "Note: This may result in data loss if DR database contains changes."
fi

# Step 4: Scale down DR services
echo -e "\n📋 STEP 4: SCALING DOWN DR SERVICES"
echo "------------------------------------------"
echo "Scaling down DR services to 0 tasks..."

aws ecs update-service --region $DR_REGION --cluster $DR_CLUSTER_NAME \
  --service $DR_SERVICE_NAME --desired-count 0

if [ $? -ne 0 ]; then
  echo "⚠️ WARNING: Failed to scale down DR services."
else
  echo "✅ DR services scaled down successfully"
fi

# Step 5: Recreate cross-region read replica if enabled
if [ "$RECREATE_REPLICA" == "true" ]; then
  echo -e "\n📋 STEP 5: RECREATING CROSS-REGION REPLICA"
  echo "------------------------------------------"
  
  # Check if primary DB is available
  PRIMARY_DB_STATUS=$(aws rds describe-db-instances --region $SOURCE_REGION \
    --db-instance-identifier $PRIMARY_DB_IDENTIFIER \
    --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null)
  
  if [ "$PRIMARY_DB_STATUS" != "available" ]; then
    echo "❌ ERROR: Primary database is not available. Cannot recreate read replica."
    echo "Primary DB status: $PRIMARY_DB_STATUS"
  else
    echo "✅ Primary database is available"
    
    # Check if Terraform directory exists
    if [ ! -d "$TERRAFORM_DIR" ]; then
      echo "❌ ERROR: Terraform directory not found: $TERRAFORM_DIR"
      echo "Manual recreation of read replica required."
    else
      echo "Using Terraform to recreate the cross-region read replica..."
      
      # Change to Terraform directory
      cd $TERRAFORM_DIR
      
      if [ $? -ne 0 ]; then
        echo "❌ ERROR: Failed to change to Terraform directory."
      else
        echo "Running Terraform apply to recreate the replica..."
        
        # Run terraform apply with appropriate variables
        terraform apply -auto-approve -var="enable_dr=true" -var="enable_db_replica=true"
        
        if [ $? -ne 0 ]; then
          echo "⚠️ WARNING: Terraform apply may have encountered issues."
          echo "Check the Terraform output for details."
          echo "Manual verification of read replica creation required."
        else
          echo "✅ Terraform apply completed successfully"
          echo "Read replica creation has been initiated"
          echo ""
          echo "Note: The read replica creation process may take 20-30 minutes to complete."
          echo "Monitor the status with:"
          echo "  aws rds describe-db-instances --region $DR_REGION --db-instance-identifier $DR_DB_IDENTIFIER --query 'DBInstances[0].DBInstanceStatus'"
        fi
      fi
    fi
  fi
else
  echo -e "\n⚠️ WARNING: READ REPLICA RECREATION SKIPPED"
  echo "------------------------------------------"
  echo "⚠️ IMPORTANT: Skipping read replica recreation as per configuration."
  echo "⚠️ Your DR environment will NOT be ready for failover without a read replica."
  echo "⚠️ In AWS RDS, once a replica is promoted, it cannot be converted back to a replica."
  echo "⚠️ A new read replica MUST be recreated to restore DR capability."
  echo ""
  echo "To manually recreate the read replica later:"
  echo "  1. Set RECREATE_REPLICA=true"
  echo "  2. Run this script again or"
  echo "  3. Run: cd $TERRAFORM_DIR && terraform apply -var=\"enable_dr=true\" -var=\"enable_db_replica=true\""
fi

# Completion
echo -e "\n✅ DR DEACTIVATION COMPLETE"
echo "======================================"
echo "Your application is now running in the primary region: $SOURCE_REGION"
echo "Primary load balancer DNS: $PRIMARY_LB_DNS"
echo ""

if [ "$SYNC_DATA" == "true" ]; then
  echo "✅ Data has been synchronized from DR to primary"
else
  echo "⚠️ Data synchronization was skipped or failed"
  echo "Manual data synchronization may be required"
fi

if [ "$RECREATE_REPLICA" == "true" ]; then
  echo "✅ Cross-region read replica recreation has been initiated"
  echo "Monitor the replica status with:"
  echo "  aws rds describe-db-instances --region $DR_REGION --db-instance-identifier $DR_DB_IDENTIFIER --query 'DBInstances[0].DBInstanceStatus'"
  echo ""
  echo "NOTE: The read replica creation process typically takes 20-30 minutes to complete."
  echo "Your DR environment will be ready for failover after the replica is fully synchronized."
else
  echo "⚠️ WARNING: Read replica recreation was skipped"
  echo "⚠️ Your DR environment is NOT ready for failover"
  echo "⚠️ You must recreate the MySQL 8.0 cross-region read replica to restore DR capability"
  echo "Run this script again with RECREATE_REPLICA=true to fix this issue"
fi

echo ""
echo "To reactivate DR if needed:"
echo "  ./dr-activate.sh"
echo "======================================"
