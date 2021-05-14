# Scripts

## Manual Persistent Volume Resize

```bash
./pv-resize.sh -h
usage: ./pv-resize.sh -c <cluster-name> -t <cluster-type> -n <namespace> -s <size_in_Gi>
   
  -c | --cluster-name    : name of the cluster to resize the PV
  -t | --cluster-type    : confluent platform type, supported value: kafka ksqldb controlcenter zookeeper
  -n | --namespace       : kubernetes namespace where cluster is running
  -s | --size            : new PV size in Gi
  -h | --help            : Usage command
```

## Recycle Statefulset 

```bash
usage: ./sts-recreate.sh -c <cluster-name> -t <cluster-type> -n <namespace>

  -c | --cluster-name    : name of the cluster to recycle statefulset
  -t | --cluster-type    : confluent platform type, supported value: kafka ksqldb controlcenter zookeeper schemaregistry connect
  -n | --namespace       : kubernetes namespace where cluster is running
  -h | --help            : Usage command
```

## Create keystore.jks
```bash
./create-keystore.sh
Usage: ./create-keystore.sh <fullchain_pem_file> <private_key> <jks_password>
```

## Create truststore.jks
```bash
./create-truststore.sh
Usage: ./create-truststore.sh <CA_pem_file_to_add_in_truststore or Fullchain_pem_file> and <jksPassword>
        CA_pem_file_to_add_in_truststore: CA certificate
        Fullchain_pem_file: Includes CA & Certificate of server or client to trust
```

