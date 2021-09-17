# Scenario: Create one certificate for all components

When testing, it's often helpful to generate your own certificates to validate the architecture and deployment.

In this scenario workflow, you'll create one server certificate for all Confluent component services. You'll use the same certificate authority.

To get an overview of the underlying concepts, read this: 
[User-provided TLS certificates](https://docs.confluent.io/operator/current/co-network-encryption.html#configure-user-provided-tls-certificates) 

Set the `TUTORIAL_HOME` path to ease directory references in the commands you run:
```
export TUTORIAL_HOME=<Git repository path>/assets/certs
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

The Subject Alternate Names are specified in the `hosts` section of the $TUTORIAL_HOME/server-domain.json 
files. If you want to change any of the above assumptions, then edit the $TUTORIAL_HOME/server-domain.json 
files accordingly.

## Create a certificate authority

In this step, you will create:

* Certificate authority (CA) private key (`ca-key.pem`)
* Certificate authority (CA) certificate (`ca.pem`)

1. Generate a private key called rootCAkey.pem for the CA:

```
openssl genrsa -out $TUTORIAL_HOME/generated/rootCAkey.pem 2048
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
# Create CP Component server certificate
# Use the SANs listed in kafka-server-domain.json

cfssl gencert -ca=$TUTORIAL_HOME/generated/cacerts.pem \
-ca-key=$TUTORIAL_HOME/generated/rootCAkey.pem \
-config=$TUTORIAL_HOME/ca-config.json \
-profile=server $TUTORIAL_HOME/server-domain.json | cfssljson -bare $TUTORIAL_HOME/generated/server
```

### Check validity of server certificates

```
openssl x509 -in $TUTORIAL_HOME/generated/server.pem -text -noout
```