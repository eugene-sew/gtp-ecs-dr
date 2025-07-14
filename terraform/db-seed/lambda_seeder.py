import boto3
import os
import json
import mysql.connector

def lambda_handler(event, context):
    # Get secrets from Secrets Manager
    secret_name = "dev-bmdb/database-credentials"
    secrets_client = boto3.client('secretsmanager')
    secret_response = secrets_client.get_secret_value(SecretId=secret_name)
    secret = json.loads(secret_response['SecretString'])
    
    # Parse credentials
    db_host = secret['DATABASE_HOST']
    db_name = secret['DATABASE_NAME']
    db_user = secret['DATABASE_USER']
    db_password = secret['DATABASE_PASSWORD']
    
    # Get seed SQL from S3
    s3_client = boto3.client('s3')
    bucket_name = 'dev-bmdb-seed-files'
    seed_key = 'seed.sql'
    
    response = s3_client.get_object(Bucket=bucket_name, Key=seed_key)
    seed_content = response['Body'].read().decode('utf-8')
    
    # Replace database name in the seed file
    seed_content = seed_content.replace('CREATE DATABASE IF NOT EXISTS `media`', 
                                     f'CREATE DATABASE IF NOT EXISTS `{db_name}`')
    seed_content = seed_content.replace('USE `media`', f'USE `{db_name}`')
    
    # Connect to the database
    try:
        conn = mysql.connector.connect(
            host=db_host,
            user=db_user,
            password=db_password,
            charset='utf8mb4'
        )
        
        # Split into statements and execute
        cursor = conn.cursor()
        # First ensure we're using the right database
        cursor.execute(f"USE `{db_name}`")
        
        # Split into statements and execute one by one
        statements = seed_content.split(';')
        for statement in statements:
            if statement.strip():
                try:
                    cursor.execute(statement.strip())
                    conn.commit()
                except mysql.connector.Error as err:
                    print(f"Error executing statement: {err}")
                    # Continue with other statements even if one fails
                    # Alternatively, you could raise the exception to fail the entire process
                    pass
            
        return {
            'statusCode': 200,
            'body': json.dumps('Database seeded successfully')
        }
    except Exception as e:
        return {
            'statusCode': 500,
            'body': json.dumps(f'Error: {str(e)}')
        }
    finally:
        if 'conn' in locals() and conn is not None:
            conn.close()
