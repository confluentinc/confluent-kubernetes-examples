#!/usr/bin/env bash
# RBAC role bindings for Replicator SMT Avro demo (no Kafka ACLs).
# Requires: SA_SRC, SA_DST, SA_WORKER
set -euo pipefail

ENV="${ENV:-env-26m77m}"
SRC="${SRC_CLUSTER:-lkc-0x90x6p}"
DST="${DST_CLUSTER:-lkc-57wk738}"
SR="${SR_CLUSTER:-lsrc-81wn160}"
GROUP="${CONNECTOR_GROUP:-replicator-smt-rbac}"

: "${SA_WORKER:?set SA_WORKER}"
: "${SA_SRC:?set SA_SRC}"
: "${SA_DST:?set SA_DST}"

bind() {
  echo "  $*"
  # Idempotent: create returns the binding JSON if new or already present.
  if ! out=$(confluent iam rbac role-binding create "$@" -o json 2>&1); then
    echo "ERROR creating binding: $out" >&2
    return 1
  fi
  echo "$out" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("   ->", d.get("role"), d.get("resource_type"), d.get("name"), d.get("pattern_type"))' 2>/dev/null || echo "   -> ok"
}

echo "=== SOURCE SA ${SA_SRC} on ${SRC} ==="
# Read/write/manage source demo.* topics (CFK create + produce + Replicator consume)
bind --principal "User:${SA_SRC}" --role ResourceOwner --environment "$ENV" \
  --cloud-cluster "$SRC" --kafka-cluster "$SRC" --resource Topic:demo --prefix
# Replicator consumer group
bind --principal "User:${SA_SRC}" --role DeveloperRead --environment "$ENV" \
  --cloud-cluster "$SRC" --kafka-cluster "$SRC" --resource "Group:${GROUP}"
# Provenance / timestamps topic on source (if enabled)
bind --principal "User:${SA_SRC}" --role ResourceOwner --environment "$ENV" \
  --cloud-cluster "$SRC" --kafka-cluster "$SRC" --resource Topic:__consumer_timestamps
# Schema Registry — produce/consume Avro under demo* subjects
bind --principal "User:${SA_SRC}" --role ResourceOwner --environment "$ENV" \
  --schema-registry-cluster "$SR" --resource "Subject:demo" --prefix

echo "=== DEST connector SA ${SA_DST} on ${DST} ==="
# Cluster admin on dest for dest.kafka / topic create / license topic (RBAC, no ACLs)
bind --principal "User:${SA_DST}" --role CloudClusterAdmin --environment "$ENV" \
  --cloud-cluster "$DST"
# SR for source + dest subject names
bind --principal "User:${SA_DST}" --role ResourceOwner --environment "$ENV" \
  --schema-registry-cluster "$SR" --resource "Subject:demo" --prefix
bind --principal "User:${SA_DST}" --role ResourceOwner --environment "$ENV" \
  --schema-registry-cluster "$SR" --resource "Subject:cloud" --prefix

echo "=== WORKER SA ${SA_WORKER} on ${DST} ==="
# Connect storage + produce post-SMT cloud.* topics
bind --principal "User:${SA_WORKER}" --role CloudClusterAdmin --environment "$ENV" \
  --cloud-cluster "$DST"
bind --principal "User:${SA_WORKER}" --role ResourceOwner --environment "$ENV" \
  --schema-registry-cluster "$SR" --resource "Subject:demo" --prefix
bind --principal "User:${SA_WORKER}" --role ResourceOwner --environment "$ENV" \
  --schema-registry-cluster "$SR" --resource "Subject:cloud" --prefix

echo "Done RBAC bindings."
