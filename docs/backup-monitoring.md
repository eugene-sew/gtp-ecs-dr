# ECS Fargate Backup & Monitoring Documentation

This document describes the backup and monitoring components implemented for the ECS Fargate application with cross-region disaster recovery.

## Table of Contents

1. [Task Definition Backup](#task-definition-backup)
2. [RDS Snapshot Management](#rds-snapshot-management)
3. [CloudWatch Monitoring](#cloudwatch-monitoring)
4. [Schedule Configuration](#schedule-configuration)
5. [Alert Notifications](#alert-notifications)

## Task Definition Backup

The `backup-task-definitions.sh` script automatically backs up all ECS task definitions from both primary and DR regions to an S3 bucket with versioning enabled.

### Features

- Extracts task definitions from primary and DR regions
- Archives them with timestamps
- Stores in versioned S3 bucket
- Maintains a "latest" pointer for easy access
- Configurable retention policy (default: 90 days)

### Usage

```bash
# Manual execution
./scripts/backup-task-definitions.sh

# With custom configuration
SOURCE_REGION=eu-west-1 DR_REGION=eu-central-1 ENVIRONMENT=dev APP_NAME=bmdb ./scripts/backup-task-definitions.sh
```

### Automatic Execution

The script is configured to run automatically every day at 1:00 AM UTC via CloudWatch Events/EventBridge.

## RDS Snapshot Management

The `manage-rds-snapshots.sh` script creates and manages RDS snapshots with cross-region replication for disaster recovery.

### Features

- Creates manual RDS snapshots in the primary region
- Copies snapshots to the DR region with proper encryption
- Manages snapshot retention by removing older snapshots
- Supports encrypted MySQL 8.0 databases

### Usage

```bash
# Manual execution
./scripts/manage-rds-snapshots.sh

# With custom configuration
SOURCE_REGION=eu-west-1 DR_REGION=eu-central-1 ENVIRONMENT=dev APP_NAME=bmdb RETENTION_DAYS=14 ./scripts/manage-rds-snapshots.sh
```

### Environment Variables

- `SOURCE_REGION`: Primary AWS region (default: eu-west-1)
- `DR_REGION`: DR AWS region (default: eu-central-1)
- `ENVIRONMENT`: Environment name (default: dev)
- `APP_NAME`: Application name (default: bmdb)
- `RETENTION_DAYS`: Days to keep snapshots (default: 7)
- `CROSS_REGION_COPY`: Whether to copy to DR region (default: true)

## CloudWatch Monitoring

The monitoring module (`terraform/modules/monitoring`) sets up comprehensive CloudWatch dashboards and alarms for both primary and DR regions.

### Monitored Components

#### Primary Region
- ECS service health (running tasks, CPU, memory)
- RDS database performance (CPU, storage, connections)
- Application Load Balancer metrics (2XX, 5XX, response time)

#### DR Region
- RDS replication lag (critical for DR readiness)
- Cross-region read replica health
- DR ECS service status
- DR ALB health checks

### Key Alarms

1. **Replication Lag Alarm**
   - Triggers when lag exceeds 5 minutes
   - Critical for DR readiness

2. **ECS Service Health**
   - Monitors running task count
   - Ensures minimum healthy tasks

3. **RDS Storage Space**
   - Alerts when storage space is low
   - Prevents database outages

4. **ALB 5XX Errors**
   - Detects application errors
   - Indicates service health issues

### Integration

The monitoring infrastructure integrates with both the task definition backup and RDS snapshot scripts:

- CloudWatch Events trigger scheduled backups
- Alarms can trigger SNS notifications
- Dashboard provides comprehensive view of DR readiness

## Schedule Configuration

| Component | Default Schedule | Configuration |
|-----------|-----------------|---------------|
| Task Definition Backup | Daily at 1:00 AM UTC | CloudWatch Events rule |
| RDS Snapshot | Daily at 2:00 AM UTC | CloudWatch Events rule |
| CloudWatch Dashboards | Real-time, 5-min intervals | Terraform module |

## Alert Notifications

Alerts are sent via SNS topics which can be configured to deliver to:

- Email
- SMS
- Lambda functions
- SQS queues
- HTTP endpoints

To configure alert recipients:

1. Subscribe to the SNS topic `{environment}-{app_name}-alerts`
2. Or update the Terraform configuration with your preferred delivery method

## Implementation Notes

- Backup S3 buckets use versioning and lifecycle policies
- RDS snapshots are encrypted using the same KMS keys as the source database
- CloudWatch dashboards include annotations for critical thresholds
- All components honor environment variables for configuration
