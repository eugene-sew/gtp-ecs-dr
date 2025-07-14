# AWS ECS Fargate Disaster Recovery Architecture

This document details the Disaster Recovery (DR) architecture and procedures for the AWS ECS Fargate infrastructure.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Infrastructure Components](#infrastructure-components)
3. [DR Activation Process](#dr-activation-process)
4. [DR Deactivation Process](#dr-deactivation-process)
5. [Testing Procedures](#testing-procedures)

## Architecture Overview

The Disaster Recovery solution uses a **module-based approach** to create a standby environment in a secondary AWS region (`eu-central-1`). The primary infrastructure is deployed in the main region (`eu-west-1`), and the DR infrastructure is conditionally deployed using the `enable_dr` flag.

### Key Features

- **Cross-Region Replication**: MySQL 8.0 database replication between regions
- **Modular Design**: Reusable Terraform modules for DR components
- **Controlled Failover**: Scripts for automated and manual failover procedures
- **Cost Optimization**: ECS services start with 0 tasks in the DR region until needed

## Infrastructure Components

### 1. DR Module (`terraform/modules/dr/main.tf`)
- Creates VPC, subnets, ECS cluster, and optionally RDS in DR region
- Starts with 0 ECS tasks to minimize costs
- Includes scheduled scaling for business hours
- References the same Docker images as the primary region

### 2. Cross-Region RDS Read Replica
- Created via Terraform (modules/dr/rds_replica.tf)
- Encrypted with DR region KMS key
- Monitored for replication lag
- Can be promoted to standalone DB during failover

### 3. Provider Configuration (`terraform/main.tf`)
- Uses AWS provider aliases for multi-region deployment
- Primary region: Default provider
- DR region: `aws.dr` provider

### 4. Conditional Deployment
- DR infrastructure is only created when `enable_dr = true`
- All DR resources are tagged with `-dr` suffix

## DR Activation Process

When a disaster occurs in the primary region, follow these steps to activate the DR environment:

### Step 1: Preparation

```bash
# Set environment variables
export SOURCE_REGION=eu-west-1
export DR_REGION=eu-central-1
export ENVIRONMENT=dev
export APP_NAME=bmdb
export DESIRED_COUNT=2  # Number of tasks to run in DR

# Run DR activation script
./scripts/dr-activate.sh
```

This script will:

1. Scale up your ECS service in the DR region to the specified task count
2. Verify infrastructure and IAM roles are properly set up
3. Provide DNS update instructions for routing traffic
4. Optionally promote the RDS read replica to a standalone database

### Step 2: Promote the Database (if needed)

If you need to promote the read replica to a standalone database:

```bash
PROMOTE_DB=true ./scripts/dr-activate.sh
```

This will:

1. Promote the read replica to a standalone database
2. Update the Secrets Manager secret with the new database endpoint
3. Restart ECS tasks to pick up the new database endpoint

### Step 3: Verify DR Environment

After activation, verify the DR environment is functioning correctly:

```bash
# Check ECS service status
aws ecs describe-services --cluster ${ENVIRONMENT}-dr-${APP_NAME}-cluster --services ${ENVIRONMENT}-dr-${APP_NAME}-service --region ${DR_REGION}

# Test the application endpoint
curl -v https://${ENVIRONMENT}-dr-${APP_NAME}.your-domain.com/health
```

## DR Deactivation Process

When the primary region is available again, follow these steps to deactivate DR:

### Step 1: Verify Primary Region Availability

Ensure all services in the primary region are operational:

```bash
# Check primary region ECS service status
aws ecs describe-services --cluster ${ENVIRONMENT}-${APP_NAME}-cluster --services ${ENVIRONMENT}-${APP_NAME}-service --region ${SOURCE_REGION}

# Check primary region RDS status
aws rds describe-db-instances --db-instance-identifier ${ENVIRONMENT}-${APP_NAME}-db --region ${SOURCE_REGION} --query 'DBInstances[0].DBInstanceStatus'
```

### Step 2: Run DR Deactivation Script

```bash
# Set environment variables
export SOURCE_REGION=eu-west-1
export DR_REGION=eu-central-1
export ENVIRONMENT=dev
export APP_NAME=bmdb
export PRIMARY_DESIRED_COUNT=2
export SYNC_DATA=true
export RECREATE_REPLICA=true

# Run DR deactivation script
./scripts/dr-deactivate.sh
```

This will:

1. Scale up your primary region services
2. Provide DNS failback instructions
3. After the primary region is ready, scale down the DR region to zero tasks
4. Synchronize data from DR back to primary if needed
5. Recreate the cross-region read replica

### Important Note on Read Replica Recreation

**CRITICAL**: After a read replica has been promoted to a standalone database, AWS RDS does not support converting it back to a read replica. The `dr-deactivate.sh` script includes logic to recreate the cross-region read replica using Terraform.

By default, `RECREATE_REPLICA=true` to ensure the read replica is always recreated, which is required for the DR environment to be ready for future failover events.
