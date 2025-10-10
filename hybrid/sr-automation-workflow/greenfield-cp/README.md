# Schema Registry Greenfield CP Workflow

This playbook demonstrates how to integrate a new Confluent Platform (CP) with an existing Confluent Cloud (CC) Schema Registry using Confluent for Kubernetes (CFK). 
The workflow establishes a greenfield CP deployment that automatically imports schemas from Confluent Cloud and enables forward mode at CP for seamless hybrid operations.

## What This Workflow Does

This greenfield workflow:
1. **Deploys a Confluent Platform** with KRaft controllers, Kafka, and Schema Registry in Kubernetes
2. **Configures Unified Stream Manager (USM)** to enable forwarder capabilities to existing CC Schema Registry
3. **Sets up automated schema import** from Confluent Cloud to the new CP installation
4. **Enables forward mode** using automation workflow without requiring an exporter

## Greenfield Architecture

This example demonstrates a greenfield CP deployment pattern:

### Key Characteristics
- **No existing CP schemas**: Fresh installation with empty schema registry
- **No exporter needed**: Uses `enableForwardWriteMode: true` to trigger automation
- **Import-only operation**: Only SchemaImporter is deployed, no SchemaExporter
- **Forward mode**: All write operations are forwarded to Confluent Cloud

## Components

- **KRaftController**: Manages Kafka metadata without requiring Zookeeper
- **Kafka Cluster**: Confluent Platform Kafka cluster with 3 replicas
- **Schema Registry**: CP schema registry with USM forwarder and importer extensions enabled
- **SchemaImporter**: Imports all schemas from CC to CP with forward write mode automation
- **Unified Stream Manager**: Enables forwarder mode for seamless schema registry integration

## Table of Contents
- [Prerequisites](#prerequisites)
- [Basic Setup](#basic-setup)
- [Confluent Platform Deployment](#confluent-platform-deployment)
- [Greenfield Schema Import Configuration](#greenfield-schema-import-configuration)
- [Verification](#verification)
- [Schema Registry Modes](#schema-registry-modes)

## Prerequisites

- Kubernetes cluster with CFK installed
- Access to existing Confluent Cloud with Schema Registry containing schemas
- `kubectl` configured to access your cluster
- Confluent Cloud API credentials for schema registry access

## Basic Setup

- Set the tutorial directory for this tutorial under the directory you downloaded the tutorial files:
```
export TUTORIAL_HOME=hybrid/sr-automation-workflow/greenfield-cp
```

- Deploy Confluent for Kubernetes (CFK) in cluster mode, so that the one CFK instance can manage Confluent deployments in multiple namespaces. Here, CFK is deployed to the `default` namespace.

```
helm upgrade --install confluent-operator \
  confluentinc/confluent-for-kubernetes \
  --namespace default --set namespaced=false
```

- Check that the Confluent For Kubernetes pod comes up and is running:
```
kubectl get pods
```

- Create a namespace for the Confluent Platform deployment:

```
kubectl create ns confluent
```

## Confluent Platform Deployment

### Create Required Secrets

Create the necessary secrets for Confluent Cloud authentication:

```bash
# Create Confluent Cloud credentials secret  
kubectl -n confluent create secret generic cc-credential \
    --from-file=basic.txt=$TUTORIAL_HOME/cc-credential.txt
```

The `cc-credential.txt` file should contain your Confluent Cloud Schema Registry credential.

Create the password encoder secret for Schema Registry:

```bash
kubectl -n confluent create secret generic password-encoder-secret --from-file=password-encoder.txt=$TUTORIAL_HOME/password-encoder-secret.txt
```

### Deploy Confluent Platform Infrastructure

Deploy the complete Confluent Platform stack:

```bash
kubectl apply -f $TUTORIAL_HOME/confluent-platform.yaml
```

This creates:
- **KRaftController**: 3 replicas for metadata management
- **Kafka**: 3-replica cluster using KRaft mode
- **SchemaRegistry**: 2 replicas with USM forwarder and schema importer extensions enabled

**Key Configuration Features:**
- **USM Enabled**: `unifiedStreamManager.enabled: true` enables forwarder capabilities
- **Remote SR Configuration**: Pre-configured connection to existing Confluent Cloud Schema Registry
- **Schema Extensions**: Importer capability enabled (no exporter needed for greenfield)

Wait for all components to be ready:
```bash
kubectl -n confluent get pods
```

## Greenfield Schema Import Configuration

### Configure Schema Import with Forward Write Mode

Since this is a greenfield deployment with no existing schemas to export, we use the automation workflow's forward write mode feature:

```bash
kubectl apply -f $TUTORIAL_HOME/schemaimporter.yaml
```

The SchemaImporter configuration uses:

```yaml
spec:
  schemaRegistryAutomation:
    enableForwardWriteMode: true  # Triggers automation without requiring an exporter
  subjects: [ ":*:" ]             # Import all schemas from all contexts
  contextName: "."                # Import to default context
```

**Key Features:**
- **No Exporter Required**: `enableForwardWriteMode: true` enables automation workflow without needing a SchemaExporter
- **All Schemas Imported**: `:*:` pattern imports schemas from all contexts in CC
- **Automatic Mode Management**: Automation workflow sets CP to FORWARD mode and maintains CC in READWRITE mode

### Automation Workflow Behavior

The greenfield automation workflow:
- **Validates CC Connection**: Ensures connection to source Confluent Cloud Schema Registry
- **Sets Forward Mode**: Automatically configures CP Schema Registry to FORWARD mode
- **Imports Existing Schemas**: Downloads all existing schemas from CC to CP
- **Maintains Synchronization**: Keeps CP as a read replica of CC schemas

## Schema Registry Modes

This greenfield setup establishes the following mode configuration:

### Confluent Platform (CP) Schema Registry
- **Mode**: FORWARD
- **Behavior**: All write requests are forwarded to Confluent Cloud
- **Purpose**: CP acts as a read replica with write forwarding to maintain CC as the source of truth

### Confluent Cloud (CC) Schema Registry  
- **Mode**: READWRITE
- **Behavior**: Continues to accept both read and write operations
- **Purpose**: Remains the authoritative schema registry for all write operations

## Verification

### Check Deployment Status

Verify all components are running:
```bash
# Check pods
kubectl -n confluent get pods

# Check schema importer status  
kubectl -n confluent get schemaimporters

# Check automation workflow status
kubectl -n confluent describe schemaimporter schema-importer
```

### Verify Schema Import and Forward Mode

Check if schemas are properly imported and forward mode is enabled:

```bash
# Access the Schema Registry pod
kubectl -n confluent exec -it schemaregistry-0 -- bash

# Inside the pod, check imported schemas
curl -X GET "http://localhost:8081/subjects"

# Check schema importer status
curl -X GET http://localhost:8081/importers/schema-importer/status

# Verify forward mode is enabled
curl -X GET http://localhost:8081/mode/:.__GLOBAL:
```

### Test Forward Write Mode

Test the forward write functionality by creating a schema in CP:

```bash
kubectl -n confluent exec -it schemaregistry-0 -- bash

# Create a test schema (will be forwarded to CC)
curl -X POST -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  --data '{"schema": "{\"type\": \"record\", \"name\": \"GreenfieldTest\", \"fields\": [{\"name\": \"id\", \"type\": \"string\"}, {\"name\": \"message\", \"type\": \"string\"}]}"}' \
  http://localhost:8081/subjects/greenfield-test-subject/versions

# Verify the schema was created locally
curl -X GET http://localhost:8081/subjects/greenfield-test-subject/versions/latest

# Check that the schema exists (forwarded to CC, then imported back)
curl -X GET http://localhost:8081/subjects/greenfield-test-subject/versions
```

Due to forward mode, the schema will be:
1. Forwarded to Confluent Cloud when written to CP
2. Imported back to CP through the import process
3. Available in both environments

### Verify Confluent Cloud Synchronization

Check that schemas are properly synchronized in Confluent Cloud:

```bash
# Check subjects in Confluent Cloud (replace with your actual endpoint and credentials)
curl --location 'https://YOUR-CC-SR-ENDPOINT/subjects' \
    --header "Authorization: Basic $(echo -n 'API_KEY:API_SECRET' | base64)"

# Verify the test schema was forwarded to CC
curl --location 'https://YOUR-CC-SR-ENDPOINT/subjects/greenfield-test-subject/versions/latest' \
    --header "Authorization: Basic $(echo -n 'API_KEY:API_SECRET' | base64)"
```

## Troubleshooting

### Common Issues

1. **Schema Registry not starting**: Check if Kafka is fully ready before deploying Schema Registry
2. **USM connection failing**: Verify Confluent Cloud credentials and network connectivity
3. **Import automation stuck**: Check CC connectivity and verify `enableForwardWriteMode: true` is set
4. **Forward mode not enabled**: Ensure automation workflow completed successfully (check importer status)
5. **Schemas not importing**: Verify CC has existing schemas and import pattern `:*:` is correct
6. **Write forwarding not working**: Check USM forwarder configuration and CC connectivity

### Greenfield-Specific Troubleshooting

```bash
# Check import synchronization status
kubectl -n confluent exec -it schemaregistry-0 -- curl -X GET http://localhost:8081/importers/schema-importer/status
```
