# ECS Fargate Scripts Documentation

This document details the utility scripts used for managing the ECS Fargate application with disaster recovery capabilities.

## Table of Contents

1. [DR Activation Script](#dr-activation-script)
2. [DR Deactivation Script](#dr-deactivation-script)
3. [Backup Task Definitions Script](#backup-task-definitions-script)
4. [RDS Snapshot Management Script](#rds-snapshot-management-script)
5. [Environment Variables Reference](#environment-variables-reference)

## DR Activation Script

The `dr-activate.sh` script activates the disaster recovery environment by scaling up ECS services in the DR region and optionally promoting the RDS read replica.

### Usage

```bash
# Basic usage (scale up ECS service in DR region)
./scripts/dr-activate.sh

# Promote read replica to standalone database
PROMOTE_DB=true ./scripts/dr-activate.sh
```

### Key Features

- Validates DR infrastructure before activation
- Scales up ECS services in DR region
- Promotes RDS read replica to standalone database (optional)
- Updates AWS Secrets Manager with new database endpoint
- Monitors service health during activation process

### Environment Variables

- `SOURCE_REGION`: Primary AWS region (default: eu-west-1)
- `DR_REGION`: DR AWS region (default: eu-central-1)
- `ENVIRONMENT`: Environment name (default: dev)
- `APP_NAME`: Application name (default: bmdb)
- `DESIRED_COUNT`: Number of ECS tasks to run in DR (default: 1)
- `PROMOTE_DB`: Whether to promote the read replica (default: false)
- `DNS_TTL`: TTL for DNS record changes in seconds (default: 60)

## DR Deactivation Script

The `dr-deactivate.sh` script deactivates the disaster recovery environment by scaling down ECS services in the DR region and recreating the cross-region read replica.

### Usage

```bash
# Basic usage
./scripts/dr-deactivate.sh

# Specify configuration options
SOURCE_REGION=eu-west-1 DR_REGION=eu-central-1 ENVIRONMENT=dev APP_NAME=bmdb ./scripts/dr-deactivate.sh

# Skip database synchronization
SYNC_DATA=false ./scripts/dr-deactivate.sh
```

### Key Features

- Validates primary infrastructure before failback
- Scales up ECS services in primary region
- Synchronizes database data from DR to primary (optional)
- Scales down DR ECS services
- Recreates cross-region read replica using Terraform

### Environment Variables

- `SOURCE_REGION`: Primary AWS region (default: eu-west-1)
- `DR_REGION`: DR AWS region (default: eu-central-1)
- `ENVIRONMENT`: Environment name (default: dev)
- `APP_NAME`: Application name (default: bmdb)
- `PRIMARY_DESIRED_COUNT`: Number of ECS tasks to run in primary (default: 1)
- `SYNC_DATA`: Whether to synchronize database data (default: false)
- `SYNC_METHOD`: Method for data synchronization (default: dump)
- `RECREATE_REPLICA`: Whether to recreate read replica (default: true)
- `TERRAFORM_DIR`: Path to Terraform environment directory (default: ./terraform/environments/dev)
- `DNS_TTL`: TTL for DNS record changes in seconds (default: 60)

### Important Note on Read Replica Recreation

**CRITICAL**: After a read replica has been promoted to a standalone database, AWS RDS does not support converting it back to a read replica. The `dr-deactivate.sh` script includes logic to recreate the cross-region read replica using Terraform.

By default, `RECREATE_REPLICA=true` to ensure the read replica is always recreated, which is required for the DR environment to be ready for future failover events.

## Backup Task Definitions Script

The `backup-task-definitions.sh` script backs up ECS task definitions from both primary and DR regions to S3.

### Usage

```bash
# Basic usage
./scripts/backup-task-definitions.sh

# With custom configuration
SOURCE_REGION=eu-west-1 DR_REGION=eu-central-1 ENVIRONMENT=dev APP_NAME=bmdb ./scripts/backup-task-definitions.sh
```

### Key Features

- Extracts task definitions from both regions
- Archives them with timestamps
- Stores in versioned S3 bucket
- Maintains a "latest" pointer for easy access
- Configurable retention policy

### Environment Variables

- `SOURCE_REGION`: Primary AWS region (default: eu-west-1)
- `DR_REGION`: DR AWS region (default: eu-central-1)
- `ENVIRONMENT`: Environment name (default: dev)
- `APP_NAME`: Application name (default: bmdb)
- `BACKUP_BUCKET`: S3 bucket name (default: {APP_NAME}-{ENVIRONMENT}-backups)

## RDS Snapshot Management Script

The `manage-rds-snapshots.sh` script creates and manages RDS snapshots with cross-region replication for disaster recovery.

### Usage

```bash
# Basic usage
./scripts/manage-rds-snapshots.sh

# With custom configuration
SOURCE_REGION=eu-west-1 DR_REGION=eu-central-1 ENVIRONMENT=dev APP_NAME=bmdb RETENTION_DAYS=14 ./scripts/manage-rds-snapshots.sh
```

### Key Features

- Creates manual RDS snapshots in the primary region
- Copies snapshots to the DR region with proper encryption
- Manages snapshot retention by removing older snapshots
- Supports encrypted MySQL 8.0 databases

### Environment Variables

- `SOURCE_REGION`: Primary AWS region (default: eu-west-1)
- `DR_REGION`: DR AWS region (default: eu-central-1)
- `ENVIRONMENT`: Environment name (default: dev)
- `APP_NAME`: Application name (default: bmdb)
- `RETENTION_DAYS`: Days to keep snapshots (default: 7)
- `CROSS_REGION_COPY`: Whether to copy to DR region (default: true)

## Environment Variables Reference

The following table summarizes all environment variables used across the scripts:

| Variable | Description | Default | Used In |
|----------|-------------|---------|---------|
| `SOURCE_REGION` | Primary AWS region | eu-west-1 | All scripts |
| `DR_REGION` | DR AWS region | eu-central-1 | All scripts |
| `ENVIRONMENT` | Environment name | dev | All scripts |
| `APP_NAME` | Application name | bmdb | All scripts |
| `DESIRED_COUNT` | Number of ECS tasks in DR | 1 | dr-activate.sh |
| `PRIMARY_DESIRED_COUNT` | Number of ECS tasks in primary | 1 | dr-deactivate.sh |
| `PROMOTE_DB` | Whether to promote read replica | false | dr-activate.sh |
| `SYNC_DATA` | Whether to synchronize database data | false | dr-deactivate.sh |
| `SYNC_METHOD` | Method for data synchronization | dump | dr-deactivate.sh |
| `RECREATE_REPLICA` | Whether to recreate read replica | true | dr-deactivate.sh |
| `TERRAFORM_DIR` | Path to Terraform environment directory | ./terraform/environments/dev | dr-deactivate.sh |
| `DNS_TTL` | TTL for DNS record changes | 60 | dr-activate.sh, dr-deactivate.sh |
| `RETENTION_DAYS` | Days to keep snapshots | 7 | manage-rds-snapshots.sh |
| `CROSS_REGION_COPY` | Whether to copy snapshots to DR | true | manage-rds-snapshots.sh |
| `BACKUP_BUCKET` | S3 bucket for backups | {APP_NAME}-{ENVIRONMENT}-backups | backup-task-definitions.sh |
