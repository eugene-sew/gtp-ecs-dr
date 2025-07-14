# Disaster Recovery Implementation Plan

This document outlines the implementation plan for enhancing the disaster recovery capabilities of our ECS Fargate application with cross-region RDS MySQL replication.

## Table of Contents

1. [Phase 1: Monitoring & Detection](#phase-1-monitoring--detection-enhancements)
2. [Phase 2: DR Activation Enhancements](#phase-2-dr-activation-enhancements)
3. [Phase 3: Route 53 Health Checks](#phase-3-route-53-health-checks--automated-failover)
4. [Phase 4: Testing Framework](#phase-4-dr-testing-framework)

## Phase 1: Monitoring & Detection Enhancements

### 1.1 CloudWatch Alarms Implementation
**Deadline**: 2 weeks
**Resources Required**: AWS IAM permissions for CloudWatch

#### Tasks:
1. Create RDS replication lag alarm:
   ```bash
   aws cloudwatch put-metric-alarm \
     --alarm-name "RDS-ReplicationLag-Critical" \
     --alarm-description "Alarm when replication lag exceeds 300 seconds" \
     --metric-name "ReplicaLag" \
     --namespace "AWS/RDS" \
     --statistic "Average" \
     --dimensions Name=DBInstanceIdentifier,Value=${DR_REGION}-${ENVIRONMENT}-dr-${APP_NAME}-db \
     --period 60 \
     --evaluation-periods 5 \
     --threshold 300 \
     --comparison-operator GreaterThanThreshold \
     --alarm-actions "${SNS_TOPIC_ARN}" \
     --region ${DR_REGION}
   ```

2. Create ECS service health alarm:
   ```bash
   aws cloudwatch put-metric-alarm \
     --alarm-name "Primary-ECS-ServiceHealth" \
     --alarm-description "Alarm when primary service is unhealthy" \
     --metric-name "RunningTaskCount" \
     --namespace "AWS/ECS" \
     --statistic "Average" \
     --dimensions Name=ClusterName,Value=${ENVIRONMENT}-${APP_NAME}-cluster Name=ServiceName,Value=${ENVIRONMENT}-${APP_NAME}-service \
     --period 60 \
     --evaluation-periods 3 \
     --threshold ${MIN_HEALTHY_TASKS} \
     --comparison-operator LessThanThreshold \
     --alarm-actions "${SNS_TOPIC_ARN}" \
     --region ${SOURCE_REGION}
   ```

3. Create Application Load Balancer health alarm:
   ```bash
   aws cloudwatch put-metric-alarm \
     --alarm-name "Primary-ALB-5XX-Errors" \
     --alarm-description "Alarm when ALB returns too many 5XX errors" \
     --metric-name "HTTPCode_ELB_5XX_Count" \
     --namespace "AWS/ApplicationELB" \
     --statistic "Sum" \
     --dimensions Name=LoadBalancer,Value=${PRIMARY_ALB_NAME} \
     --period 60 \
     --evaluation-periods 3 \
     --threshold 10 \
     --comparison-operator GreaterThanThreshold \
     --alarm-actions "${SNS_TOPIC_ARN}" \
     --region ${SOURCE_REGION}
   ```

### 1.2 SNS Topic and Subscriptions
**Deadline**: 1 week
**Resources Required**: AWS IAM permissions for SNS

#### Tasks:
1. Create SNS topic in both regions:
   ```bash
   # Create SNS topic in primary region
   aws sns create-topic --name "${ENVIRONMENT}-${APP_NAME}-alerts" --region ${SOURCE_REGION}
   
   # Create SNS topic in DR region
   aws sns create-topic --name "${ENVIRONMENT}-${APP_NAME}-dr-alerts" --region ${DR_REGION}
   ```

2. Subscribe operations team emails:
   ```bash
   aws sns subscribe \
     --topic-arn "${PRIMARY_SNS_TOPIC_ARN}" \
     --protocol email \
     --notification-endpoint "ops-team@example.com" \
     --region ${SOURCE_REGION}
   ```

## Phase 2: DR Activation Enhancements

### 2.1 Database Validation Components
**Deadline**: 3 weeks
**Resources Required**: MySQL client tools, AWS IAM permissions for RDS

#### Tasks:
1. Add database validation function to DR activation script:
   ```bash
   function validate_database() {
     echo "Validating database health and data integrity..."
     
     # Get database credentials from Secrets Manager
     DB_CREDS=$(aws secretsmanager get-secret-value \
       --secret-id "${ENVIRONMENT}-dr-${APP_NAME}-db-credentials" \
       --query 'SecretString' --output text --region ${DR_REGION})
     
     DB_USER=$(echo $DB_CREDS | jq -r .username)
     DB_PASS=$(echo $DB_CREDS | jq -r .password)
     DB_HOST=$(echo $DB_CREDS | jq -r .host)
     
     # Create temporary MySQL config file with credentials
     cat > ~/.dr_my.cnf << EOF
   [client]
   user=${DB_USER}
   password=${DB_PASS}
   host=${DB_HOST}
   EOF
     chmod 600 ~/.dr_my.cnf
     
     # Check database connectivity
     if ! mysql --defaults-file=~/.dr_my.cnf -e "SELECT 1;" &>/dev/null; then
       echo "❌ ERROR: Cannot connect to database"
       rm ~/.dr_my.cnf
       return 1
     fi
     
     # Check for critical tables
     echo "Checking critical tables..."
     TABLE_COUNT=$(mysql --defaults-file=~/.dr_my.cnf -e "SELECT COUNT(TABLE_NAME) FROM information_schema.TABLES WHERE TABLE_SCHEMA NOT IN ('mysql','information_schema','performance_schema');" --skip-column-names)
     
     if [ "$TABLE_COUNT" -lt 5 ]; then
       echo "⚠️ WARNING: Found only $TABLE_COUNT tables. Database may not be fully replicated."
     else
       echo "✅ Found $TABLE_COUNT tables in database."
     fi
     
     # Clean up
     rm ~/.dr_my.cnf
     return 0
   }
   ```

2. Add data comparison logic:
   ```bash
   function compare_table_counts() {
     # Implementation for comparing record counts between primary and DR databases
     # [...]
   }
   ```

### 2.2 Enhanced ECS Service Health Verification
**Deadline**: 2 weeks
**Resources Required**: AWS IAM permissions for ECS, CloudWatch

#### Tasks:
1. Add enhanced ECS service health check:
   ```bash
   function verify_ecs_service_health() {
     echo "Verifying ECS service health in $1 region..."
     local region=$1
     local cluster_name="${ENVIRONMENT}-${APP_NAME}-cluster"
     local service_name="${ENVIRONMENT}-${APP_NAME}-service"
     
     if [ "$region" == "$DR_REGION" ]; then
       cluster_name="${ENVIRONMENT}-dr-${APP_NAME}-cluster"
       service_name="${ENVIRONMENT}-dr-${APP_NAME}-service"
     fi
     
     # Get service details
     local service_info=$(aws ecs describe-services \
       --cluster "$cluster_name" \
       --services "$service_name" \
       --region "$region")
     
     # Check deployment status
     local deployments=$(echo "$service_info" | jq -r '.services[0].deployments | length')
     if [ "$deployments" -gt 1 ]; then
       echo "⚠️ WARNING: Service has multiple active deployments."
     fi
     
     # Check running tasks
     local running_count=$(echo "$service_info" | jq -r '.services[0].runningCount')
     local desired_count=$(echo "$service_info" | jq -r '.services[0].desiredCount')
     
     if [ "$running_count" -lt "$desired_count" ]; then
       echo "⚠️ WARNING: Running tasks ($running_count) less than desired ($desired_count)."
       return 1
     else
       echo "✅ Service has $running_count/$desired_count tasks running."
       return 0
     fi
   }
   ```

## Phase 3: Route 53 Health Checks & Automated Failover

### 3.1 Route 53 Health Check Configuration
**Deadline**: 2 weeks
**Resources Required**: AWS IAM permissions for Route 53

#### Tasks:
1. Create health checks for primary and DR endpoints:
   ```bash
   # Primary region health check
   aws route53 create-health-check \
     --caller-reference "primary-$(date +%s)" \
     --health-check-config "{ \
       \"Port\": 443, \
       \"Type\": \"HTTPS\", \
       \"ResourcePath\": \"/health\", \
       \"FullyQualifiedDomainName\": \"${PRIMARY_ENDPOINT}\", \
       \"RequestInterval\": 30, \
       \"FailureThreshold\": 3 \
     }" \
     --region us-east-1
   
   # DR region health check
   aws route53 create-health-check \
     --caller-reference "dr-$(date +%s)" \
     --health-check-config "{ \
       \"Port\": 443, \
       \"Type\": \"HTTPS\", \
       \"ResourcePath\": \"/health\", \
       \"FullyQualifiedDomainName\": \"${DR_ENDPOINT}\", \
       \"RequestInterval\": 30, \
       \"FailureThreshold\": 3 \
     }" \
     --region us-east-1
   ```

2. Create Route 53 failover records:
   ```terraform
   resource "aws_route53_record" "primary" {
     zone_id = aws_route53_zone.main.zone_id
     name    = "${var.environment}-${var.app_name}"
     type    = "A"
     
     failover_routing_policy {
       type = "PRIMARY"
     }
     
     set_identifier = "primary"
     health_check_id = aws_route53_health_check.primary.id
     
     alias {
       name                   = var.primary_alb_dns_name
       zone_id                = var.primary_alb_zone_id
       evaluate_target_health = true
     }
   }
   
   resource "aws_route53_record" "secondary" {
     zone_id = aws_route53_zone.main.zone_id
     name    = "${var.environment}-${var.app_name}"
     type    = "A"
     
     failover_routing_policy {
       type = "SECONDARY"
     }
     
     set_identifier = "dr"
     health_check_id = aws_route53_health_check.dr.id
     
     alias {
       name                   = var.dr_alb_dns_name
       zone_id                = var.dr_alb_zone_id
       evaluate_target_health = true
     }
   }
   ```

## Phase 4: DR Testing Framework

### 4.1 DR Test Script Development
**Deadline**: 3 weeks
**Resources Required**: Access to test environment

#### Tasks:
1. Create DR testing framework script:
   ```bash
   #!/bin/bash
   # dr-test.sh - Comprehensive DR testing framework
   
   set -e
   
   # Configuration
   SOURCE_REGION=${SOURCE_REGION:-"eu-west-1"}
   DR_REGION=${DR_REGION:-"eu-central-1"}
   ENVIRONMENT=${ENVIRONMENT:-"dev"}
   APP_NAME=${APP_NAME:-"bmdb"}
   TEST_TYPE=${TEST_TYPE:-"full"} # Options: full, readiness, failover, failback
   
   # Import common functions
   source $(dirname "$0")/common-functions.sh
   
   # Start testing
   print_header "DISASTER RECOVERY TEST: $TEST_TYPE"
   record_metric "DR_TEST_START" "$(date)"
   
   # 1. Check DR readiness
   print_header "STEP 1: Checking DR readiness"
   
   # Check RDS replication lag
   replication_lag=$(aws cloudwatch get-metric-statistics \
     --namespace AWS/RDS \
     --metric-name ReplicaLag \
     --dimensions "Name=DBInstanceIdentifier,Value=${ENVIRONMENT}-dr-${APP_NAME}-db" \
     --start-time "$(date -u -d '5 minutes ago' '+%Y-%m-%dT%H:%M:%S')" \
     --end-time "$(date -u '+%Y-%m-%dT%H:%M:%S')" \
     --period 60 \
     --statistics Average \
     --region ${DR_REGION} \
     --query 'Datapoints[0].Average' \
     --output text)
   
   if [ "$replication_lag" == "None" ]; then
     echo "❌ ERROR: Could not retrieve replication lag metrics"
   elif [ "$(echo "$replication_lag > 300" | bc -l)" == 1 ]; then
     echo "❌ ERROR: Replication lag is too high: $replication_lag seconds"
   else
     echo "✅ Replication lag is within acceptable range: $replication_lag seconds"
   fi
   
   # 2. Test DR activation (if full test)
   if [ "$TEST_TYPE" == "full" ] || [ "$TEST_TYPE" == "failover" ]; then
     print_header "STEP 2: Testing DR activation"
     confirm "Ready to test failover to DR region?"
     
     # Call DR activation script with test mode
     TEST_MODE=true ./dr-activate.sh
     
     # Validate DR functionality
     verify_ecs_service_health "$DR_REGION"
     validate_database
   fi
   
   # 3. Verify application functionality in DR
   print_header "STEP 3: Verifying application functionality"
   
   # Implement application-specific health checks here
   # ...
   
   record_metric "DR_FUNCTIONALITY_VERIFIED" "$(date)"
   
   # 4. Perform failback
   if [ "$TEST_TYPE" == "full" ] || [ "$TEST_TYPE" == "failback" ]; then
     print_header "STEP 4: Performing failback to primary region"
     confirm "Ready to failback to primary region?"
     
     # Call DR deactivation script with test mode
     TEST_MODE=true ./dr-deactivate.sh
     
     # Verify primary functionality
     verify_ecs_service_health "$SOURCE_REGION"
   fi
   
   print_header "DR TEST COMPLETE"
   record_metric "DR_TEST_END" "$(date)"
   echo "✅ DR test completed successfully: $(date)"
   ```

### 4.2 DR Test Schedule
**Deadline**: 1 week
**Resources Required**: Access to operations calendar

#### Tasks:
1. Define quarterly DR testing schedule
2. Create DR test runbook
3. Integrate DR testing with application deployment pipeline
