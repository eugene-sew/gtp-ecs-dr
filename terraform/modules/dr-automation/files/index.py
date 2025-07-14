import boto3
import json
import os
import logging
from datetime import datetime

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Environment variables
SOURCE_REGION = os.environ.get('SOURCE_REGION', 'eu-west-1')
DR_REGION = os.environ.get('DR_REGION', 'eu-central-1')
ENVIRONMENT = os.environ.get('ENVIRONMENT', 'dev')
APP_NAME = os.environ.get('APP_NAME', 'bmdb')

# Derived values
CLUSTER_NAME = f"{ENVIRONMENT}-{APP_NAME}-cluster"
SERVICE_NAME = f"{ENVIRONMENT}-{APP_NAME}-service"
DR_CLUSTER_NAME = f"{ENVIRONMENT}-dr-{APP_NAME}-cluster"
DR_SERVICE_NAME = f"{ENVIRONMENT}-dr-{APP_NAME}-service"

def handler(event, context):
    """
    Lambda handler to synchronize ECS task definitions between regions
    """
    logger.info(f"Starting task definition sync from {SOURCE_REGION} to {DR_REGION}")
    logger.info(f"Environment: {ENVIRONMENT}, App: {APP_NAME}")
    
    try:
        # Get ECS clients for both regions
        source_ecs = boto3.client('ecs', region_name=SOURCE_REGION)
        dr_ecs = boto3.client('ecs', region_name=DR_REGION)
        
        # Step 1: Get current task definition from source region
        logger.info(f"Getting current task definition from {CLUSTER_NAME}/{SERVICE_NAME}")
        service_response = source_ecs.describe_services(
            cluster=CLUSTER_NAME,
            services=[SERVICE_NAME]
        )
        
        if not service_response['services']:
            logger.error(f"Service {SERVICE_NAME} not found in cluster {CLUSTER_NAME}")
            return {
                'statusCode': 404,
                'body': f"Service {SERVICE_NAME} not found"
            }
        
        task_def_arn = service_response['services'][0]['taskDefinition']
        logger.info(f"Found task definition: {task_def_arn}")
        
        # Step 2: Get task definition details
        task_def = source_ecs.describe_task_definition(
            taskDefinition=task_def_arn
        )['taskDefinition']
        
        # Step 3: Clean task definition by removing read-only fields
        clean_task_def = {
            'family': task_def['family'],
            'containerDefinitions': task_def['containerDefinitions'],
            'executionRoleArn': task_def.get('executionRoleArn', ''),
            'taskRoleArn': task_def.get('taskRoleArn', ''),
            'networkMode': task_def.get('networkMode', ''),
            'volumes': task_def.get('volumes', []),
            'placementConstraints': task_def.get('placementConstraints', []),
            'requiresCompatibilities': task_def.get('requiresCompatibilities', [])
        }
        
        # Add optional attributes only if they exist in the original task definition
        if 'cpu' in task_def:
            clean_task_def['cpu'] = task_def['cpu']
        if 'memory' in task_def:
            clean_task_def['memory'] = task_def['memory']
        
        # Step 4: Register task definition in DR region
        logger.info(f"Registering task definition in {DR_REGION}")
        dr_task_def_response = dr_ecs.register_task_definition(**clean_task_def)
        
        new_task_def_arn = dr_task_def_response['taskDefinition']['taskDefinitionArn']
        logger.info(f"Successfully registered task definition in DR region: {new_task_def_arn}")
        
        # Step 5: Check if DR service exists and update it
        try:
            dr_cluster_exists = False
            dr_service_exists = False
            
            # Check if DR cluster exists
            clusters = dr_ecs.list_clusters()
            for cluster_arn in clusters['clusterArns']:
                if DR_CLUSTER_NAME in cluster_arn:
                    dr_cluster_exists = True
                    break
            
            if not dr_cluster_exists:
                logger.info(f"Creating DR cluster: {DR_CLUSTER_NAME}")
                dr_ecs.create_cluster(clusterName=DR_CLUSTER_NAME)
                logger.info(f"Created DR cluster: {DR_CLUSTER_NAME}")
            
            # Check if DR service exists
            services = dr_ecs.list_services(cluster=DR_CLUSTER_NAME)
            for service_arn in services.get('serviceArns', []):
                if DR_SERVICE_NAME in service_arn:
                    dr_service_exists = True
                    break
            
            if dr_service_exists:
                logger.info(f"Updating DR service with new task definition")
                dr_ecs.update_service(
                    cluster=DR_CLUSTER_NAME,
                    service=DR_SERVICE_NAME,
                    taskDefinition=new_task_def_arn
                )
                logger.info(f"Updated DR service with task definition: {new_task_def_arn}")
            else:
                logger.info(f"DR service doesn't exist yet. Task definition is registered and ready.")
                
        except Exception as e:
            logger.warning(f"Could not update DR service: {str(e)}")
            logger.info("Task definition has been registered but service not updated")
        
        return {
            'statusCode': 200,
            'body': json.dumps({
                'message': 'Task definition sync completed successfully',
                'sourceTaskDefinition': task_def_arn,
                'drTaskDefinition': new_task_def_arn,
                'timestamp': datetime.now().isoformat()
            })
        }
        
    except Exception as e:
        logger.error(f"Error syncing task definitions: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({
                'message': f"Error syncing task definitions: {str(e)}",
                'timestamp': datetime.now().isoformat()
            })
        }
