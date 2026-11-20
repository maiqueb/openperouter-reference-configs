#! /bin/bash

set -e

SCRIPT_PATH=$(dirname "$(realpath "$0")")
DIR=$(dirname $SCRIPT_PATH)
source $SCRIPT_PATH/env.sh

parse_harness_args "$@"
RESTART_VMS=false
for arg in "${REMAINING_ARGS[@]}"; do
  case "$arg" in
    --restart-vms) RESTART_VMS=true ;;
    *) echo "FATAL: unknown argument [$arg]" >&2; exit 1 ;;
  esac
done

echo "INFO: Generate NAD manifests:"
(
  export VNI_BR_NAD_NAME=$VNI_BR_NAD_NAME \
    L2VNI_BRIDGE=$L2VNI_BRIDGE
  echo "\
    VM1VNI_BR_NAD_NAME_NAME=$VNI_BR_NAD_NAME
    L2VNI_BRIDGE=$L2VNI_BRIDGE"
  envsubst <<< $(cat $NAD_VNI_BR_TEMPLATE) > $NAD_VNI_BR_MANIFEST
)
echo "INFO: Generate VM manifests:"
(
  export VM1_NAME=$VM1_NAME \
    VM1_IP=$VM1_IP \
    VM2_NAME=$VM2_NAME \
    VM2_IP=$VM2_IP \
    VMS_GW=$VMS_GW \
    SSH_PUBLIC_KEY="$(base64 $VMS_PUBLIC_KEY -w 500)" \
    EXT_NET_CRI_CIDR=$EXT_NET_CRI_CIDR \
    VNI_BR_NAD_NAME=$VNI_BR_NAD_NAME
  echo "\
    VM1_NAME=$VM1_NAME
    VM1_IP=$VM1_IP
    VM2_NAME=$VM2_NAME
    VM2_IP=$VM2_IP
    VMS_GW=$VMS_GW
    SSH_PUBLIC_KEY=$SSH_PUBLIC_KEY
    VNI_BR_NAD_NAME=$VNI_BR_NAD_NAME"
  envsubst <<< $(cat $WORKLOADS_TEMPLATE) > $WORKLOADS_MANIFEST
)

echo "INFO: Create test namespace"
oc create ns $TEST_NS ||:
echo "INFO: Create linux-bridge NAD"
oc -n $TEST_NS apply -f $NAD_VNI_BR_MANIFEST
echo "INFO: Create test workloads"
oc -n $TEST_NS apply -f $WORKLOADS_MANIFEST

# restart VMs to ensure NAD changes take effect
if $RESTART_VMS; then
  echo "INFO: Restarting VMs"
  virtctl -n $TEST_NS restart $VM1_NAME
  virtctl -n $TEST_NS restart $VM2_NAME
fi

echo "INFO: Waiting for VM readiness"
oc -n $TEST_NS wait vm/$VM1_NAME --for condition=Ready --timeout 10m
oc -n $TEST_NS wait vm/$VM2_NAME --for condition=Ready --timeout 10m
echo "INFO: Waiting for guest readiness"
oc -n $TEST_NS wait vmi/$VM1_NAME --for condition=AgentConnected --timeout 10m
oc -n $TEST_NS wait vmi/$VM2_NAME --for condition=AgentConnected --timeout 10m

# its safe to expect for single IP address because VM is connected to single network
VM1_IP=$(oc -n $TEST_NS get vmi $VM1_NAME -o jsonpath='{.status.interfaces[1].ipAddress}')
VM2_IP=$(oc -n $TEST_NS get vmi $VM2_NAME -o jsonpath='{.status.interfaces[1].ipAddress}')
EXT_CLIENT_IP=$(podman inspect -f '{{(index .NetworkSettings.Networks "'"$EXT_NET_CRI_NET_NAME"'").IPAddress}}' $EXT_APP_NAME)
EXT_FRR_CLIENT_IP=$(podman inspect -f '{{(index .NetworkSettings.Networks "'"$EXT_NET_CRI_NET_NAME"'").IPAddress}}' $EXT_FRR_NAME)

echo ""
echo ""

ssh_args="--identity-file=$VMS_KEY --local-ssh-opts='-o StrictHostKeyChecking=no' --local-ssh-opts='-o UserKnownHostsFile=/dev/null'"
{
  echo "## Test: VM to VM connectivity"
  echo "### Test: connectivity from vm [$VM1_NAME] to vm [$VM2_NAME][$VM2_IP]"
  eval "virtctl -n $TEST_NS ssh fedora@vm/$VM1_NAME $ssh_args -c \"ping -I eth1 -c 3 -W 2 $VM2_IP\"" || \
    echo "  FAIL: no connectivity from [$VM1_NAME] to [$VM2_NAME][$VM2_IP]"
  echo ""
  echo ""
  echo "### Test: connectivity from vm [$VM2_NAME] to vm [$VM1_NAME][$VM1_IP]"
  eval "virtctl -n $TEST_NS ssh fedora@vm/$VM2_NAME $ssh_args -c \"ping -I eth1 -c 3 -W 2 $VM1_IP\"" || \
    echo "  FAIL: no connectivity from [$VM2_NAME] to [$VM1_NAME][$VM2_IP]"
  echo ""
  echo ""
  echo "## Test: VM to external-router connectivity"
  echo "### Test: connectivity from VM [$VM1_NAME] to external-router [$EXT_FRR_NAME][vrf $EXT_NET_VRF][$EXT_FRR_CLIENT_IP]"
  eval "virtctl -n $TEST_NS ssh fedora@vm/$VM1_NAME $ssh_args -c \"ping -I eth1 -c 3 -W 2 $EXT_FRR_CLIENT_IP\"" || \
    echo "  FAIL: no connectivity from VM [$VM1_NAME][$VM1_IP] to external-router [$EXT_FRR_NAME][vrf $EXT_NET_VRF][$EXT_FRR_CLIENT_IP]"
  echo ""
  echo ""
  echo "### Test: connectivity from external-router [$EXT_FRR_NAME][vrf $EXT_NET_VRF] to VM [$VM1_NAME][$VM1_IP]"
  podman exec $EXT_FRR_NAME ip vrf exec $EXT_NET_VRF ping -c 3 -W 2 $VM1_IP || \
    echo "  FAIL: no connectivity from external-router [$EXT_FRR_NAME][vrf $EXT_NET_VRF] to [$VM1_NAME][$VM1_IP]"
  echo ""
  echo ""
  echo "### Test: connectivity from VM [$VM2_NAME] to external-router [$EXT_FRR_NAME][vrf $EXT_NET_VRF][$EXT_FRR_CLIENT_IP]"
  eval "virtctl -n $TEST_NS ssh fedora@vm/$VM2_NAME $ssh_args -c \"ping -I eth1 -c 3 -W 2 $EXT_FRR_CLIENT_IP\"" || \
    echo "  FAIL: no connectivity from [$VM2_NAME][$VM2_IP] to external-router [$EXT_FRR_NAME][vrf $EXT_NET_VRF][$EXT_FRR_CLIENT_IP]"
  echo ""
  echo ""
  echo "### Test: connectivity from external-router [$EXT_FRR_NAME][vrf $EXT_NET_VRF] to VM [$VM2_NAME][$VM2_IP]"
  podman exec $EXT_FRR_NAME ip vrf exec $EXT_NET_VRF ping -c 3 -W 2 $VM2_IP || \
    echo "  FAIL: no connectivity from external-router [$EXT_FRR_NAME][vrf $EXT_NET_VRF] to [$VM2_NAME][$VM2_IP]"
  echo ""
  echo ""
  echo "## Test: VM to external-client connectivity"
  echo "### Test: connectivity from vm [$VM1_NAME] to external-client [$EXT_APP_NAME][$EXT_CLIENT_IP]"
  eval "virtctl -n $TEST_NS ssh fedora@vm/$VM1_NAME $ssh_args -c \"ping -I eth1 -c 3 -W 2 $EXT_CLIENT_IP\"" || \
    echo "  FAIL: no connectivity from [$VM1_NAME] to external-client [$EXT_APP_NAME][$EXT_CLIENT_IP]"
  echo ""
  echo ""
  echo "### Test: connectivity from external-client [$EXT_APP_NAME] to VM [$VM1_NAME][$VM1_IP]"
  podman exec $EXT_APP_NAME ping -c 3 -W 2 $VM1_IP || \
    echo "  FAIL: no connectivity from external-client [$EXT_APP_NAME] to VM [$VM1_NAME][$VM1_IP]"
  echo ""
  echo ""
  echo "### Test: connectivity from vm [$VM2_NAME] to external-client [$EXT_APP_NAME][$EXT_CLIENT_IP]"
  eval "virtctl -n $TEST_NS ssh fedora@vm/$VM2_NAME $ssh_args -c \"ping -I eth1 -c 3 -W 2 $EXT_CLIENT_IP\"" || \
    echo "  FAIL: no connectivity from [$VM2_NAME] to external-client [$EXT_APP_NAME][$EXT_CLIENT_IP]"
  echo ""
  echo ""
  echo "### Test: connectivity from external-client [$EXT_APP_NAME] to VM [$VM2_NAME][$VM2_IP]"
  podman exec $EXT_APP_NAME ping -c 3 -W 2 $VM2_IP || \
    echo "  FAIL: no connectivity from external-client [$EXT_APP_NAME] to [$VM2_NAME][$VM2_IP]"
  echo ""
  echo ""
} | tee "${SCRIPT_PATH}/test-result-summary.txt"
