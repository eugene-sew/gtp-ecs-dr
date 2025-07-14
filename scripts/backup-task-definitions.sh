#!/bin/bash
# backup-task-definitions.sh - Backs up ECS task definitions to S3
#
# This script extracts all ECS task definitions from both primary and DR regions,
# archives them, and stores them in an S3 bucket for historical tracking.
# It can be scheduled via CloudWatch Events/EventBridge to run on a regular basis.

set -e

# Configuration
SOURCE_REGION=${SOURCE_REGION:-"eu-west-1"}
DR_REGION=${DR_REGION:-"eu-central-1"}
ENVIRONMENT=${ENVIRONMENT:-"dev"}
APP_NAME=${APP_NAME:-"bmdb"}
BACKUP_BUCKET="${APP_NAME}-${ENVIRONMENT}-backups"
TIMESTAMP=$(date +"%Y-%m-%d-%H%M%S")
S3_PREFIX="task-definitions"
BACKUP_DIR="/tmp/task-definitions-${TIMESTAMP}"

# Create backup directories
echo "Creating backup directories..."
mkdir -p "${BACKUP_DIR}"/{primary,dr}

# Check if S3 bucket exists, create if not
echo "Checking S3 bucket..."
if ! aws s3 ls "s3://${BACKUP_BUCKET}" &> /dev/null; then
  echo "Creating S3 bucket: ${BACKUP_BUCKET}"
  # Use the SOURCE_REGION for the S3 bucket
  aws s3 mb "s3://${BACKUP_BUCKET}" --region ${SOURCE_REGION}
  
  # Enable versioning for historical tracking
  aws s3api put-bucket-versioning \
    --bucket ${BACKUP_BUCKET} \
    --versioning-configuration Status=Enabled \
    --region ${SOURCE_REGION}
  
  # Add lifecycle policy to expire old versions after 90 days
  aws s3api put-bucket-lifecycle-configuration \
    --bucket ${BACKUP_BUCKET} \
    --lifecycle-configuration '{
      "Rules": [
        {
          "ID": "ExpireOldVersions",
          "Status": "Enabled",
          "NoncurrentVersionExpiration": {
            "NoncurrentDays": 90
          },
          "Filter": {
            "Prefix": "'"${S3_PREFIX}"'/"
          }
        }
      ]
    }' \
    --region ${SOURCE_REGION}
else
  echo "Using existing S3 bucket: ${BACKUP_BUCKET}"
fi

# List and extract task definitions from primary region
echo -e "\n📋 Backing up task definitions from primary region (${SOURCE_REGION})..."
PRIMARY_TASK_DEFS=$(aws ecs list-task-definitions --region ${SOURCE_REGION} --family-prefix "${ENVIRONMENT}-${APP_NAME}" --status ACTIVE --query 'taskDefinitionArns[*]' --output text)

if [ -z "$PRIMARY_TASK_DEFS" ]; then
  echo "No task definitions found in primary region matching ${ENVIRONMENT}-${APP_NAME}"
else
  for task_def in $PRIMARY_TASK_DEFS; do
    task_name=$(echo $task_def | awk -F'/' '{print $NF}')
    echo "  - Extracting $task_name"
    aws ecs describe-task-definition --region ${SOURCE_REGION} --task-definition $task_name \
      --query 'taskDefinition' > "${BACKUP_DIR}/primary/$task_name.json"
  done
  echo "✅ Primary region task definitions backed up: $(echo $PRIMARY_TASK_DEFS | wc -w | xargs) definitions"
fi

# List and extract task definitions from DR region
echo -e "\n📋 Backing up task definitions from DR region (${DR_REGION})..."
DR_TASK_DEFS=$(aws ecs list-task-definitions --region ${DR_REGION} --family-prefix "${ENVIRONMENT}-dr-${APP_NAME}" --status ACTIVE --query 'taskDefinitionArns[*]' --output text)

if [ -z "$DR_TASK_DEFS" ]; then
  echo "No task definitions found in DR region matching ${ENVIRONMENT}-dr-${APP_NAME}"
else
  for task_def in $DR_TASK_DEFS; do
    task_name=$(echo $task_def | awk -F'/' '{print $NF}')
    echo "  - Extracting $task_name"
    aws ecs describe-task-definition --region ${DR_REGION} --task-definition $task_name \
      --query 'taskDefinition' > "${BACKUP_DIR}/dr/$task_name.json"
  done
  echo "✅ DR region task definitions backed up: $(echo $DR_TASK_DEFS | wc -w | xargs) definitions"
fi

# Create archive
echo -e "\n📦 Creating archive..."
tar -czf "${BACKUP_DIR}.tar.gz" -C "/tmp" "task-definitions-${TIMESTAMP}"

# Upload to S3
echo -e "\n☁️ Uploading to S3..."
aws s3 cp "${BACKUP_DIR}.tar.gz" "s3://${BACKUP_BUCKET}/${S3_PREFIX}/task-definitions-${TIMESTAMP}.tar.gz" --region ${SOURCE_REGION}

# Create a latest pointer
echo -e "\n📌 Creating 'latest' pointer..."
aws s3 cp "s3://${BACKUP_BUCKET}/${S3_PREFIX}/task-definitions-${TIMESTAMP}.tar.gz" \
  "s3://${BACKUP_BUCKET}/${S3_PREFIX}/latest/task-definitions-latest.tar.gz" \
  --region ${SOURCE_REGION}

# Cleanup
echo -e "\n🧹 Cleaning up temporary files..."
rm -rf "${BACKUP_DIR}" "${BACKUP_DIR}.tar.gz"

echo -e "\n✅ Task definition backup complete"
echo "Backup stored at: s3://${BACKUP_BUCKET}/${S3_PREFIX}/task-definitions-${TIMESTAMP}.tar.gz"
echo "Latest pointer: s3://${BACKUP_BUCKET}/${S3_PREFIX}/latest/task-definitions-latest.tar.gz"
