

k apply -f '/Users/mosheblumberg/kafkaexample/gits/moshe-examples/confluent-kubernetes-examples/connector/http-sink-connector/nodejs.yaml'
k apply -f '/Users/mosheblumberg/kafkaexample/gits/moshe-examples/confluent-kubernetes-examples/connector/http-sink-connector/confluent-platform.yaml'

 k apply -f '/Users/mosheblumberg/kafkaexample/gits/moshe-examples/confluent-kubernetes-examples/connector/http-sink-connector/producer-app-data.yaml'

k apply -f '/Users/mosheblumberg/kafkaexample/gits/moshe-examples/confluent-kubernetes-examples/connector/http-sink-connector/httpsinkconnector.yaml'


curl -X POST -H "Content-Type: application/json" -d '{"name" :"Don Draper"}' http://localhost:80/messages 
curl  http://localhost:80/messagesfromtopic         


curl -X POST -H "Content-Type: application/json" -d '{"name" :"Don Draper"}' http://localhost/messages 
curl  http://localhost/messagesfromtopic         