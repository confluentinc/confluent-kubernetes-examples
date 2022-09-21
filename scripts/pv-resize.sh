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

get_suffix_multiplier() {
  local SUFFIX=$1
  for i in "${!valid_suffixes[@]}"; do
    if [[ "${valid_suffixes[$i]}" = "${SUFFIX}" ]]; then
      let b=${i}+1
      echo ${b};
      return
    fi
  done
  echo 1
}

resize() {
  local CLUSTER_TYPE=$1
  local CLUSTER_NAME=$2
  local NAMESPACE=$3
  local INT_NEW_SIZE=$4
  local NEW_SIZE_SUFFIX=$5

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

    INT_current_capacity=( $(grep -Eo '^[0-9]+\.?[0-9]*' <<< "${current_capacity}") )
    INT_current_capacity_suffix="${current_capacity#"${INT_current_capacity}"}"
    current_multiplier=$(get_suffix_multiplier ${INT_current_capacity_suffix})
    RAW_current_size=`bc -l <<< "${INT_current_capacity} * 1024^${current_multiplier}"`

    new_mulitplier=$(get_suffix_multiplier ${NEW_SIZE_SUFFIX})
    RAW_new_size=`bc -l <<<  "${INT_NEW_SIZE} * 1024^${new_mulitplier}"`
    expand=`bc -l <<< "${RAW_new_size} > ${RAW_current_size}"`

    if [ ${expand} -eq "1" ]; then
      NEW_SIZE="${INT_NEW_SIZE}${NEW_SIZE_SUFFIX}"
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
      echo "${green}#### PVC: ${PVC} is already size: ${current_capacity}${reset}. This script is only for disk expansion."
    fi
  done

  if [[ "$updated" = true ]]; then
     kubectl patch "${CLUSTER_TYPE}s.platform.confluent.io" "$CLUSTER_NAME" --type=json -p "[{\"op\": \"replace\", \"path\": \"/spec/dataVolumeCapacity\", \"value\": ${NEW_SIZE} }]"
     # doesn't takes consideration for zookeeper log volume, if required change accordingly
  fi

  cleanup "$CLUSTER_TYPE" "$CLUSTER_NAME" "$NAMESPACE"
}

components_types=(kafka ksqldb controlcenter zookeeper)
valid_suffixes=("Ki" "Mi" "Gi" "Ti")
usage() {
    echo "usage: ./pv-resize.sh -c <cluster-name> -t <cluster-type> -n <namespace> -s <size_with_unit>"
    echo "   ";
    echo "  -c | --cluster-name    : name of the cluster to resize the PV";
    echo "  -t | --cluster-type    : confluent platform component, supported value: ${components_types[*]}";
    echo "  -n | --namespace       : kubernetes namespace where cluster is running";
    echo "  -s | --size            : new PV size in Ki|Mi|Gi|Ti";
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

    local SUFFIXES_STRING=`printf '%s\n' "$(IFS=\|; printf '%s' "${valid_suffixes[*]}")"`

    set -- "${args[@]}"
    if [[ ! -z ${help} ]]; then usage; exit 1; fi
    if [[ -z ${name} ]]; then usage; die "==> Please provide cluster name to resize the PV"; fi
    if [[ -z ${type} ]]; then usage; die "==> Please provide cluster type, supported value: ${components_types[*]}"; fi
    if [[ ! "${components_types[*]}" =~ ${type} ]]; then die "Please provide cluster type, supported value: ${components_types[*]}"; fi
    if [[ -z ${namespace} ]]; then usage; die "==> Please provide namespace where cluster is running"; fi
    if [[ -z ${size} ]]; then usage; die "==> Please provide PV size in ${SUFFIXES_STRING}"; fi

    local NEW_SIZE_VALUE=( $(grep -Eo '^[0-9]+' <<< "${size}") )
    #decimal todo
    local NEW_SIZE_SUFFIX="${size#"${NEW_SIZE_VALUE}"}"
    if [ -z "${NEW_SIZE_VALUE}" ] || [ "${NEW_SIZE_VALUE}" == "0" ]
    then
      # do not allow decimals https://github.com/kubernetes/kubernetes/pull/100100
      die "new size with unit parameter is not properly formatted. No decimals allowed"
    fi

    local in=1
    for element in "${valid_suffixes[@]}"; do
      if [[ $element == "${NEW_SIZE_SUFFIX}" ]]; then
        in=0
        break
      fi
    done
    if [[ ${in} -eq 1 ]];
    then
      die "new size with unit parameter should not have decimals or is not properly formatted with units ${SUFFIXES_STRING}"
    fi

    resize "${type}" "${name}" "${namespace}" "${NEW_SIZE_VALUE}" "${NEW_SIZE_SUFFIX}"
}

parse_args "$@";

