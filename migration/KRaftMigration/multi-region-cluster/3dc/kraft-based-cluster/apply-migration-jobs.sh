#!/bin/bash
set -e

TUTORIAL_HOME=$(dirname "$BASH_SOURCE")

# MRC migration sequencing: apply one region at a time and wait for each
# region's broker rolls to complete before proceeding to the next.
# Triggering multiple regions simultaneously can cause brokers holding
# replicas of the same partition to restart at the same time.

echo "=== Applying KRaftMigrationJob one region at a time ==="
echo ""

# Region 1: Central
echo "Applying KRaftMigrationJob for central region..."
kubectl apply -f "$TUTORIAL_HOME/confluent-platform/migrationjob/kraftmigrationjob-central.yaml" --context mrc-central
echo ""
echo "Waiting for central region to reach MIGRATE phase (subphase: MigrateMonitorMigrationProgress)..."
echo "Monitor with: kubectl get kmj kraftmigrationjob-central -n central --context mrc-central -w -oyaml"
echo ""
read -p "Press Enter once central region has reached MIGRATE/MigrateMonitorMigrationProgress..."

# Region 2: East
echo ""
echo "Applying KRaftMigrationJob for east region..."
kubectl apply -f "$TUTORIAL_HOME/confluent-platform/migrationjob/kraftmigrationjob-east.yaml" --context mrc-east
echo ""
echo "Waiting for east region to reach MIGRATE phase (subphase: MigrateMonitorMigrationProgress)..."
echo "Monitor with: kubectl get kmj kraftmigrationjob-east -n east --context mrc-east -w -oyaml"
echo ""
read -p "Press Enter once east region has reached MIGRATE/MigrateMonitorMigrationProgress..."

# Region 3: West
echo ""
echo "Applying KRaftMigrationJob for west region..."
kubectl apply -f "$TUTORIAL_HOME/confluent-platform/migrationjob/kraftmigrationjob-west.yaml" --context mrc-west
echo ""

echo "KRaftMigrationJob applied for all regions!"
echo ""
echo "Once the last region completes its broker rolls, all regions will transition to DUAL-WRITE."
echo ""
echo "To monitor migration progress:"
echo "  kubectl get kmj kraftmigrationjob-central -n central --context mrc-central -w -oyaml"
echo "  kubectl get kmj kraftmigrationjob-east -n east --context mrc-east -w -oyaml"
echo "  kubectl get kmj kraftmigrationjob-west -n west --context mrc-west -w -oyaml"
