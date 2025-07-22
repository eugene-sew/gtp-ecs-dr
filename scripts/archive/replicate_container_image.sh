#!/bin/bash
# Replicates container images from the source region to the DR region

# Default configuration
SOURCE_REGION=${SOURCE_REGION:-"eu-west-1"}
DR_REGION=${DR_REGION:-"eu-central-1"} 
ENVIRONMENT=${ENVIRONMENT:-"dev"}
APP_NAME=${APP_NAME:-"bmdb"}

# DR configuration
DR_ENV="${ENVIRONMENT}-dr"

# Account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)

echo "Container Image Replication"
echo "=========================="
echo "Configuration:"
echo "  Source Region: $SOURCE_REGION"
echo "  DR Region: $DR_REGION" 
echo "  Environment: $ENVIRONMENT"
echo "  DR Environment: $DR_ENV"
echo "  Application: $APP_NAME"
echo "=========================="

# Step 1: Find the current task definition image
echo "Finding current task definition image..."
TASK_DEF_ARN=$(aws ecs list-task-definitions --region $SOURCE_REGION --family-prefix $ENVIRONMENT-$APP_NAME --sort DESC --status ACTIVE --max-items 1 --query 'taskDefinitionArns[0]' --output text)

if [ -z "$TASK_DEF_ARN" ] || [ "$TASK_DEF_ARN" == "None" ]; then
  echo "Error: No active task definition found for $ENVIRONMENT-$APP_NAME in $SOURCE_REGION"
  exit 1
fi

echo "Found task definition: $TASK_DEF_ARN"

# Get the image from the task definition
SOURCE_IMAGE=$(aws ecs describe-task-definition --region $SOURCE_REGION --task-definition $TASK_DEF_ARN --query 'taskDefinition.containerDefinitions[0].image' --output text)

echo "Source image: $SOURCE_IMAGE"

if [ -z "$SOURCE_IMAGE" ]; then
  echo "Error: Could not extract image from task definition."
  exit 1
fi

# Parse the image URI components
SOURCE_REGISTRY=$(echo $SOURCE_IMAGE | cut -d'/' -f1)
SOURCE_REPO_PATH=$(echo $SOURCE_IMAGE | cut -d'/' -f2-)
SOURCE_REPO=$(echo $SOURCE_REPO_PATH | cut -d':' -f1)
IMAGE_TAG=$(echo $SOURCE_IMAGE | cut -d':' -f2)

if [ -z "$IMAGE_TAG" ]; then
  echo "Using 'latest' tag as fallback"
  IMAGE_TAG="latest"
fi

echo "Source registry: $SOURCE_REGISTRY"
echo "Source repository: $SOURCE_REPO"
echo "Image tag: $IMAGE_TAG"

# Compose source and target URIs
SOURCE_URI="$SOURCE_IMAGE"
TARGET_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${DR_REGION}.amazonaws.com"
TARGET_URI="${TARGET_REGISTRY}/${SOURCE_REPO}:${IMAGE_TAG}"

echo "Source URI: $SOURCE_URI"
echo "Target URI: $TARGET_URI"

# Step 2: Create the target repository in the DR region if it doesn't exist
echo "Creating repository in DR region if it doesn't exist..."

# Extract just the repository name without the full path
REPO_NAME=$(echo $SOURCE_REPO | sed 's|.*/||')
echo "Repository name for creation: $REPO_NAME"

# Try to describe the repository to check if it exists
REPO_EXISTS=$(aws ecr describe-repositories --repository-names $REPO_NAME --region $DR_REGION 2>&1 || true)
if [[ $REPO_EXISTS == *"RepositoryNotFoundException"* ]]; then
  echo "Creating repository $REPO_NAME in $DR_REGION..."
  aws ecr create-repository --repository-name $REPO_NAME --region $DR_REGION
else
  echo "Repository already exists in $DR_REGION."
fi

# Step 3: Login to both ECR registries
echo "Logging in to ECR registries..."
aws ecr get-login-password --region $SOURCE_REGION | docker login --username AWS --password-stdin $SOURCE_REGISTRY
aws ecr get-login-password --region $DR_REGION | docker login --username AWS --password-stdin $TARGET_REGISTRY

# Step 4: Pull the image from source region
echo "Pulling image from source region..."
docker pull $SOURCE_URI

# Step 5: Tag the image for the DR region
echo "Tagging image for DR region..."
docker tag $SOURCE_URI $TARGET_URI

# Step 6: Push the image to the DR region
echo "Pushing image to DR region..."
docker push $TARGET_URI

echo "Image replication complete."
echo "Source: $SOURCE_URI"
echo "Target: $TARGET_URI"
