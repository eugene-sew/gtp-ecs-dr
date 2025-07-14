#!/bin/bash
# This script recreates the cross-region RDS read replica in the DR region after failback
# It ensures the primary database is ready and then runs Terraform to recreate the replica

# Default configuration (can be overridden by environment variables)
DR_REGION=${DR_REGION:-"eu-central-1"}
SOURCE_REGION=${SOURCE_REGION:-"eu-west-1"}
ENVIRONMENT=${ENVIRONMENT:-"dev"}
APP_NAME=${APP_NAME:-"bmdb"}
TERRAFORM_DIR=${TERRAFORM_DIR:-"/Users/admin/Desktop/AmaliTech-GTP/ECS-IAC/terraform"}
TERRAFORM_VARS=${TERRAFORM_VARS:-"-var=\"enable_dr=true\" -var=\"enable_db_replica=true\""}

# Configuration
PRIMARY_DB_IDENTIFIER="${ENVIRONMENT}-${APP_NAME}-instance"  # Using "instance" based on output we saw

# Show configuration
echo "RECREATE DR READ REPLICA"
echo "======================="
echo "Configuration:"
echo "  Primary Region: $SOURCE_REGION"
echo "  DR Region: $DR_REGION"
echo "  Environment: $ENVIRONMENT"
echo "  Application: $APP_NAME"
echo "  Terraform Directory: $TERRAFORM_DIR"
echo "  Terraform Variables: $TERRAFORM_VARS"
echo "======================="
echo "This will recreate the cross-region read replica in the DR region."
echo "Press CTRL+C within 5 seconds to abort..."
sleep 5

echo "Proceeding with read replica recreation..."

# Step 1: Verify primary database is available
echo "Verifying primary database status..."
PRIMARY_DB_STATUS=$(aws rds describe-db-instances --db-instance-identifier $PRIMARY_DB_IDENTIFIER --region $SOURCE_REGION --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null)

if [ "$PRIMARY_DB_STATUS" != "available" ]; then
  echo "Error: Primary database '$PRIMARY_DB_IDENTIFIER' is not available in $SOURCE_REGION (status: $PRIMARY_DB_STATUS)."
  echo "The primary database must be in 'available' state to create a read replica."
  exit 1
fi

echo "Primary database is available and ready."

# Step 2: Check if the Terraform directory exists
if [ ! -d "$TERRAFORM_DIR" ]; then
  echo "Error: Terraform directory does not exist: $TERRAFORM_DIR"
  exit 1
fi

# Step 3: Check if Terraform is installed
if ! command -v terraform &> /dev/null; then
  echo "Error: Terraform is not installed or not in PATH."
  exit 1
fi

# Step 4: Run Terraform to recreate the cross-region read replica
echo "Running Terraform to recreate the cross-region read replica..."
cd "$TERRAFORM_DIR" || exit 1

# Check if the workspace is initialized
if [ ! -d "$TERRAFORM_DIR/.terraform" ]; then
  echo "Initializing Terraform..."
  terraform init

  if [ $? -ne 0 ]; then
    echo "Error: Failed to initialize Terraform."
    exit 1
  fi
fi

# Apply the Terraform configuration
echo "Applying Terraform configuration to recreate read replica..."
echo "This may take some time (typically 10-20 minutes)..."

# Convert TERRAFORM_VARS string to array for proper expansion
eval "terraform apply $TERRAFORM_VARS -auto-approve"

if [ $? -ne 0 ]; then
  echo "Error: Failed to apply Terraform configuration."
  echo "Please check the error messages and try again."
  exit 1
fi

# Step 5: Verify that the read replica is being created
echo "Terraform apply completed successfully."
echo "Verifying read replica creation..."

# Wait for a moment to ensure AWS API consistency
sleep 10

# Get the DR database identifier
DR_DB_IDENTIFIER="${ENVIRONMENT}-dr-${APP_NAME}-db"

# Check if the read replica exists
DR_DB_STATUS=$(aws rds describe-db-instances --db-instance-identifier $DR_DB_IDENTIFIER --region $DR_REGION --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null)

if [ -z "$DR_DB_STATUS" ]; then
  echo "Warning: Could not find read replica '$DR_DB_IDENTIFIER' in $DR_REGION."
  echo "This may be because it's still being created. Please check the AWS Console or run:"
  echo "aws rds describe-db-instances --db-instance-identifier $DR_DB_IDENTIFIER --region $DR_REGION"
else
  echo "Read replica is being created. Current status: $DR_DB_STATUS"
  echo "It may take 10-20 minutes for the replica to be fully available."
  
  # Display replication status if available
  REPL_STATUS=$(aws rds describe-db-instances --db-instance-identifier $DR_DB_IDENTIFIER --region $DR_REGION --query 'DBInstances[0].StatusInfos[?Status==`replication`].Status' --output text 2>/dev/null)
  
  if [ -n "$REPL_STATUS" ]; then
    echo "Replication status: $REPL_STATUS"
  fi
fi

echo ""
echo "DR READ REPLICA RECREATION INITIATED"
echo "=================================="
echo "The cross-region read replica is being recreated in the DR region."
echo "To monitor the status, run:"
echo "aws rds describe-db-instances --db-instance-identifier $DR_DB_IDENTIFIER --region $DR_REGION --query 'DBInstances[0].DBInstanceStatus' --output text"
echo ""
echo "Once the read replica is available, your DR environment will be fully prepared for the next DR event."
echo "Complete DR testing is recommended to ensure the DR environment is functioning correctly."
echo ""
