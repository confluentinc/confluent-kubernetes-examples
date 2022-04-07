# Scenario: Create own certificates for each component

When testing, it's often helpful to generate your own certificates to validate the architecture and deployment.

In this scenario workflow, you'll create one server certificate per Confluent component service. You'll use the same certificate authority for all.

To get an overview of the underlying concepts, read this: 
[User-provided TLS certificates](https://docs.confluent.io/operator/current/co-network-encryption.html#configure-user-provided-tls-certificates) 

Set the `TUTORIAL_HOME` path to ease directory references in the commands you run:
```
export TUTORIAL_HOME=<Git repository path>/assets/certs/component-certs
```

This scenario workflow requires the following CLI tools to be available on the machine you
are using:

- openssl
- cfssl

## Setting the Subject Alternate Names

In this scenario workflow, we make the following assumptions:

- You are deploying the Confluent components to a Kubernetes namespace `confluent`
- You are using an external domain name `mydomain.example`
- You can use a wildcard domain in your certificate SAN. If you don't use wildcards, 
  you will need to specify each URL for each Confluent component instance. 

The Subject Alternate Names are specified in the `hosts` section of the *-server-domain.json 
files. If you want to change any of the above assumptions, then edit the *-server-domain.json 
files accordingly.

## Create a certificate authority

In this step, you will create:

* Certificate authority (CA) private key (`ca-key.pem`)
* Certificate authority (CA) certificate (`ca.pem`)

1. Generate a private key called rootCAkey.pem for the CA:

```
mkdir $TUTORIAL_HOME/generated && openssl genrsa -out $TUTORIAL_HOME/generated/rootCAkey.pem 2048
```

2. Generate the CA certificate.

```
openssl req -x509  -new -nodes \
  -key $TUTORIAL_HOME/generated/rootCAkey.pem \
  -days 3650 \
  -out $TUTORIAL_HOME/generated/cacerts.pem \
  -subj "/C=US/ST=CA/L=MVT/O=TestOrg/OU=Cloud/CN=TestCA"
```

3. Check the validatity of the CA

```
openssl x509 -in $TUTORIAL_HOME/generated/cacerts.pem -text -noout
```

## Create the Confluent component server certificates

In this series of steps, you will create the server certificate private and public keys
for each Confluent component.

### Create server certificates

```
# Create Zookeeper server certificates
# Use the SANs listed in zookeeper-server-domain.json

cfssl gencert -ca=$TUTORIAL_HOME/generated/cacerts.pem \
-ca-key=$TUTORIAL_HOME/generated/rootCAkey.pem \
-config=$TUTORIAL_HOME/ca-config.json \
-profile=server $TUTORIAL_HOME/zookeeper-server-domain.json | cfssljson -bare $TUTORIAL_HOME/generated/zookeeper-server

# Create Kafka server certificates
# Use the SANs listed in kafka-server-domain.json

cfssl gencert -ca=$TUTORIAL_HOME/generated/cacerts.pem \
-ca-key=$TUTORIAL_HOME/generated/rootCAkey.pem \
-config=$TUTORIAL_HOME/ca-config.json \
-profile=server $TUTORIAL_HOME/kafka-server-domain.json | cfssljson -bare $TUTORIAL_HOME/generated/kafka-server

# Create ControlCenter server certificates
# Use the SANs listed in controlcenter-server-domain.json

cfssl gencert -ca=$TUTORIAL_HOME/generated/cacerts.pem \
-ca-key=$TUTORIAL_HOME/generated/rootCAkey.pem \
-config=$TUTORIAL_HOME/ca-config.json \
-profile=server $TUTORIAL_HOME/controlcenter-server-domain.json | cfssljson -bare $TUTORIAL_HOME/generated/controlcenter-server

# Create SchemaRegistry server certificates
# Use the SANs listed in schemaregistry-server-domain.json

cfssl gencert -ca=$TUTORIAL_HOME/generated/cacerts.pem \
-ca-key=$TUTORIAL_HOME/generated/rootCAkey.pem \
-config=$TUTORIAL_HOME/ca-config.json \
-profile=server $TUTORIAL_HOME/schemaregistry-server-domain.json | cfssljson -bare $TUTORIAL_HOME/generated/schemaregistry-server

# Create Connect server certificates
# Use the SANs listed in connect-server-domain.json

cfssl gencert -ca=$TUTORIAL_HOME/generated/cacerts.pem \
-ca-key=$TUTORIAL_HOME/generated/rootCAkey.pem \
-config=$TUTORIAL_HOME/ca-config.json \
-profile=server $TUTORIAL_HOME/connect-server-domain.json | cfssljson -bare $TUTORIAL_HOME/generated/connect-server

# Create ksqlDB server certificates
# Use the SANs listed in ksqldb-server-domain.json

cfssl gencert -ca=$TUTORIAL_HOME/generated/cacerts.pem \
-ca-key=$TUTORIAL_HOME/generated/rootCAkey.pem \
-config=$TUTORIAL_HOME/ca-config.json \
-profile=server $TUTORIAL_HOME/ksqldb-server-domain.json | cfssljson -bare $TUTORIAL_HOME/generated/ksqldb-server

# Create Kafka Rest Proxy server certificates
# Use the SANs listed in kafkarestproxy-server-domain.json

cfssl gencert -ca=$TUTORIAL_HOME/generated/cacerts.pem \
-ca-key=$TUTORIAL_HOME/generated/rootCAkey.pem \
-config=$TUTORIAL_HOME/ca-config.json \
-profile=server $TUTORIAL_HOME/kafkarestproxy-server-domain.json | cfssljson -bare $TUTORIAL_HOME/generated/kafkarestproxy-server
```

### Check validity of server certificates

```
openssl x509 -in $TUTORIAL_HOME/generated/zookeeper-server.pem -text -noout

openssl x509 -in $TUTORIAL_HOME/generated/kafka-server.pem -text -noout

openssl x509 -in $TUTORIAL_HOME/generated/controlcenter-server.pem -text -noout

openssl x509 -in $TUTORIAL_HOME/generated/schemaregistry-server.pem -text -noout

openssl x509 -in $TUTORIAL_HOME/generated/connect-server.pem -text -noout

openssl x509 -in $TUTORIAL_HOME/generated/ksqldb-server.pem -text -noout

openssl x509 -in $TUTORIAL_HOME/generated/kafkarestproxy-server.pem -text -noout
```