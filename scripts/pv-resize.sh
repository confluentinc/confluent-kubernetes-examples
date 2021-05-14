#!/usr/bin/env bash
set -C -e -o pipefail
##
## Runs this script if manual resize of PV is required.
##
## This script uses platform.confluent.io/block-reconcile annotation to
## disable the reconcile during the PV resizing.
##
## We can only expand PVC/PV if it's storage class's allowVolumeExpansion field is set to true.
## Only PVCs created from that class are allow to expand.
##
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
  local NEW_SIZE=$4
  local suffix="Gi"
  if [ -f "${CLUSTER_NAME}"-sts.yaml ]; then
     die "${CLUSTER_NAME}-sts.yaml exist, please delete by running rm -f ${CLUSTER_NAME}-sts.yaml"
  fi
  # always run clean_up if an error occurs
  # shellcheck disable=SC2064
  trap "cleanup $CLUSTER_TYPE $CLUSTER_NAME $NAMESPACE" ERR SIGINT INT
  echo "${green}#### Add block reconcile annotation ####${reset}"
  kubectl annotate "${CLUSTER_TYPE}" -n "${NAMESPACE}" --overwrite "${CLUSTER_NAME}" platform.confluent.io/block-reconcile=true
  kubectl get sts "${CLUSTER_NAME}" -n "${NAMESPACE}" -o yaml > "${CLUSTER_NAME}"-sts.yaml
  updated=false
  for POD in $(kubectl get pod -n "${NAMESPACE}" -l app="${CLUSTER_NAME}" | grep "$CLUSTER_NAME" | awk '{print $1}'); do
    PVC=$(kubectl get pod "${POD}" -n "${NAMESPACE}" -ojsonpath={.spec.volumes[0].persistentVolumeClaim.claimName})
    current_capacity=$(kubectl get pvc "${PVC}" -n "${NAMESPACE}" -ojsonpath={.status.capacity.storage})
    INT_NEW_SIZE=${NEW_SIZE%"$suffix"}
    INT_current_capacity=${current_capacity%"$suffix"}

    if [[ "$INT_NEW_SIZE" -gt "$INT_current_capacity" ]]; then
      echo "${green}#########################"
      echo "#### PVC: ${PVC}"
      echo "#### Current Size: ${current_capacity}"
      echo "#### New Size: ${NEW_SIZE}"
      echo "#### Used by: ${POD}"
      echo "#########################"
      read -p "Press enter to continue${reset}"
      # flag to indicate to update the CR with new size
      updated=true
      # deleting this sts allows the pods to be selectively deleted
      kubectl delete sts "${CLUSTER_NAME}" --cascade=false -n "$NAMESPACE"
      kubectl patch pvc  "$PVC" -n "${NAMESPACE}" --patch "{\"spec\": {\"resources\": {\"requests\": {\"storage\": \"${NEW_SIZE}\"}}}}"

      echo "${green}#### Deleting Pod: ${POD}${reset}"
      kubectl delete po "${POD}" -n "$NAMESPACE" --wait
      echo "${green}#### Delete of Pod: ${POD}, complete${reset}"

      # Resize can take 2-3 tries 2 mins apart while resizing
      echo "${green}#### Waiting for PVC resize: ${PVC}${reset}"
      kubectl wait --for=condition=FileSystemResizePending pvc/"${PVC}" -n "${NAMESPACE}" --timeout=30m
      # Creating the sts puts the pod back and reattached the pvc
      kubectl create -f "${CLUSTER_NAME}"-sts.yaml -n "${NAMESPACE}"
      # This wait isn't strictly necessary as the rolling operator on the next \
      #   pod in the queue would prevent issues.
      echo "${green} #### Waiting for Pod to start: ${POD}${reset}"
      kubectl wait --for=condition=ready pod/${POD} -n "${NAMESPACE}" --timeout=30m
      else
        echo "${green}#### PVC: ${PVC} is already size: ${NEW_SIZE}${reset}"
    fi
  done

  if [[ "$updated" = true ]]; then
     kubectl patch "${CLUSTER_TYPE}s.platform.confluent.io" "$CLUSTER_NAME" --type=json -p "[{\"op\": \"replace\", \"path\": \"/spec/dataVolumeCapacity\", \"value\": ${NEW_SIZE} }]"
     # doesn't takes consideration for zookeeper log volume, if required change accordingly
  fi

  cleanup "$CLUSTER_TYPE" "$CLUSTER_NAME" "$NAMESPACE"
}

components_types=(kafka ksqldb controlcenter zookeeper)
usage() {
    echo "usage: ./pv-resize.sh -c <cluster-name> -t <cluster-type> -n <namespace> -s <size_in_Gi>"
    echo "   ";
    echo "  -c | --cluster-name    : name of the cluster to resize the PV";
    echo "  -t | --cluster-type    : confluent platform component, supported value: ${components_types[*]}";
    echo "  -n | --namespace       : kubernetes namespace where cluster is running";
    echo "  -s | --size            : new PV size in Gi";
    echo "  -h | --help            : Usage command";
}

parse_args() {
    args=()
    while [[ "$1" != "" ]]; do
        case "$1" in
            -t | --type )             type="${2}";          shift;;
            -c | --name )             name="${2}";          shift;;
            -n | --namespace )        namespace="${2}";     shift;;
            -s | --size)              size="${2}";          shift;;
            -h | --help )             help="true";          ;;
            *)                        args+=("$1")
        esac
        shift
    done

    set -- "${args[@]}"
    if [[ ! -z ${help} ]]; then usage; exit 1; fi
    if [[ -z ${name} ]]; then usage; die "==> Please provide cluster name to resize the PV"; fi
    if [[ -z ${type} ]]; then usage; die "==> Please provide cluster type, supported value: ${components_types[*]}"; fi
    if [[ ! "${components_types[*]}" =~ ${type} ]]; then die "Please provide cluster type, supported value: ${components_types[*]}"; fi
    if [[ -z ${namespace} ]]; then usage; die "==> Please provide namespace where cluster is running"; fi
    if [[ -z ${size} ]]; then usage; die "==> Please provide PV size in Gi"; fi
    if [[ $size != *Gi ]]; then  die "==> Make sure the size comes wit suffix Gi"; fi

    resize "${type}" "${name}" "${namespace}" "${size}"
}

parse_args "$@";

