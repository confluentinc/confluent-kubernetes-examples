#!/usr/bin/env bash
set -C -e -o pipefail
##
## Only run this script if you want to recreate the statefulset: to deal with forbidden issues,
## revision problems, etc
## This script deletes the statefuset with cascading false (orphaning the pods) and forces
## the operator to recreate the statefulset once all the pods are recycled.
##

red=$(tput setaf 1)
green=$(tput setaf 2)
reset=$(tput sgr0)

die() {
    echo "${red}$*${reset}"
    exit 1
}

cleanup() {
  local CLUSTER_TYPE=$1
  local CLUSTER_NAME=$2
  local NAMESPACE=$3
	kubectl -n "${NAMESPACE}"  annotate "${CLUSTER_TYPE}s.platform.confluent.io" --overwrite  "${CLUSTER_NAME}" platform.confluent.io/block-reconcile-
	echo "${green}#### Removed block reconcile annotation ####${reset}"
}

resize() {
  local CLUSTER_TYPE=$1
  local CLUSTER_NAME=$2
  local NAMESPACE=$3
  if [ -f "${CLUSTER_NAME}"-sts.yaml ]; then
     die "${CLUSTER_NAME}-sts.yaml exist, please delete by running rm -f ${CLUSTER_NAME}-sts.yaml"
  fi
  # always run clean_up if an error occurs
  # shellcheck disable=SC2064
  trap "cleanup $CLUSTER_TYPE $CLUSTER_NAME $NAMESPACE" ERR SIGINT INT
  echo "${green}#### Add block reconcile annotation ####${reset}"
  kubectl annotate "${CLUSTER_TYPE}" -n "${NAMESPACE}" --overwrite "${CLUSTER_NAME}" platform.confluent.io/block-reconcile=true
  kubectl get sts "${CLUSTER_NAME}" -n "${NAMESPACE}" -o yaml > "${CLUSTER_NAME}"-sts.yaml
  for POD in $(kubectl get pod -n "${NAMESPACE}" -l app="${CLUSTER_NAME}" | grep "$CLUSTER_NAME" | awk '{print $1}'); do

      # deleting this sts allows the pods to be selectively deleted
      echo "${green}#### Deleting sts ${CLUSTER_NAME} with cascading false${reset}"
      kubectl delete sts "${CLUSTER_NAME}" --cascade=false -n "$NAMESPACE"
      echo "${green}#### Deleting Pod: ${POD}${reset}"
      kubectl delete po "${POD}" -n "$NAMESPACE" --wait
      echo "${green}#### Delete of Pod: ${POD}, complete${reset}"
      # Creating the sts puts the pod back and reattached the pvc
      kubectl create -f "${CLUSTER_NAME}"-sts.yaml -n "${NAMESPACE}"
      echo "${green} #### Waiting for Pod to start: ${POD}${reset}"
      kubectl wait --for=condition=ready pod/"${POD}" -n "${NAMESPACE}" --timeout=30m
  done

  cleanup "$CLUSTER_TYPE" "$CLUSTER_NAME" "$NAMESPACE"
}

components_types=(kafka ksqldb controlcenter zookeeper schemaregistry connect)
usage() {
    echo "usage: ./sts-recreate.sh -c <cluster-name> -t <cluster-type> -n <namespace>"
    echo "   ";
    echo "  -c | --cluster-name    : name of the cluster to recycle statefulset";
    echo "  -t | --cluster-type    : confluent platform component, supported value: ${components_types[*]}";
    echo "  -n | --namespace       : kubernetes namespace where cluster is running";
    echo "  -h | --help            : Usage command";
}

parse_args() {
    args=()
    while [[ "$1" != "" ]]; do
        case "$1" in
            -t | --type )             type="${2}";          shift;;
            -c | --name )             name="${2}";          shift;;
            -n | --namespace )        namespace="${2}";     shift;;
            -h | --help )             help="true";          ;;
            *)                        args+=("$1")
        esac
        shift
    done

    set -- "${args[@]}"
    if [[ ! -z ${help} ]]; then usage; exit 1; fi
    if [[ -z ${name} ]]; then usage; die "==> Please provide cluster name to recycle statefulset"; fi
    if [[ ! "${components_types[*]}" =~ ${type} ]]; then die "Please provide cluster type, supported value: ${components_types[*]}"; fi
    if [[ -z ${namespace} ]]; then usage; die "==> Please provide namespace where cluster is running"; fi

    resize "${type}" "${name}" "${namespace}"
}

parse_args "$@";
