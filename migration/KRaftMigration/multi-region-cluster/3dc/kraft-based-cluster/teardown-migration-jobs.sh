#!/bin/bash
set -e

TUTORIAL_HOME=$(dirname "$BASH_SOURCE")

echo "Removing KRaftMigrationJob for all regions..."

# Remove migration jobs for each region
echo "Removing KRaftMigrationJob for central region..."
kubectl delete -f "$TUTORIAL_HOME/confluent-platform/migrationjob/kraftmigrationjob-central.yaml" --context mrc-central 2>/dev/null || echo "KRaftMigrationJob central not found, skipping..."

echo "Removing KRaftMigrationJob for east region..."
kubectl delete -f "$TUTORIAL_HOME/confluent-platform/migrationjob/kraftmigrationjob-east.yaml" --context mrc-east 2>/dev/null || echo "KRaftMigrationJob east not found, skipping..."

echo "Removing KRaftMigrationJob for west region..."
kubectl delete -f "$TUTORIAL_HOME/confluent-platform/migrationjob/kraftmigrationjob-west.yaml" --context mrc-west 2>/dev/null || echo "KRaftMigrationJob west not found, skipping..."

echo "KRaftMigrationJob cleanup completed for all regions!"