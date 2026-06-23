#!/bin/bash
set -e

TUTORIAL_HOME=$(dirname "$BASH_SOURCE")

# All KMJs must be applied for controllers to form a quorum and migration to
# proceed. The operator's cluster-wide URP=0 check serializes broker restarts
# at the partition level — at most one replica of any given partition is
# offline at a time. Requires >= 2 brokers per region for zero downtime.

echo "=== Applying KRaftMigrationJob for all regions ==="
echo ""

echo "Applying KRaftMigrationJob for central region..."
kubectl apply -f "$TUTORIAL_HOME/confluent-platform/migrationjob/kraftmigrationjob-central.yaml" --context mrc-central

echo "Applying KRaftMigrationJob for east region..."
kubectl apply -f "$TUTORIAL_HOME/confluent-platform/migrationjob/kraftmigrationjob-east.yaml" --context mrc-east

echo "Applying KRaftMigrationJob for west region..."
kubectl apply -f "$TUTORIAL_HOME/confluent-platform/migrationjob/kraftmigrationjob-west.yaml" --context mrc-west

echo ""
echo "KRaftMigrationJob applied for all regions!"
echo ""
echo "All regions will progress through SETUP -> MIGRATE -> DUAL-WRITE."
echo "DUAL-WRITE is a cluster-wide state — the last region to finish its"
echo "broker rolls is the bottleneck for this transition."
echo ""
echo "To monitor migration progress:"
echo "  kubectl get kmj kraftmigrationjob-central -n central --context mrc-central -w -oyaml"
echo "  kubectl get kmj kraftmigrationjob-east -n east --context mrc-east -w -oyaml"
echo "  kubectl get kmj kraftmigrationjob-west -n west --context mrc-west -w -oyaml"
