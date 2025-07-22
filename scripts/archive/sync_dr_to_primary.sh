#!/bin/bash
# This script automates the data synchronization from the DR database to the primary database
# Run this during failback after the primary region infrastructure has been restored

# Default configuration (can be overridden by environment variables)
DR_REGION=${DR_REGION:-"eu-central-1"}
SOURCE_REGION=${SOURCE_REGION:-"eu-west-1"}
ENVIRONMENT=${ENVIRONMENT:-"dev"}
APP_NAME=${APP_NAME:-"bmdb"}
SYNC_METHOD=${SYNC_METHOD:-"dump"}  # Options: dump, aws_dms (for future use)
SYNC_TIMEOUT=${SYNC_TIMEOUT:-1800}  # 30 minutes timeout for data sync
RECREATE_REPLICA=${RECREATE_REPLICA:-"false"}  # Whether to recreate DR read replica after sync

# Configuration
DR_ENV="${ENVIRONMENT}-dr"
PRIMARY_DB_IDENTIFIER="${ENVIRONMENT}-${APP_NAME}-instance"  # Using "instance" based on output we saw
DR_DB_IDENTIFIER="${ENVIRONMENT}-dr-${APP_NAME}-db"
PRIMARY_SECRET_NAME="${ENVIRONMENT}-${APP_NAME}/database-credentials"
DR_SECRET_NAME="${DR_ENV}-${APP_NAME}/database-credentials"

# Show configuration
echo "DATABASE FAILBACK - SYNC FROM DR TO PRIMARY"
echo "=========================================="
echo "Configuration:"
echo "  Primary Region: $SOURCE_REGION"
echo "  DR Region: $DR_REGION"
echo "  Environment: $ENVIRONMENT"
echo "  DR Environment: $DR_ENV"
echo "  Application: $APP_NAME"
echo "  Sync Method: $SYNC_METHOD"
echo "  Recreate Replica: $RECREATE_REPLICA"
echo "=========================================="
echo "WARNING: This will synchronize data from DR database to primary!"
echo "Ensure that the primary database is running and ready to accept data."
echo "Press CTRL+C within 5 seconds to abort..."
sleep 5

echo "Proceeding with database synchronization..."

# Step 1: Verify databases are available
echo "Checking database availability..."

PRIMARY_DB_STATUS=$(aws rds describe-db-instances --db-instance-identifier $PRIMARY_DB_IDENTIFIER --region $SOURCE_REGION --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null)
if [ "$PRIMARY_DB_STATUS" != "available" ]; then
  echo "Error: Primary database '$PRIMARY_DB_IDENTIFIER' is not available in $SOURCE_REGION (status: $PRIMARY_DB_STATUS)."
  echo "The primary database must be in 'available' state for failback."
  exit 1
fi

DR_DB_STATUS=$(aws rds describe-db-instances --db-instance-identifier $DR_DB_IDENTIFIER --region $DR_REGION --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null)
if [ "$DR_DB_STATUS" != "available" ]; then
  echo "Error: DR database '$DR_DB_IDENTIFIER' is not available in $DR_REGION (status: $DR_DB_STATUS)."
  exit 1
fi

echo "Both databases are available and ready for sync."

# Step 2: Get database endpoints and credentials
echo "Retrieving database connection details..."

# Get database endpoints
DR_DB_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier $DR_DB_IDENTIFIER --region $DR_REGION --query 'DBInstances[0].Endpoint.Address' --output text)
PRIMARY_DB_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier $PRIMARY_DB_IDENTIFIER --region $SOURCE_REGION --query 'DBInstances[0].Endpoint.Address' --output text)

# Get database credentials from Secrets Manager
DR_SECRET_ARN=$(aws secretsmanager list-secrets --region $DR_REGION --query "SecretList[?Name=='$DR_SECRET_NAME'].ARN" --output text)
PRIMARY_SECRET_ARN=$(aws secretsmanager list-secrets --region $SOURCE_REGION --query "SecretList[?Name=='$PRIMARY_SECRET_NAME'].ARN" --output text)

if [ -z "$DR_SECRET_ARN" ] || [ -z "$PRIMARY_SECRET_ARN" ]; then
  echo "Error: Could not find database secrets in one or both regions."
  exit 1
fi

DR_SECRET=$(aws secretsmanager get-secret-value --secret-id $DR_SECRET_ARN --region $DR_REGION --query 'SecretString' --output text)
PRIMARY_SECRET=$(aws secretsmanager get-secret-value --secret-id $PRIMARY_SECRET_ARN --region $SOURCE_REGION --query 'SecretString' --output text)

DR_DB_USER=$(echo $DR_SECRET | jq -r '.DATABASE_USER')
DR_DB_PASSWORD=$(echo $DR_SECRET | jq -r '.DATABASE_PASSWORD')
DR_DB_NAME=$(echo $DR_SECRET | jq -r '.DATABASE_NAME')

PRIMARY_DB_USER=$(echo $PRIMARY_SECRET | jq -r '.DATABASE_USER')
PRIMARY_DB_PASSWORD=$(echo $PRIMARY_SECRET | jq -r '.DATABASE_PASSWORD')
PRIMARY_DB_NAME=$(echo $PRIMARY_SECRET | jq -r '.DATABASE_NAME')

echo "Database connection details retrieved successfully."

# Step 3: Perform data synchronization
echo "Starting data synchronization using method: $SYNC_METHOD"

# Create a temp directory for our sync work
TEMP_DIR=$(mktemp -d)
DUMP_FILE="$TEMP_DIR/${APP_NAME}_dr_dump.sql"

case $SYNC_METHOD in
  dump)
    echo "Using MySQL dump and restore method..."
    
    # Install MySQL client if needed
    if ! command -v mysql &> /dev/null || ! command -v mysqldump &> /dev/null; then
      echo "Installing MySQL client tools..."
      apt-get update && apt-get install -y default-mysql-client || \
      yum install -y mysql || \
      brew install mysql-client
      
      if [ $? -ne 0 ]; then
        echo "Error: Failed to install MySQL client tools."
        echo "Please install MySQL client tools manually and try again."
        rm -rf $TEMP_DIR
        exit 1
      fi
    fi
    
    # Create MySQL config files with credentials to avoid command line exposure
    DR_CNF="$TEMP_DIR/dr_mysql.cnf"
    PRIMARY_CNF="$TEMP_DIR/primary_mysql.cnf"
    
    cat > $DR_CNF << EOF
[client]
user=$DR_DB_USER
password=$DR_DB_PASSWORD
EOF

    cat > $PRIMARY_CNF << EOF
[client]
user=$PRIMARY_DB_USER
password=$PRIMARY_DB_PASSWORD
EOF

    chmod 600 $DR_CNF $PRIMARY_CNF
    
    # Step 3.1: Dump data from DR database
    echo "Creating dump from DR database ($DR_DB_ENDPOINT)..."
    mysqldump --defaults-file=$DR_CNF -h $DR_DB_ENDPOINT --set-gtid-purged=OFF --single-transaction --routines --triggers --databases $DR_DB_NAME > $DUMP_FILE
    
    if [ $? -ne 0 ] || [ ! -s $DUMP_FILE ]; then
      echo "Error: Failed to create database dump from DR database."
      rm -rf $TEMP_DIR
      exit 1
    fi
    
    DUMP_SIZE=$(du -h $DUMP_FILE | cut -f1)
    echo "Dump created successfully. Size: $DUMP_SIZE"
    
    # Step 3.2: Restore to primary database
    echo "Restoring dump to primary database ($PRIMARY_DB_ENDPOINT)..."
    mysql --defaults-file=$PRIMARY_CNF -h $PRIMARY_DB_ENDPOINT < $DUMP_FILE
    
    if [ $? -ne 0 ]; then
      echo "Error: Failed to restore database dump to primary database."
      echo "Dump file is preserved at: $DUMP_FILE"
      echo "You can attempt a manual restore using:"
      echo "  mysql -h $PRIMARY_DB_ENDPOINT -u $PRIMARY_DB_USER -p $PRIMARY_DB_NAME < $DUMP_FILE"
      rm -f $DR_CNF $PRIMARY_CNF
      exit 1
    fi
    
    echo "Database restored successfully to primary region."
    ;;
    
  aws_dms)
    echo "AWS DMS method not implemented yet."
    echo "For production workloads, consider creating a DMS task to migrate data."
    echo "See: https://docs.aws.amazon.com/dms/latest/userguide/CHAP_GettingStarted.html"
    ;;
    
  *)
    echo "Error: Unknown sync method '$SYNC_METHOD'"
    echo "Supported methods: dump, aws_dms (aws_dms not implemented yet)"
    rm -rf $TEMP_DIR
    exit 1
    ;;
esac

# Clean up temporary files
rm -rf $TEMP_DIR

# Step 4: Recreate read replica if requested
if [ "$RECREATE_REPLICA" == "true" ]; then
  echo "Recreating cross-region read replica using Terraform..."
  echo "Note: This requires Terraform to be properly configured."
  
  # This assumes you're running the script from the ECS-IAC directory
  cd /Users/admin/Desktop/AmaliTech-GTP/ECS-IAC/terraform
  terraform apply -var="enable_dr=true" -auto-approve
  
  if [ $? -ne 0 ]; then
    echo "Warning: Failed to recreate cross-region read replica with Terraform."
    echo "You may need to run Terraform manually to recreate the DR infrastructure."
  else
    echo "Cross-region read replica recreation initiated successfully."
  fi
fi

echo ""
echo "DATABASE FAILBACK COMPLETE"
echo "========================="
echo "Data has been synchronized from DR to primary database."
echo "If you've completed all failback steps, you can now:"
echo "1. Verify application functionality in the primary region"
echo "2. If you didn't recreate the replica, run: terraform apply -var=\"enable_dr=true\""
echo ""
