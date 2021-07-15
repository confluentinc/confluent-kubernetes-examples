# Security setup

In this workflow scenario, you'll set up a Confluent Platform cluster with the following security:
- Full TLS network encryption with user provided certificates
- mTLS authentication
- Kafka ACLs authorization

Before continuing with the scenario, ensure that you have set up the [prerequisites](https://github.com/confluentinc/confluent-kubernetes-examples/blob/master/README.md#prerequisites).

## Set the current tutorial directory

Set the tutorial directory for this tutorial under the directory you downloaded the tutorial files:

```
export TUTORIAL_HOME=<Tutorial directory>/security/userprovided-tls_mtls_confluent_rbac
```
  
## Deploy Confluent for Kubernetes

Set up the Helm Chart:

```
helm repo add confluentinc https://packages.confluent.io/helm
```

Install Confluent For Kubernetes using Helm:

```
helm upgrade --install operator confluentinc/confluent-for-kubernetes --namespace confluent
```
  
Check that the Confluent For Kubernetes pod comes up and is running:

```
kubectl get pods --namespace confluent
```

## Deploy OpenLDAP

This repo includes a Helm chart for [OpenLdap](https://github.com/osixia/docker-openldap). The chart `values.yaml`
includes the set of principal definitions that Confluent Platform needs for RBAC.

Deploy OpenLdap:

```
helm upgrade --install -f $TUTORIAL_HOME/../../assets/openldap/ldaps-rbac.yaml test-ldap $TUTORIAL_HOME/../../assets/openldap --namespace confluent
```

Validate that OpenLDAP is running:  

```
kubectl get pods --namespace confluent
```

Log in to the LDAP pod:

```
kubectl --namespace confluent exec -it ldap-0 -- bash

# Run the LDAP search command
ldapsearch -LLL -x -H ldap://ldap.confluent.svc.cluster.local:389 -b 'dc=test,dc=com' -D "cn=mds,dc=test,dc=com" -w 'Developer!'

# Exit out of the LDAP pod
exit
```

## Create TLS certificates

In this scenario, you'll configure authentication using the mTLS mechanism. With mTLS, Confluent components and clients use TLS certificates for authentication. The certificate has a CN that identifies the principal name.

Each Confluent component service should have it's own TLS certificate. In this scenario, you'll
generate a server certificate for each Confluent component service. Follow [these instructions](../../assets/certs/component-certs/README.md) to generate these certificates.
     
## Deploy configuration secrets

You'll use Kubernetes secrets to provide credential configurations.

With Kubernetes secrets, credential management (defining, configuring, updating)
can be done outside of the Confluent For Kubernetes. You define the configuration
secret, and then tell Confluent For Kubernetes where to find the configuration.
   
To support the above deployment scenario, you need to provide the following
credentials:

* Component TLS Certificates

* Authentication credentials for Zookeeper, Kafka, Control Center, remaining CP components

* RBAC principal credentials

### Provide component TLS certificates

Set the tutorial directory for this tutorial under the directory you downloaded the tutorial files:

```
export TUTORIAL_HOME=<Tutorial directory>/security/userprovided-tls_mtls_confluent_rbac
```

In this step, you will create secrets for each Confluent component TLS certificates.

```
kubectl create secret generic tls-zookeeper \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/zookeeper-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/zookeeper-server-key.pem \
  --namespace confluent

kubectl create secret generic tls-kafka \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/kafka-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/kafka-server-key.pem \
  --namespace confluent

kubectl create secret generic tls-controlcenter \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/controlcenter-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/controlcenter-server-key.pem \
  --namespace confluent

kubectl create secret generic tls-schemaregistry \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/schemaregistry-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/schemaregistry-server-key.pem \
  --namespace confluent

kubectl create secret generic tls-connect \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/connect-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/connect-server-key.pem \
  --namespace confluent

kubectl create secret generic tls-ksqldb \
  --from-file=fullchain.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/ksqldb-server.pem \
  --from-file=cacerts.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/cacerts.pem \
  --from-file=privkey.pem=$TUTORIAL_HOME/../../assets/certs/component-certs/generated/ksqldb-server-key.pem \
  --namespace confluent
```

### Provide authentication credentials

Create a Kubernetes secret object for Zookeeper, Kafka, and Control Center.

This secret object contains file based properties. These files are in the
format that each respective Confluent component requires for authentication
credentials.

```   
kubectl create secret generic credential \
  --from-file=digest-users.json=$TUTORIAL_HOME/creds-zookeeper-sasl-digest-users.json \
  --from-file=digest.txt=$TUTORIAL_HOME/creds-kafka-zookeeper-credentials.txt \
  --from-file=basic.txt=$TUTORIAL_HOME/creds-control-center-users.txt \
  --from-file=ldap.txt=$TUTORIAL_HOME/ldap.txt \
  --namespace confluent
```

In this tutorial, we use one credential for authenticating all client and
server communication to Kafka brokers. In production scenarios, you'll want
to specify different credentials for each of them.

### Provide RBAC principal credentials

Create a Kubernetes secret object for MDS:

```
kubectl create secret generic mds-token \
  --from-file=mdsPublicKey.pem=$TUTORIAL_HOME/../../assets/certs/mds-publickey.txt \
  --from-file=mdsTokenKeyPair.pem=$TUTORIAL_HOME/../../assets/certs/mds-tokenkeypair.txt \
  --namespace confluent
   
# Kafka RBAC credential
kubectl create secret generic mds-client \
  --from-file=bearer.txt=$TUTORIAL_HOME/kafka-client.txt \
  --namespace confluent
# Control Center RBAC credential
kubectl create secret generic c3-mds-client \
  --from-file=bearer.txt=$TUTORIAL_HOME/c3-mds-client.txt \
  --namespace confluent
# Connect RBAC credential
kubectl create secret generic connect-mds-client \
  --from-file=bearer.txt=$TUTORIAL_HOME/connect-mds-client.txt \
  --namespace confluent
# Schema Registry RBAC credential
kubectl create secret generic sr-mds-client \
  --from-file=bearer.txt=$TUTORIAL_HOME/sr-mds-client.txt \
  --namespace confluent
# ksqlDB RBAC credential
kubectl create secret generic ksqldb-mds-client \
  --from-file=bearer.txt=$TUTORIAL_HOME/ksqldb-mds-client.txt \
  --namespace confluent
# Kafka REST credential
kubectl create secret generic rest-credential \
  --from-file=bearer.txt=$TUTORIAL_HOME/kafka-client.txt \
  --from-file=basic.txt=$TUTORIAL_HOME/kafka-client.txt \
  --namespace confluent
```

## Deploy Confluent Platform

Deploy Confluent Platform:

```
kubectl apply -f $TUTORIAL_HOME/confluent-platform-mtls-rbac.yaml --namespace confluent
```

Check that all Confluent Platform resources are deployed:

```
kubectl get pods --namespace confluent
```

If any component does not deploy, it could be due to missing configuration information in secrets.
The Kubernetes events will tell you if there are any issues with secrets. For example:

```
kubectl get events --namespace confluent
Warning  KeyInSecretRefIssue  kafka/kafka  required key [ldap.txt] missing in secretRef [credential] for auth type [ldap_simple]
```

The default required RoleBindings for each Confluent component are created
automatically, and maintained as `confluentrolebinding` custom resources.

```
kubectl get confluentrolebinding --namespace confluent
```

If you'd like to see how the RoleBindings custom resources are structured, so that
you can create your own RoleBindings, take a look at the custom resources in this 
directory: $TUTORIAL_HOME/internal-rolebindings

## Create RBAC Rolebindings for Control Center admin

Create Control Center Role Binding for a Control Center `testadmin` user.

```
kubectl apply -f $TUTORIAL_HOME/controlcenter-testadmin-rolebindings.yaml --namespace confluent
```

## Validate

### Validate in Control Center

Use Control Center to monitor the Confluent Platform, and see the created topic
and data. You can visit the external URL you set up for Control Center, or visit the URL
through a local port forwarding like below:

Set up port forwarding to Control Center web UI from local machine:

```
kubectl port-forward controlcenter-0 9021:9021 --namespace confluent
```

Browse to Control Center. You will log in as the `testadmin` user, with `testadmin` password.

```
https://localhost:9021
```

The `testadmin` user (`testadmin` password) has the `SystemAdmin` role granted and will have access to the
cluster and broker information.

## Tear down

```
kubectl delete confluentrolebinding --all --namespace confluent
  
kubectl delete -f $TUTORIAL_HOME/confluent-platform-production.yaml --namespace confluent

kubectl delete secret rest-credential ksqldb-mds-client sr-mds-client connect-mds-client c3-mds-client mds-client --namespace confluent

kubectl delete secret mds-token --namespace confluent

kubectl delete secret credential --namespace confluent

kubectl delete secret tls-group1 --namespace confluent

helm delete test-ldap --namespace confluent

helm delete operator --namespace confluent
```

## Appendix: Troubleshooting

### Gather data to troubleshoot

```
# Check for any error messages in events
kubectl get events --namespace confluent

# Check for any pod failures
kubectl get pods --namespace confluent

# For pod failures, check logs
kubectl logs <pod-name> --namespace confluent
```

### Issues with Zookeeper certificates

The following errors appear in the logs when the certificates are wrong - the wrong certificate authority was specified in this case.

```
[WARN] 2021-07-13 14:51:50,042 [QuorumConnectionThread-[myid=0]-1] org.apache.zookeeper.server.quorum.QuorumCnxManager initiateConnection - Cannot open channel to 1 at election address zookeeper-1.zookeeper.confluent.svc.cluster.local/10.124.3.10:3888
javax.net.ssl.SSLHandshakeException: PKIX path building failed: sun.security.provider.certpath.SunCertPathBuilderException: unable to find valid certification path to requested target
	at java.base/sun.security.ssl.Alert.createSSLException(Alert.java:131)
	at java.base/sun.security.ssl.TransportContext.fatal(TransportContext.java:349)
	at java.base/sun.security.ssl.TransportContext.fatal(TransportContext.java:292)
	at java.base/sun.security.ssl.TransportContext.fatal(TransportContext.java:287)
	at java.base/sun.security.ssl.CertificateMessage$T12CertificateConsumer.checkServerCerts(CertificateMessage.java:654)
	at java.base/sun.security.ssl.CertificateMessage$T12CertificateConsumer.onCertificate(CertificateMessage.java:473)
	at java.base/sun.security.ssl.CertificateMessage$T12CertificateConsumer.consume(CertificateMessage.java:369)
	at java.base/sun.security.ssl.SSLHandshake.consume(SSLHandshake.java:392)
	at java.base/sun.security.ssl.HandshakeContext.dispatch(HandshakeContext.java:443)
	at java.base/sun.security.ssl.HandshakeContext.dispatch(HandshakeContext.java:421)
	at java.base/sun.security.ssl.TransportContext.dispatch(TransportContext.java:182)
	at java.base/sun.security.ssl.SSLTransport.decode(SSLTransport.java:171)
	at java.base/sun.security.ssl.SSLSocketImpl.decode(SSLSocketImpl.java:1418)
	at java.base/sun.security.ssl.SSLSocketImpl.readHandshakeRecord(SSLSocketImpl.java:1324)
	at java.base/sun.security.ssl.SSLSocketImpl.startHandshake(SSLSocketImpl.java:440)
	at java.base/sun.security.ssl.SSLSocketImpl.startHandshake(SSLSocketImpl.java:411)
	at org.apache.zookeeper.server.quorum.QuorumCnxManager.initiateConnection(QuorumCnxManager.java:366)
	at org.apache.zookeeper.server.quorum.QuorumCnxManager$QuorumConnectionReqThread.run(QuorumCnxManager.java:436)
	at java.base/java.util.concurrent.ThreadPoolExecutor.runWorker(ThreadPoolExecutor.java:1128)
	at java.base/java.util.concurrent.ThreadPoolExecutor$Worker.run(ThreadPoolExecutor.java:628)
	at java.base/java.lang.Thread.run(Thread.java:829)
Caused by: sun.security.validator.ValidatorException: PKIX path building failed: sun.security.provider.certpath.SunCertPathBuilderException: unable to find valid certification path to requested target
	at java.base/sun.security.validator.PKIXValidator.doBuild(PKIXValidator.java:439)
	at java.base/sun.security.validator.PKIXValidator.engineValidate(PKIXValidator.java:306)
	at java.base/sun.security.validator.Validator.validate(Validator.java:264)
	at java.base/sun.security.ssl.X509TrustManagerImpl.validate(X509TrustManagerImpl.java:313)
	at java.base/sun.security.ssl.X509TrustManagerImpl.checkTrusted(X509TrustManagerImpl.java:222)
	at java.base/sun.security.ssl.X509TrustManagerImpl.checkServerTrusted(X509TrustManagerImpl.java:129)
	at org.apache.zookeeper.common.ZKTrustManager.checkServerTrusted(ZKTrustManager.java:80)
	at java.base/sun.security.ssl.CertificateMessage$T12CertificateConsumer.checkServerCerts(CertificateMessage.java:638)
	... 16 more
Caused by: sun.security.provider.certpath.SunCertPathBuilderException: unable to find valid certification path to requested target
	at java.base/sun.security.provider.certpath.SunCertPathBuilder.build(SunCertPathBuilder.java:141)
	at java.base/sun.security.provider.certpath.SunCertPathBuilder.engineBuild(SunCertPathBuilder.java:126)
	at java.base/java.security.cert.CertPathBuilder.build(CertPathBuilder.java:297)
	at java.base/sun.security.validator.PKIXValidator.doBuild(PKIXValidator.java:434)
	... 23 more
```

The following occur when the wrong certificate authority private key was used to generate the 
server certificates.

```
[WARN] 2021-07-13 15:12:28,978 [QuorumConnectionThread-[myid=0]-3] org.apache.zookeeper.server.quorum.QuorumCnxManager initiateConnection - Cannot open channel to 1 at election address zookeeper-1.zookeeper.confluent.svc.cluster.local/10.124.0.23:3888
java.net.ConnectException: Connection refused (Connection refused)
	at java.base/java.net.PlainSocketImpl.socketConnect(Native Method)
	at java.base/java.net.AbstractPlainSocketImpl.doConnect(AbstractPlainSocketImpl.java:399)
	at java.base/java.net.AbstractPlainSocketImpl.connectToAddress(AbstractPlainSocketImpl.java:242)
	at java.base/java.net.AbstractPlainSocketImpl.connect(AbstractPlainSocketImpl.java:224)
	at java.base/java.net.SocksSocketImpl.connect(SocksSocketImpl.java:392)
	at java.base/java.net.Socket.connect(Socket.java:609)
	at java.base/sun.security.ssl.SSLSocketImpl.connect(SSLSocketImpl.java:289)
	at org.apache.zookeeper.server.quorum.QuorumCnxManager.initiateConnection(QuorumCnxManager.java:365)
	at org.apache.zookeeper.server.quorum.QuorumCnxManager$QuorumConnectionReqThread.run(QuorumCnxManager.java:436)
	at java.base/java.util.concurrent.ThreadPoolExecutor.runWorker(ThreadPoolExecutor.java:1128)
	at java.base/java.util.concurrent.ThreadPoolExecutor$Worker.run(ThreadPoolExecutor.java:628)
	at java.base/java.lang.Thread.run(Thread.java:829)
[WARN] 2021-07-13 15:12:29,004 [QuorumConnectionThread-[myid=0]-2] org.apache.zookeeper.server.quorum.QuorumCnxManager initiateConnection - Cannot open channel to 2 at election address zookeeper-2.zookeeper.confluent.svc.cluster.local/10.124.4.12:3888
javax.net.ssl.SSLHandshakeException: PKIX path validation failed: java.security.cert.CertPathValidatorException: signature check failed
	at java.base/sun.security.ssl.Alert.createSSLException(Alert.java:131)
	at java.base/sun.security.ssl.TransportContext.fatal(TransportContext.java:349)
	at java.base/sun.security.ssl.TransportContext.fatal(TransportContext.java:292)
	at java.base/sun.security.ssl.TransportContext.fatal(TransportContext.java:287)
	at java.base/sun.security.ssl.CertificateMessage$T12CertificateConsumer.checkServerCerts(CertificateMessage.java:654)
	at java.base/sun.security.ssl.CertificateMessage$T12CertificateConsumer.onCertificate(CertificateMessage.java:473)
	at java.base/sun.security.ssl.CertificateMessage$T12CertificateConsumer.consume(CertificateMessage.java:369)
	at java.base/sun.security.ssl.SSLHandshake.consume(SSLHandshake.java:392)
	at java.base/sun.security.ssl.HandshakeContext.dispatch(HandshakeContext.java:443)
	at java.base/sun.security.ssl.HandshakeContext.dispatch(HandshakeContext.java:421)
	at java.base/sun.security.ssl.TransportContext.dispatch(TransportContext.java:182)
	at java.base/sun.security.ssl.SSLTransport.decode(SSLTransport.java:171)
	at java.base/sun.security.ssl.SSLSocketImpl.decode(SSLSocketImpl.java:1418)
	at java.base/sun.security.ssl.SSLSocketImpl.readHandshakeRecord(SSLSocketImpl.java:1324)
	at java.base/sun.security.ssl.SSLSocketImpl.startHandshake(SSLSocketImpl.java:440)
	at java.base/sun.security.ssl.SSLSocketImpl.startHandshake(SSLSocketImpl.java:411)
	at org.apache.zookeeper.server.quorum.QuorumCnxManager.initiateConnection(QuorumCnxManager.java:366)
	at org.apache.zookeeper.server.quorum.QuorumCnxManager$QuorumConnectionReqThread.run(QuorumCnxManager.java:436)
	at java.base/java.util.concurrent.ThreadPoolExecutor.runWorker(ThreadPoolExecutor.java:1128)
	at java.base/java.util.concurrent.ThreadPoolExecutor$Worker.run(ThreadPoolExecutor.java:628)
	at java.base/java.lang.Thread.run(Thread.java:829)
Caused by: sun.security.validator.ValidatorException: PKIX path validation failed: java.security.cert.CertPathValidatorException: signature check failed
	at java.base/sun.security.validator.PKIXValidator.doValidate(PKIXValidator.java:369)
	at java.base/sun.security.validator.PKIXValidator.engineValidate(PKIXValidator.java:263)
	at java.base/sun.security.validator.Validator.validate(Validator.java:264)
	at java.base/sun.security.ssl.X509TrustManagerImpl.validate(X509TrustManagerImpl.java:313)
	at java.base/sun.security.ssl.X509TrustManagerImpl.checkTrusted(X509TrustManagerImpl.java:222)
	at java.base/sun.security.ssl.X509TrustManagerImpl.checkServerTrusted(X509TrustManagerImpl.java:129)
	at org.apache.zookeeper.common.ZKTrustManager.checkServerTrusted(ZKTrustManager.java:80)
	at java.base/sun.security.ssl.CertificateMessage$T12CertificateConsumer.checkServerCerts(CertificateMessage.java:638)
	... 16 more
Caused by: java.security.cert.CertPathValidatorException: signature check failed
	at java.base/sun.security.provider.certpath.PKIXMasterCertPathValidator.validate(PKIXMasterCertPathValidator.java:135)
	at java.base/sun.security.provider.certpath.PKIXCertPathValidator.validate(PKIXCertPathValidator.java:224)
	at java.base/sun.security.provider.certpath.PKIXCertPathValidator.validate(PKIXCertPathValidator.java:144)
	at java.base/sun.security.provider.certpath.PKIXCertPathValidator.engineValidate(PKIXCertPathValidator.java:83)
	at java.base/java.security.cert.CertPathValidator.validate(CertPathValidator.java:309)
	at java.base/sun.security.validator.PKIXValidator.doValidate(PKIXValidator.java:364)
	... 23 more
Caused by: java.security.SignatureException: Signature does not match.
	at java.base/sun.security.x509.X509CertImpl.verify(X509CertImpl.java:422)
	at java.base/sun.security.provider.certpath.BasicChecker.verifySignature(BasicChecker.java:166)
	at java.base/sun.security.provider.certpath.BasicChecker.check(BasicChecker.java:147)
	at java.base/sun.security.provider.certpath.PKIXMasterCertPathValidator.validate(PKIXMasterCertPathValidator.java:125)
	... 28 more
```

The following occurs in Zookeeper pod logs ...

```
[ERROR] 2021-07-13 15:23:29,091 [nioEventLoopGroup-7-2] org.apache.zookeeper.server.NettyServerCnxnFactory operationComplete - Unsuccessful handshake with session 0x0
[ERROR] 2021-07-13 15:23:39,091 [nioEventLoopGroup-7-1] org.apache.zookeeper.server.NettyServerCnxnFactory operationComplete - Unsuccessful handshake with session 0x0
[ERROR] 2021-07-13 15:23:49,091 [nioEventLoopGroup-7-2] org.apache.zookeeper.server.NettyServerCnxnFactory operationComplete - Unsuccessful handshake with session 0x0
[ERROR] 2021-07-13 15:23:59,090 [nioEventLoopGroup-7-1] org.apache.zookeeper.server.NettyServerCnxnFactory operationComplete - Unsuccessful handshake with session 0x0
```

The following occurs in Kafka pod logs ...

```
[ERROR] 2021-07-13 16:00:35,474 [nioEventLoopGroup-2-1] org.apache.zookeeper.common.ZKTrustManager performHostVerification - Failed to verify host address: 10.124.3.12
javax.net.ssl.SSLPeerUnverifiedException: Certificate for <10.124.3.12> doesn't match any of the subject alternative names: [zookeeper, *.zookeeper.confluent.svc.cluster.local]
	at org.apache.zookeeper.common.ZKHostnameVerifier.matchIPAddress(ZKHostnameVerifier.java:194)
	at org.apache.zookeeper.common.ZKHostnameVerifier.verify(ZKHostnameVerifier.java:164)
	...
```