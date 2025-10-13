# Schema Registry Context-Based Workflow

This playbook demonstrates how to synchronize distinct schema contexts between Confluent Platform (CP) and Confluent Cloud (CC) using Confluent for Kubernetes (CFK). 
The workflow establishes context-specific bidirectional schema synchronization.

## What This Workflow Does

This context-based workflow:
1. **Deploys a complete Confluent Platform** with KRaft controllers, Kafka, and Schema Registry in Kubernetes
2. **Configures Unified Stream Manager (USM)** to enable forwarder capabilities between CP and CC
3. **Sets up context-specific schema export** from CP to Confluent Cloud using dedicated SchemaExporters
4. **Configures automated context-aware schema import** from Confluent Cloud back to CP using SchemaImporters with automation workflow
5. **Maintains distinct schema contexts** for different organizational units (finance, tech, etc.)

## Context Architecture

This example demonstrates a multi-context schema synchronization pattern:

### Context Mapping
- **CP Context `.`** ↔ **CC Context `cc`**
- **CP Context `finance`** ↔ **CC Context `cc.finance`**
- **CP Context `tech`** ↔ **CC Context `cc.tech`**

## Components

- **KRaftController**: Manages Kafka metadata without requiring Zookeeper
- **Kafka Cluster**: Confluent Platform Kafka cluster with 3 replicas
- **Schema Registry**: CP schema registry with USM forwarder, exporter, and importer extensions enabled
- **SchemaExporter (Default)**: Exports schemas from CP `default` context to CC `cc` context
- **SchemaExporter (Finance)**: Exports schemas from CP `finance` context to CC `cc` context
- **SchemaExporter (Tech)**: Exports schemas from CP `tech` context to CC `cc` context
- **SchemaImporter (Default)**: Imports schemas from CC `cc` context to CP `default` context with automation workflow
- **SchemaImporter (Finance)**: Imports schemas from CC `cc.finance` context to CP `finance` context with automation workflow
- **SchemaImporter (Tech)**: Imports schemas from CC `cc.tech` context to CP `tech` context with automation workflow
- **Unified Stream Manager**: Enables forwarder mode for seamless schema registry integration

## Table of Contents
- [Prerequisites](#prerequisites)
- [Basic Setup](#basic-setup)
- [Confluent Platform Deployment](#confluent-platform-deployment)
- [Context-Based Schema Synchronization](#context-based-schema-synchronization)
- [Verification](#verification)
- [Schema Registry Modes](#schema-registry-modes)

## Prerequisites
- Kubernetes cluster with CFK installed
- Access to Confluent Cloud with Schema Registry enabled
- `kubectl` configured to access your cluster
- Confluent Cloud API credentials for schema registry access

## ⚠️ **IMPORTANT: Clean Existing Mode Settings First** ⚠️

**If you already have an existing Schema Registry setup in Confluent Platform**, you **MUST** clean all mode settings at subject and context levels before proceeding with this tutorial.

**Run the cleanup script:**
```bash
# Navigate to the cleanup directory
cd hybrid/sr-automation-workflow/clean-mode-settings

# Set your Schema Registry endpoint
export SCHEMA_REGISTRY_URL="http://localhost:8081"

# If using authentication, set credentials
export SCHEMA_REGISTRY_USER="your-username"
export SCHEMA_REGISTRY_PASSWORD="your-password"

# Run the cleanup script
./cleanup_mode_settings.sh
```

**Why this is critical:**
- Existing mode settings can conflict with context-specific automation workflows
- Each context automation workflow needs to manage modes independently
- Leftover mode configurations can cause context synchronization failures
- This ensures a clean state for context-based schema synchronization

**⚠️ This step is MANDATORY for existing Schema Registry deployments ⚠️** 

## Basic Setup

- Set the tutorial directory for this tutorial under the directory you downloaded the tutorial files:
```
export TUTORIAL_HOME=hybrid/sr-automation-workflow/distinct-schemas-and-contexts
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

## Context-Based Schema Synchronization

### Configure Context-Specific Schema Synchronization

Set up automated schema synchronization for each organizational context. **IMPORTANT**: Deploy the exporter first, then the importer for each context to ensure proper automation workflow coordination.

#### Default Context Synchronization

**Step 1: Deploy Default Context Export**
```bash
kubectl apply -f $TUTORIAL_HOME/schemaexporter.yaml
```

The Default SchemaExporter will:
- Export all schemas from the default context (`*` pattern) from CP to CC `cc` context
- Use dedicated exporter `schema-exporter` for default/global schemas

**Step 2: Deploy Default Context Import**
```bash
kubectl apply -f $TUTORIAL_HOME/schemaimporter.yaml
```

The Default SchemaImporter will:
- Import schemas from CC `cc` context (`:cc:*` pattern) to CP default context
- Use automation workflow with `exporterName: "schema-exporter"` for coordinated mode management
- Automatically manage schema registry modes for default context synchronization

#### Finance Context Synchronization

**Step 1: Deploy Finance Context Export**
```bash
kubectl apply -f $TUTORIAL_HOME/schemaexporter-finance.yaml
```

The Finance SchemaExporter will:
- Export all schemas in the `finance` context (`:finance:*` pattern) from CP to CC `cc` context
- Use dedicated exporter `schema-exporter-finance` for finance schemas

**Step 2: Deploy Finance Context Import**
```bash
kubectl apply -f $TUTORIAL_HOME/schemaimporter-finance.yaml
```

The Finance SchemaImporter will:
- Import schemas from CC `cc.finance` context (`:cc.finance:*` pattern) to CP `finance` context
- Use automation workflow with `exporterName: "schema-exporter-finance"` for coordinated mode management
- Automatically manage schema registry modes for finance context synchronization

#### Tech Context Synchronization

**Step 1: Deploy Tech Context Export**
```bash
kubectl apply -f $TUTORIAL_HOME/schemaexporter-tech.yaml
```

The Tech SchemaExporter will:
- Export all schemas in the `tech` context (`:.tech:*` pattern) from CP to CC `cc` context
- Use dedicated exporter `schema-exporter-tech` for tech schemas

**Step 2: Deploy Tech Context Import**
```bash
kubectl apply -f $TUTORIAL_HOME/schemaimporter-tech.yaml
```

The Tech SchemaImporter will:
- Import schemas from CC `cc.tech` context (`:.tech:*` pattern) to CP `tech` context
- Use automation workflow with `exporterName: "schema-exporter-tech"` for coordinated mode management
- Automatically manage schema registry modes for tech context synchronization

### Schema Registry Automation Configuration

Each SchemaImporter uses context-specific automation workflow:

```yaml
spec:
  schemaRegistryAutomation:
    exporterName: "schema-exporter-[context]"  # context-specific exporter reference
  contextName: ":[context]:"                   # destination context in CP
  subjects: [ ":[cc-context]:*" ]              # source subjects pattern from CC
```

**Context-Specific Automation Workflow:**
- **Validates** that the specified context exporter exists and is in RUNNING state
- **Coordinates modes** between CP and CC Schema Registries for each context
- **Ensures context isolation** during schema synchronization operations

## Schema Registry Modes

This context-based setup establishes the following mode configuration per context:

### Confluent Platform (CP) Schema Registry
- **Finance Context Mode**: FORWARD
- **Tech Context Mode**: FORWARD
- **Behavior**: Forwards write requests to appropriate Confluent Cloud contexts
- **Purpose**: Ensures CC remains the authoritative source for schema writes in each context

### Confluent Cloud (CC) Schema Registry  
- **cc.finance Context Mode**: READWRITE
- **tech Context Mode**: READWRITE
- **Behavior**: Accepts both read and write operations per context
- **Purpose**: Serves as the primary schema registry for context-specific write operations

## Verification

### Check Deployment Status

Verify all components are running:
```bash
# Check pods
kubectl -n confluent get pods

# Check context-specific schema exporters
kubectl -n confluent get schemaexporters

# Check context-specific schema importers  
kubectl -n confluent get schemaimporters

# Check automation workflow status for each context
kubectl -n confluent describe schemaimporter schema-importer
kubectl -n confluent describe schemaimporter schema-importer-finance
kubectl -n confluent describe schemaimporter schema-importer-tech
```

### Verify Context-Based Schema Synchronization

Check if schemas are properly exported and imported for each context:

```bash
# Access the Schema Registry pod
kubectl -n confluent exec -it schemaregistry-0 -- bash

# Inside the pod, check subjects in different contexts
curl -X GET "http://localhost:8081/subjects"  # default context
curl -X GET "http://localhost:8081/subjects?subjectPrefix=:.finance:" # finance context
curl -X GET "http://localhost:8081/subjects?subjectPrefix=:.tech:" # tech context

# Check status of context-specific exporters
curl -X GET http://localhost:8081/exporters/schema-exporter/status
curl -X GET http://localhost:8081/exporters/schema-exporter-finance/status
curl -X GET http://localhost:8081/exporters/schema-exporter-tech/status

# Check context-specific importers
curl -X GET http://localhost:8081/importers/schema-importer/status
curl -X GET http://localhost:8081/importers/schema-importer-finance/status  
curl -X GET http://localhost:8081/importers/schema-importer-tech/status
```

### Test Context-Specific Schema Mirroring

Test the context-based mirroring by creating schemas in different contexts:

#### Test Default Context
```bash
kubectl -n confluent exec -it schemaregistry-0 -- bash

# Create a schema in default context
curl -X POST -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  --data '{"schema": "{\"type\": \"record\", \"name\": \"DefaultRecord\", \"fields\": [{\"name\": \"id\", \"type\": \"string\"}, {\"name\": \"timestamp\", \"type\": \"long\"}]}"}' \
  "http://localhost:8081/subjects/default-events/versions"

# Verify the schema was created in default context
curl -X GET "http://localhost:8081/subjects/default-events/versions/latest"
```

#### Test Finance Context
```bash
kubectl -n confluent exec -it schemaregistry-0 -- bash

# Create a schema in finance context
curl -X POST -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  --data '{"schema": "{\"type\": \"record\", \"name\": \"FinanceRecord\", \"fields\": [{\"name\": \"accountId\", \"type\": \"string\"}, {\"name\": \"amount\", \"type\": \"double\"}]}"}' \
  "http://localhost:8081/subjects/:.finance:finance-transactions/versions"

# Verify the schema was created in finance context
curl -X GET "http://localhost:8081/subjects/:.finance:finance-transactions/versions/latest"
```

#### Test Tech Context
```bash
# Create a schema in tech context
curl -X POST -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  --data '{"schema": "{\"type\": \"record\", \"name\": \"TechRecord\", \"fields\": [{\"name\": \"serviceId\", \"type\": \"string\"}, {\"name\": \"version\", \"type\": \"string\"}]}"}' \
  "http://localhost:8081/subjects/:.tech:tech-services/versions"

# Verify the schema was created in tech context
curl -X GET "http://localhost:8081/subjects/:.tech:tech-services/versions/latest"
```

The schemas should appear in their respective contexts in both CP and CC due to the context-specific mirroring setup.

### Verify Confluent Cloud Context Synchronization

Check schemas are synchronized in the appropriate Confluent Cloud contexts.

## Troubleshooting

### Common Issues

1. **Context-specific exporters not starting**: Check if Kafka and Schema Registry are fully ready
2. **USM connection failing per context**: Verify Confluent Cloud credentials and context configuration
3. **Context automation workflow stuck**: Check context-specific exporter status and validate context names
4. **Schema sync issues in specific contexts**: Verify both context exporters and importers are in RUNNING state
5. **Context mode conflicts**: Ensure automation workflow completed successfully for each context (check importer status)
6. **Subject pattern mismatches**: Verify context naming conventions match between exporters and importers
