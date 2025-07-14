#!/bin/bash
set -e

# Get database credentials from AWS Secrets Manager
SECRETS=$(aws secretsmanager get-secret-value --secret-id dev-bmdb/database-credentials --query 'SecretString' --output text)

# Parse JSON to extract values
DB_HOST=$(echo $SECRETS | grep -o '"DATABASE_HOST":"[^"]*' | cut -d'"' -f4)
DB_NAME=$(echo $SECRETS | grep -o '"DATABASE_NAME":"[^"]*' | cut -d'"' -f4)
DB_USER=$(echo $SECRETS | grep -o '"DATABASE_USER":"[^"]*' | cut -d'"' -f4)
DB_PASSWORD=$(echo $SECRETS | grep -o '"DATABASE_PASSWORD":"[^"]*' | cut -d'"' -f4)

echo "Creating a modified version of seed.sql to use database $DB_NAME instead of 'media'"
sed "s/CREATE DATABASE IF NOT EXISTS \`media\`/CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`/g" seed.sql | sed "s/USE \`media\`/USE \`$DB_NAME\`/g" > seed_modified.sql

echo "Applying seed file to database $DB_NAME on $DB_HOST"
mysql -h $DB_HOST -u $DB_USER -p$DB_PASSWORD < seed_modified.sql

echo "Cleaning up temporary files"
rm seed_modified.sql

echo "Database seeding completed successfully!"
