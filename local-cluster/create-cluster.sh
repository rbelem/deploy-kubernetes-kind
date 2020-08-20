#!/usr/bin/env bash
set -e

LIGHT_GREEN='\033[1;32m'
LIGHT_RED='\033[1;31m'
NC='\033[0m'   # No Color
KIND_CFG="./kind-cfg.yaml"   # base config file

git co $KIND_CFG

# TODO: default to 1 control plane and 2 workers and log out that is what it is doing
# TODO: move this to node so is easier check exceptions https://nodejs.org/api/child_process.html#child_process_child_process_exec_command_options_callback
# acctyally now that I think about it this is a good test case for pulumi
#  https://www.pulumi.com/docs/guides/adopting/from_kubernetes/#deploying-a-single-kubernetes-yaml-file
if [[ -z "$1" ]]; then
  printf "\nAt least no. of K8s nodes must be set. \nUse ${LIGHT_GREEN}\"bash $0 --help\"${NC} for details.\n"
  exit 1
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --nodes=*|-n=*)
      if [[ "$1" != *=[1-9] ]] && [[ "$1" != *=[1-9][1-9] ]]; then
        printf "\nNo. of K8s nodes must be: ${LIGHT_GREEN}1-99${NC}.\n"
        exit 1
      fi
      NO_NODES="${1#*=}"
      ;;
    --all-labelled=*|-al=*)
      NODE_LABEL="${1#*=}"
      COEFFICIENT_LABEL=1
      ;;
    --half-labelled=*|-hl=*)
      NODE_LABEL="${1#*=}"
      COEFFICIENT_LABEL=0.5
      ;;
    --all-tainted=*|-at=*|--all-tainted|-at)
      if [[ "$1" == *=* ]]; then NODE_TAINT_LABEL="${1#*=}"; fi
      COEFFICIENT_TAINT=1
      ;;
    --half-tainted=*|-ht=*|--half-tainted|-ht)
      if [[ "$1" == *=* ]]; then NODE_TAINT_LABEL="${1#*=}"; fi
      COEFFICIENT_TAINT=0.5
      ;;
    --k8s_ver=*|-v=*)
      if [[ "$1" != *=1.*.* ]]; then
        printf "\nIncompatible K8s node ver.\nCorrect syntax/version: ${LIGHT_GREEN}1.[x].[x]${NC}\n"
        exit 2
      fi
      K8S_VER="${1#*=}"
      ;;
    --reset|-r)
      if [[ -f "${KIND_CFG}.backup" ]]; then
        yes | mv "${KIND_CFG}.backup" "${KIND_CFG}"
        printf "\nReset: ${LIGHT_GREEN}OK${NC}.\n"
        exit 0
      else
        printf "\nSkipping reset - ${LIGHT_GREEN}no old temporary configuration${NC}.\n"
        exit 0
      fi
      ;;
    --help|-h)
      printf "\nUsage:\n    ${LIGHT_GREEN}--k8s_ver,-v${NC}         Set K8s version to be deployed.\n    ${LIGHT_GREEN}--nodes,-n${NC}           Set number of K8s nodes to be created.\n    ${LIGHT_GREEN}--all-labelled,-al${NC}   Set labels on all K8s nodes.\n    ${LIGHT_GREEN}--half-labelled,-hl${NC}  Set labels on half K8s nodes.\n    ${LIGHT_GREEN}--all-tainted,-at${NC}    Set taints on all K8s nodes. A different label can be defined.\n    ${LIGHT_GREEN}--half-tainted,-ht${NC}   Set taints on half K8s nodes. A different label can be defined.\n    ${LIGHT_GREEN}--reset,-r${NC}           Resets any old temporary configuration.\n    ${LIGHT_GREEN}--help,-h${NC}            Prints this message.\nExample:\n    ${LIGHT_GREEN}bash $0 -n=2 -v=1.18.2 -hl='nodeType=devops' -ht ${NC}\n" # Flag argument
      exit 0
      ;;
    *)
      >&2 printf "\nError: ${LIGHT_GREEN}Invalid argument${NC}\n"
      exit 3
      ;;
  esac
  shift
done

if [[ -z "$K8S_VER" ]]; then
  KIND_CTRL_CFG=$'\n  - role: control-plane\n    extraMounts:\n      - hostPath: /var/run/docker.sock\n        containerPath: /var/run/docker.sock'
  KIND_WRKR_CFG=$'\n  - role: worker\n    extraMounts:\n      - hostPath: /var/run/docker.sock\n        containerPath: /var/run/docker.sock'
else
  KIND_CTRL_CFG=$'\n  - role: control-plane\n    image: kindest/node:v'"${K8S_VER}"$'\n    extraMounts:\n      - hostPath: /var/run/docker.sock\n        containerPath: /var/run/docker.sock'
  KIND_WRKR_CFG=$'\n  - role: worker\n    image: kindest/node:v'"${K8S_VER}"$'\n    extraMounts:\n      - hostPath: /var/run/docker.sock\n        containerPath: /var/run/docker.sock'
fi

# Adjust the kINd config
cp "${KIND_CFG}"{,.backup}
if [ "${NO_NODES}" == 1 ]; then
  NO_NODES_CREATE="$((${NO_NODES} - 1))"
else
  NO_NODES_CREATE="${NO_NODES}"
fi
echo -e "${KIND_CTRL_CFG}" >> "${KIND_CFG}"
for (( i=0; i<"${NO_NODES_CREATE}"; ++i));
  do
    echo -e "${KIND_WRKR_CFG}" >> "${KIND_CFG}"
  done

# Create kINd cluster
# using retain because I want to be able to debug if cluster creation fails
kind create cluster --retain --config "${KIND_CFG}" --name kind-"${NO_NODES}" 

# Revert the kINd config
yes | mv "${KIND_CFG}.backup" "${KIND_CFG}"

# Deploy desired svc-s
helmfile -f ./helmfile.yaml apply > /dev/null

# Admin setup

kubectl apply -f dashboard-admin-rbac.yaml


# https://codelearn.me/2019/01/13/wsl-windows-toast.html
# https://github.com/microsoft/WSL/issues/2466#issuecomment-662184581
if grep -q Microsoft /proc/version; then
 powershell.exe 'New-BurntToastNotification -Text "k8s cluster is up!" -Sound "Default" -SnoozeAndDismiss'
fi

# Get node names
CLUSTER_WRKS=$(kubectl get nodes | tail -n +2 | cut -d' ' -f1)
IFS=$'\n' CLUSTER_WRKS=(${CLUSTER_WRKS})

# Put node labels
if [[ ! -z "$COEFFICIENT_LABEL" ]]; then
  NO_NODES_LABELLED="$(bc -l <<<"${#CLUSTER_WRKS[@]} * $COEFFICIENT_LABEL" | awk '{printf("%d\n",$1 - 0.5)}')"
  for ((i=1;i<="$NO_NODES_LABELLED";i++));
    do
      kubectl label node "${CLUSTER_WRKS[i]}" "$NODE_LABEL"
    done
fi

# Taint the nodes with "NoExecute"
if [[ ! -z "$COEFFICIENT_TAINT" ]]; then
  NO_NODES_TAINTED="$(bc -l <<<"${#CLUSTER_WRKS[@]} * $COEFFICIENT_TAINT" | awk '{printf("%d\n",$1 - 0.5)}')"
  for ((i=1;i<="$NO_NODES_TAINTED";i++));
    do
      if [[ ! -z "$NODE_LABEL" ]] && [[ -z "$NODE_TAINT_LABEL" ]] ; then
        kubectl taint node "${CLUSTER_WRKS[i]}" "$NODE_LABEL":NoExecute
      else
        kubectl taint node "${CLUSTER_WRKS[i]}" "$NODE_TAINT_LABEL":NoExecute
      fi
    done
fi
