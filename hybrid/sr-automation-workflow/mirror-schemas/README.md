# Schema Registry Mirroring Workflow

This playbook demonstrates how to create an exact replica between Confluent Platform (CP) and Confluent Cloud (CC) using Confluent for Kubernetes (CFK). 
The workflow establishes true bidirectional schema synchronization, ensuring both environments maintain identical schema repositories.

## What This Workflow Does

This mirroring workflow:
1. **Deploys a complete Confluent Platform** with KRaft controllers, Kafka, and Schema Registry in Kubernetes
2. **Configures Unified Stream Manager (USM)** to enable forwarder capabilities between CP and CC
3. **Sets up bidirectional schema export** from CP to Confluent Cloud using SchemaExporter
4. **Configures automated schema import** from Confluent Cloud back to CP using SchemaImporter with automation workflow
5. **Maintains exact schema replicas** across both environments with automated mode coordination

## Components

- **KRaft Controller**: Manages Kafka metadata without requiring Zookeeper
- **Kafka Cluster**: Confluent Platform Kafka cluster with 3 replicas
- **Schema Registry**: CP schema registry with USM forwarder, exporter, and importer extensions enabled
- **SchemaExporter**: Exports all schemas from CP to Confluent Cloud
- **SchemaImporter**: Imports all schemas from Confluent Cloud to CP with automation workflow
- **Unified Stream Manager**: Enables forwarder mode for seamless schema registry integration

## Table of Contents
- [Prerequisites](#prerequisites)
- [Basic Setup](#basic-setup)
- [Confluent Platform Deployment](#confluent-platform-deployment)
- [Schema Mirroring Configuration](#schema-mirroring-configuration)
- [Verification](#verification)
- [Schema Registry Modes](#schema-registry-modes)

## Prerequisites

- Kubernetes cluster with CFK installed
- Access to Confluent Cloud with Schema Registry enabled
- `kubectl` configured to access your cluster
- Confluent Cloud API credentials for schema registry access

## Basic Setup

- Set the tutorial directory for this tutorial under the directory you downloaded the tutorial files:
```
export TUTORIAL_HOME=hybrid/sr-automation-workflow/mirror-schemas
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
- **SchemaRegistry**: 2 replicas with USM forwarder, schema exporter, and importer extensions enabled

**Key Configuration Features:**
- **USM Enabled**: `unifiedStreamManager.enabled: true` enables forwarder capabilities
- **Remote SR Configuration**: Pre-configured connection to Confluent Cloud Schema Registry
- **Schema Extensions**: Both exporter and importer capabilities enabled

Wait for all components to be ready:
```bash
kubectl -n confluent get pods
```

## Schema Mirroring Configuration

### Configure Schema Export to Confluent Cloud

Set up automated schema export from CP to CC:

```bash
kubectl apply -f $TUTORIAL_HOME/schemaexporter.yaml
```

The SchemaExporter will:
- Export all schemas in all contexts (`:*:` pattern) from CP Schema Registry to Confluent Cloud
- Use `contextType: "NONE"` to preserve original context structure.
- Authenticate using Confluent Cloud credentials

### Configure Schema Import from Confluent Cloud

Set up bidirectional synchronization with automation workflow:

```bash
kubectl apply -f $TUTORIAL_HOME/schemaimporter.yaml
```

The SchemaImporter will:
- Import all schemas in all contexts (`:*:` pattern) from Confluent Cloud to CP
- Use automation workflow with `exporterName: "schema-exporter"` to coordinate schema registry modes
- Automatically set CP to FORWARD mode and CC contexts to READWRITE mode

### Schema Registry Automation Configuration

The SchemaImporter uses automation workflow to ensure proper mode coordination:

```yaml
spec:
  schemaRegistryAutomation:
    exporterName: "schema-exporter"
```

**Automation Workflow Behavior:**
- **Validates** that the specified exporter exists and is in RUNNING state
- **Coordinates modes** between CP and CC Schema Registries:
  - CP Schema Registry (destination) → **FORWARD mode**  
  - CC Schema Registry contexts (source) → **READWRITE mode**
- **Ensures consistency** during schema synchronization operations

## Schema Registry Modes

This mirroring setup establishes the following mode configuration:

### Confluent Platform (CP) Schema Registry
- **Mode**: FORWARD
- **Behavior**: Forwards write requests to Confluent Cloud
- **Purpose**: Ensures CC remains the authoritative source for schema writes

### Confluent Cloud (CC) Schema Registry  
- **Mode**: READWRITE (for imported contexts)
- **Behavior**: Accepts both read and write operations
- **Purpose**: Serves as the primary schema registry for write operations

### Bidirectional Flow
1. **Schemas written to CC** → Automatically imported to CP via SchemaImporter
2. **Schemas written to CP** → Forwarded to CC (due to FORWARD mode) → Exported back via SchemaExporter
3. **Result**: Both registries maintain identical schema copies

## Verification

### Check Deployment Status

Verify all components are running:
```bash
# Check pods
kubectl -n confluent get pods

# Check schema exporter status
kubectl -n confluent get schemaexporters

# Check schema importer status  
kubectl -n confluent get schemaimporters

# Check automation workflow status
kubectl -n confluent describe schemaimporter schema-importer
```

### Verify Schema Synchronization

Check if schemas are properly exported and imported:

```bash
# Access the Schema Registry pod
kubectl -n confluent exec -it schemaregistry-0 -- bash

# Inside the pod, check local schemas
curl -X GET http://localhost:8081/subjects?subjectPrefix=:*:

# Check schema exporter status
curl -X GET http://localhost:8081/exporters/schema-exporter/status

# Check schema importer status  
curl -X GET http://localhost:8081/importers/schema-importer/status

# Check schema registry mode
curl -X GET http://localhost:8081/mode/:.__GLOBAL:
```

### Test Schema Mirroring

Test the bidirectional mirroring by creating a schema:

```bash
# Create a test schema in CP (it will be forwarded to CC due to FORWARD mode)
kubectl -n confluent exec -it schemaregistry-0 -- bash

# Inside the pod, create a test schema
curl -X POST -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  --data '{"schema": "{\"type\": \"record\", \"name\": \"TestRecord\", \"fields\": [{\"name\": \"id\", \"type\": \"int\"}, {\"name\": \"name\", \"type\": \"string\"}]}"}' \
  http://localhost:8081/subjects/test-mirroring-subject/versions

# Verify the schema was created
curl -X GET http://localhost:8081/subjects/test-mirroring-subject/versions/latest
```

The schema should appear in both CP and CC due to the mirroring setup.


### Verify Confluent Cloud Synchronization

Check schemas are synchronized in Confluent Cloud:

```bash
# Check subjects in Confluent Cloud (replace with your actual endpoint and credentials)
curl --location 'https://YOUR-CC-SR-ENDPOINT/subjects?subjectPrefix=:*:' \
    --header "Authorization: Basic $(echo -n 'API_KEY:API_SECRET' | base64)"
```

## Troubleshooting

### Common Issues

1. **Schema Registry not starting**: Check if Kafka is fully ready before deploying Schema Registry
2. **USM connection failing**: Verify Confluent Cloud credentials and network connectivity  
3. **Automation workflow stuck**: Check exporter status and forwarder configuration validation
4. **Schema sync issues**: Verify both exporter and importer are in RUNNING state
5. **Mode conflicts**: Ensure automation workflow completed successfully (check importer status)
