#!/usr/bin/env bash
set -eou pipefail

usage() {
  echo "Usage: $0 [--name <service-account-name>] [--namespace <namespace>] [--kube-output-dir <kube-output-dir>] [--regenerate] [--help]"
  echo "  --name                 The name of the service account to create for an agent."
  echo "  --namespace            The namespace to create the service account into."
  echo "  --kube-output-dir      The path to save kubeconfig file locally."
  echo "  --regenerate           Optional. To regenerate the token."
  echo "  -h, --help             Displays this help message."
}

# default
REGENERATE_TOKEN=false
SA_NAME=""
SA_NAMESPACE=""
KUBE_CONFIG_OUTPUT_PATH=""

while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    --name)
      SA_NAME="$2"
      shift
      shift
      ;;
    --namespace)
      SA_NAMESPACE="$2"
      shift
      shift
      ;;
    --kube-output-dir)
      KUBE_CONFIG_OUTPUT_PATH="$2"
      shift
      shift
      ;;
    --regenerate|-f)
      REGENERATE_TOKEN=true
      shift
      ;;
    -h|--help)
      usage
      exit
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$SA_NAME" || -z "$SA_NAMESPACE" || -z "$KUBE_CONFIG_OUTPUT_PATH" ]]; then
  usage
  exit 1
fi

if [[ "$REGENERATE_TOKEN" = "true" ]]; then
     echo "==> proceeding to regenerate the token."
     REGENERATE_TOKEN=true
fi

if [ ! -d "${KUBE_CONFIG_OUTPUT_PATH}" ]; then
  echo "===> error: ${KUBE_CONFIG_OUTPUT_PATH} does not exist or is not a directory."
  exit 1
fi

secret_file="${KUBE_CONFIG_OUTPUT_PATH}/${SA_NAME}-secret.yaml"
clusterrole_file="${KUBE_CONFIG_OUTPUT_PATH}/clusterrole-${SA_NAME}.yaml"
kubeconfig_file="${KUBE_CONFIG_OUTPUT_PATH}/kubeconfig"

[ -e "${secret_file}" ] && rm  "${secret_file}"
[ -e "${clusterrole_file}" ] && rm  "${clusterrole_file}"
[ -e "${kubeconfig_file}" ] && rm  "${kubeconfig_file}"

# Check if the service account exists
if kubectl -n "${SA_NAMESPACE}" get serviceaccount "${SA_NAME}" >/dev/null 2>&1; then
  # Delete the service account if it exists
   if [[ "${REGENERATE_TOKEN}" = "true" ]]; then
    echo "===> service account ${SA_NAME} in namespace ${SA_NAMESPACE} already exists. deleting..."
    kubectl -n "${SA_NAMESPACE}" delete serviceaccount "${SA_NAME}"
   fi
fi

# Check if the secret exists
if kubectl -n "${SA_NAMESPACE}" get  secret "${SA_NAME}-secret" >/dev/null 2>&1; then
  # Delete the secret if it exists
  if [[ "${REGENERATE_TOKEN}" = "true" ]]; then
    echo "===> secret delete ${SA_NAME} in namespace ${SA_NAMESPACE} already exists. deleting..."
    kubectl -n "${SA_NAMESPACE}" delete secret "${SA_NAME}-secret"
  fi
fi

echo "===> creating service-account ${SA_NAME} in namespace ${SA_NAMESPACE} in the control-plane k8s cluster"
kubectl -n "${SA_NAMESPACE}" create serviceaccount "${SA_NAME}" --save-config --dry-run=client -oyaml | kubectl apply -f -

cat > "${secret_file}" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SA_NAME}-secret
  namespace: ${SA_NAMESPACE}
  annotations:
    kubernetes.io/service-account.name: ${SA_NAME}
type: kubernetes.io/service-account-token
EOF

echo "===> creating secret ${SA_NAME}-secret in namespace ${SA_NAMESPACE} in the control-plane k8s cluster"
kubectl apply -f "${secret_file}"

cat > "${clusterrole_file}" <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${SA_NAME}-clusterrole
rules:
- apiGroups:
  - ""
  resources:
  - configmaps
  - secrets
  verbs:
  - '*'
- apiGroups:
  - platform.confluent.io
  resources:
  - '*'
  verbs:
  - '*'
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
  name: ${SA_NAME}-clusterrolebinding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${SA_NAME}-clusterrole
subjects:
- kind: ServiceAccount
  name: ${SA_NAME}
  namespace: ${SA_NAMESPACE}
EOF

echo "===> creating clusterrole and clusterrolebinding in control-plane k8s cluster"
kubectl apply -f "${clusterrole_file}"

echo "===> generating kubeconfig file, ${kubeconfig_file}, for agent to deploy in multi-site mode."
USER_TOKEN_NAME=$(kubectl -n "${SA_NAMESPACE}" get serviceaccount "${SA_NAME}" -o=jsonpath='{.secrets[0].name}')
if [ -z "${USER_TOKEN_NAME}" ];then
  USER_TOKEN_NAME="${SA_NAME}"-secret
fi
USER_TOKEN_VALUE=$(kubectl -n "${SA_NAMESPACE}" get secret/"${USER_TOKEN_NAME}" -o=go-template='{{.data.token}}' | base64 --decode)
CURRENT_CONTEXT=$(kubectl config current-context)
CURRENT_CLUSTER=$(kubectl config view --raw -o=go-template='{{range .contexts}}{{if eq .name "'''"${CURRENT_CONTEXT}"'''"}}{{ index .context "cluster" }}{{end}}{{end}}')
CLUSTER_CA=$(kubectl config view --raw -o=go-template='{{range .clusters}}{{if eq .name "'''"${CURRENT_CLUSTER}"'''"}}"{{with index .cluster "certificate-authority-data" }}{{.}}{{end}}"{{ end }}{{ end }}')
CLUSTER_SERVER=$(kubectl config view --raw -o=go-template='{{range .clusters}}{{if eq .name "'''"${CURRENT_CLUSTER}"'''"}}{{ .cluster.server }}{{end}}{{ end }}')

cat > "${kubeconfig_file}" <<EOF
apiVersion: v1
kind: Config
current-context: ${CURRENT_CONTEXT}
contexts:
- name: ${CURRENT_CONTEXT}
  context:
    cluster: ${CURRENT_CONTEXT}
    user: ${SA_NAME}
    namespace: ${SA_NAMESPACE}
clusters:
- name: ${CURRENT_CONTEXT}
  cluster:
    certificate-authority-data: ${CLUSTER_CA}
    server: ${CLUSTER_SERVER}
users:
- name: ${SA_NAME}
  user:
    token: ${USER_TOKEN_VALUE}
EOF
