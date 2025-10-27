#!/bin/bash
set -e

TUTORIAL_HOME=$(dirname "$BASH_SOURCE")

echo "Applying KRaftMigrationJob for all regions..."

# Apply migration jobs for each region
echo "Applying KRaftMigrationJob for central region..."
kubectl apply -f "$TUTORIAL_HOME/confluent-platform/migrationjob/kraftmigrationjob-central.yaml" --context mrc-central

echo "Applying KRaftMigrationJob for east region..."
kubectl apply -f "$TUTORIAL_HOME/confluent-platform/migrationjob/kraftmigrationjob-east.yaml" --context mrc-east

echo "Applying KRaftMigrationJob for west region..."
kubectl apply -f "$TUTORIAL_HOME/confluent-platform/migrationjob/kraftmigrationjob-west.yaml" --context mrc-west

echo "KRaftMigrationJob applied successfully for all regions!"
echo ""
echo "To check status:"
echo "kubectl get kmj kraftmigrationjob-central -n central --context mrc-central"
echo "kubectl get kmj kraftmigrationjob-east -n east --context mrc-east"
echo "kubectl get kmj kraftmigrationjob-west -n west --context mrc-west"
echo ""
echo "To monitor migration progress:"
echo "kubectl get kmj kraftmigrationjob-central -n central --context mrc-central -w -oyaml"
echo "kubectl get kmj kraftmigrationjob-east -n east --context mrc-east -w -oyaml"
echo "kubectl get kmj kraftmigrationjob-west -n west --context mrc-west -w -oyaml"
