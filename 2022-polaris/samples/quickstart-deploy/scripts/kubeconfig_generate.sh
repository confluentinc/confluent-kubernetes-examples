#!/usr/bin/env bash
set -C -e -o pipefail

NAME=$1
NAMESPACE=$2
CONFIG_OUTPUT_PATH=$3

[ $# -ne 3 ] && { echo "Usage: $0 <serviveaccountname> <namespace> <config_output_path>"; exit 1; }

echo "creating serviceaccount ${NAME} in namespace ${NAMESPACE}"
kubectl -n "${NAMESPACE}" create serviceaccount "${NAME}" --save-config --dry-run=true -oyaml | kubectl apply -f -

cat << EOF > "${CONFIG_OUTPUT_PATH}"/clusterrole-"${NAME}".yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${NAME}-clusterrole
rules:
- apiGroups:
  - ""
  resources:
  - configmaps
  - secrets
  - secrets/finalizers
  verbs:
  - get
  - list
  - watch
  - create
  - update
  - patch
  - delete
- apiGroups:
  - platform.confluent.io
  resources:
  - '*'
  verbs:
  - create
  - delete
  - get
  - list
  - patch
  - update
  - watch
- apiGroups:
  - core.cpc.platform.confluent.io
  resources:
  - cpchealthchecks
  - cpchealthchecks/status
  verbs:
  - get
  - list
  - patch
  - watch
- apiGroups:
  - install.cpc.platform.confluent.io
  resources:
  - cpcagentinstalls
  verbs:
  - get
  - list
  - watch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${NAME}-clusterrolebinding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${NAME}-clusterrole
subjects:
- kind: ServiceAccount
  name: ${NAME}
  namespace: ${NAMESPACE}
EOF

echo "creating clusterrole and clusterrolebinding"
kubectl apply -f "${CONFIG_OUTPUT_PATH}"/clusterrole-${NAME}.yaml

if [ -e "${CONFIG_OUTPUT_PATH}/kubeconfig" ];then
  rm  "${CONFIG_OUTPUT_PATH}/kubeconfig"
fi

echo "generating kubeconfig file"
USER_TOKEN_NAME=$(kubectl -n "${NAMESPACE}" get serviceaccount "${NAME}" -o=jsonpath='{.secrets[0].name}')
USER_TOKEN_VALUE=$(kubectl -n "${NAMESPACE}" get secret/"${USER_TOKEN_NAME}" -o=go-template='{{.data.token}}' | base64 --decode)
CURRENT_CONTEXT=$(kubectl config current-context)
CURRENT_CLUSTER=$(kubectl config view --raw -o=go-template='{{range .contexts}}{{if eq .name "'''${CURRENT_CONTEXT}'''"}}{{ index .context "cluster" }}{{end}}{{end}}')
CLUSTER_CA=$(kubectl config view --raw -o=go-template='{{range .clusters}}{{if eq .name "'''${CURRENT_CLUSTER}'''"}}"{{with index .cluster "certificate-authority-data" }}{{.}}{{end}}"{{ end }}{{ end }}')
CLUSTER_SERVER=$(kubectl config view --raw -o=go-template='{{range .clusters}}{{if eq .name "'''${CURRENT_CLUSTER}'''"}}{{ .cluster.server }}{{end}}{{ end }}')

cat << EOF > "${CONFIG_OUTPUT_PATH}"/kubeconfig
apiVersion: v1
kind: Config
current-context: ${CURRENT_CONTEXT}
contexts:
- name: ${CURRENT_CONTEXT}
  context:
    cluster: ${CURRENT_CONTEXT}
    user: ${NAME}
    namespace: ${NAMESPACE}
clusters:
- name: ${CURRENT_CONTEXT}
  cluster:
    certificate-authority-data: ${CLUSTER_CA}
    server: ${CLUSTER_SERVER}
users:
- name: ${NAME}
  user:
    token: ${USER_TOKEN_VALUE}
EOF



