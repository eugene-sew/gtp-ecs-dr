#!/bin/bash
# manage-rds-snapshots.sh - Creates and manages RDS snapshots with cross-region copying
#
# This script creates manual RDS snapshots in the primary region and copies them to the DR region.
# It also manages snapshot retention by removing older snapshots beyond the retention period.
# Designed for MySQL 8.0 databases with cross-region DR requirements.

set -e

# Configuration
SOURCE_REGION=${SOURCE_REGION:-"eu-west-1"}
DR_REGION=${DR_REGION:-"eu-central-1"}
ENVIRONMENT=${ENVIRONMENT:-"dev"}
APP_NAME=${APP_NAME:-"bmdb"}
DB_INSTANCE_ID="${ENVIRONMENT}-${APP_NAME}-db"
DR_DB_INSTANCE_ID="${ENVIRONMENT}-dr-${APP_NAME}-db"
RETENTION_DAYS=${RETENTION_DAYS:-7}
SNAPSHOT_PREFIX="${ENVIRONMENT}-${APP_NAME}"
TIMESTAMP=$(date +"%Y-%m-%d-%H%M%S")
SNAPSHOT_ID="${SNAPSHOT_PREFIX}-snapshot-${TIMESTAMP}"
CROSS_REGION_COPY=${CROSS_REGION_COPY:-"true"}

# Check if database exists in primary region
echo -e "\n📋 Checking if database exists in primary region..."
PRIMARY_DB=$(aws rds describe-db-instances \
  --region $SOURCE_REGION \
  --db-instance-identifier $DB_INSTANCE_ID \
  --query 'DBInstances[0].DBInstanceIdentifier' \
  --output text 2>/dev/null)

if [ $? -ne 0 ] || [ "$PRIMARY_DB" != "$DB_INSTANCE_ID" ]; then
  echo "❌ ERROR: Database $DB_INSTANCE_ID not found in region $SOURCE_REGION"
  exit 1
fi

echo "✅ Database $DB_INSTANCE_ID found in region $SOURCE_REGION"

# Get DB engine version for tags
DB_ENGINE_VERSION=$(aws rds describe-db-instances \
  --region $SOURCE_REGION \
  --db-instance-identifier $DB_INSTANCE_ID \
  --query 'DBInstances[0].EngineVersion' \
  --output text)

echo "Database engine version: $DB_ENGINE_VERSION"

# Create snapshot in primary region
echo -e "\n📋 Creating snapshot in primary region..."
aws rds create-db-snapshot \
  --region $SOURCE_REGION \
  --db-instance-identifier $DB_INSTANCE_ID \
  --db-snapshot-identifier $SNAPSHOT_ID \
  --tags "Key=Environment,Value=$ENVIRONMENT" "Key=Application,Value=$APP_NAME" "Key=EngineVersion,Value=$DB_ENGINE_VERSION"

echo "✅ Snapshot creation initiated: $SNAPSHOT_ID"

# Wait for snapshot to be available
echo -e "\n📋 Waiting for snapshot to become available..."
aws rds wait db-snapshot-available \
  --region $SOURCE_REGION \
  --db-snapshot-identifier $SNAPSHOT_ID

echo "✅ Snapshot $SNAPSHOT_ID is now available"

# Copy snapshot to DR region if enabled
if [ "$CROSS_REGION_COPY" == "true" ]; then
  echo -e "\n📋 Copying snapshot to DR region $DR_REGION..."
  
  # Check if we need to specify the KMS key for encrypted snapshots
  IS_ENCRYPTED=$(aws rds describe-db-snapshots \
    --region $SOURCE_REGION \
    --db-snapshot-identifier $SNAPSHOT_ID \
    --query 'DBSnapshots[0].Encrypted' \
    --output text)
  
  DR_SNAPSHOT_ID="${SNAPSHOT_ID}-copy"
  
  if [ "$IS_ENCRYPTED" == "true" ]; then
    echo "Source snapshot is encrypted. Using DR region KMS key for copy..."
    
    # Get KMS key in DR region (assuming naming convention)
    DR_KMS_KEY_ID=$(aws kms list-aliases \
      --region $DR_REGION \
      --query "Aliases[?AliasName=='alias/${ENVIRONMENT}-dr-${APP_NAME}-rds-key'].TargetKeyId" \
      --output text)
    
    if [ -z "$DR_KMS_KEY_ID" ]; then
      echo "⚠️ WARNING: No matching KMS key found in DR region. Will try to use default RDS key."
      aws rds copy-db-snapshot \
        --region $DR_REGION \
        --source-db-snapshot-identifier "arn:aws:rds:${SOURCE_REGION}:$(aws sts get-caller-identity --query 'Account' --output text):snapshot:${SNAPSHOT_ID}" \
        --target-db-snapshot-identifier $DR_SNAPSHOT_ID \
        --copy-tags
    else
      aws rds copy-db-snapshot \
        --region $DR_REGION \
        --source-db-snapshot-identifier "arn:aws:rds:${SOURCE_REGION}:$(aws sts get-caller-identity --query 'Account' --output text):snapshot:${SNAPSHOT_ID}" \
        --target-db-snapshot-identifier $DR_SNAPSHOT_ID \
        --kms-key-id $DR_KMS_KEY_ID \
        --copy-tags
    fi
  else
    aws rds copy-db-snapshot \
      --region $DR_REGION \
      --source-db-snapshot-identifier "arn:aws:rds:${SOURCE_REGION}:$(aws sts get-caller-identity --query 'Account' --output text):snapshot:${SNAPSHOT_ID}" \
      --target-db-snapshot-identifier $DR_SNAPSHOT_ID \
      --copy-tags
  fi
  
  echo "✅ Cross-region snapshot copy initiated: $DR_SNAPSHOT_ID"
  
  echo -e "\n📋 Waiting for DR region snapshot to become available..."
  aws rds wait db-snapshot-available \
    --region $DR_REGION \
    --db-snapshot-identifier $DR_SNAPSHOT_ID
  
  echo "✅ DR region snapshot $DR_SNAPSHOT_ID is now available"
fi

# Clean up old snapshots in primary region
echo -e "\n📋 Cleaning up old snapshots in primary region..."
CUTOFF_DATE=$(date -d "-${RETENTION_DAYS} days" +"%Y-%m-%d")

# Get list of manual snapshots for our database
OLD_SNAPSHOTS=$(aws rds describe-db-snapshots \
  --region $SOURCE_REGION \
  --snapshot-type manual \
  --db-instance-identifier $DB_INSTANCE_ID \
  --query "DBSnapshots[?SnapshotCreateTime<='${CUTOFF_DATE}'].DBSnapshotIdentifier" \
  --output text)

# Delete old snapshots
if [ -n "$OLD_SNAPSHOTS" ]; then
  echo "Found old snapshots to delete:"
  for snapshot in $OLD_SNAPSHOTS; do
    echo "  - Deleting $snapshot"
    aws rds delete-db-snapshot \
      --region $SOURCE_REGION \
      --db-snapshot-identifier $snapshot
  done
  echo "✅ Old snapshots cleanup complete"
else
  echo "No old snapshots to clean up"
fi

# Clean up old snapshots in DR region if enabled
if [ "$CROSS_REGION_COPY" == "true" ]; then
  echo -e "\n📋 Cleaning up old snapshots in DR region..."
  
  # Get list of copied snapshots with our prefix
  OLD_DR_SNAPSHOTS=$(aws rds describe-db-snapshots \
    --region $DR_REGION \
    --snapshot-type manual \
    --query "DBSnapshots[?contains(DBSnapshotIdentifier,'${SNAPSHOT_PREFIX}-snapshot-') && SnapshotCreateTime<='${CUTOFF_DATE}'].DBSnapshotIdentifier" \
    --output text)
  
  # Delete old snapshots
  if [ -n "$OLD_DR_SNAPSHOTS" ]; then
    echo "Found old DR snapshots to delete:"
    for snapshot in $OLD_DR_SNAPSHOTS; do
      echo "  - Deleting $snapshot"
      aws rds delete-db-snapshot \
        --region $DR_REGION \
        --db-snapshot-identifier $snapshot
    done
    echo "✅ Old DR snapshots cleanup complete"
  else
    echo "No old DR snapshots to clean up"
  fi
fi

echo -e "\n✅ RDS snapshot management complete"
echo "Primary snapshot ID: $SNAPSHOT_ID"
if [ "$CROSS_REGION_COPY" == "true" ]; then
  echo "DR snapshot ID: $DR_SNAPSHOT_ID"
fi
echo "Retention period: $RETENTION_DAYS days"
