#! /bin/bash

# Podman networks. These are lab infrastructure and must already exist; the
# scripts only consume them.
DEFAULT_CRI_NET_NAME="default-network" # libvirt default network (192.168.122.0/24)
NET1_CRI_NET_NAME="net1-ext"           # net1 exposed to podman (10.200.0.0/16)
# Third attachment (net2 / eth2). The router's address here (e.g.
# 192.169.1.26) is the external client's default gateway.
EXT_NET_CRI_NET_NAME="my-isolated-network"
EXT_NET_CRI_CIDR="192.169.1.0/24"

# Node underlay: the CNI device is a macvlan on top of ens4 (net1).
NET1_NODE_NIC="ens4"
UNDERLAY_IFACE_NAME="net1" # interface name inside the router netns
UNDERLAY_PREFIX="16"
# The external router's net1-ext address is discovered at setup time (podman
# inspect) and used as the BGP neighbor.

# Cluster nodes. These defaults match the reference lab; override them with
# --node0/--node1 or the NODE0/NODE1 environment variables.
DEFAULT_NODE0="multi-homing-worker-0.maiqueb.org"
DEFAULT_NODE1="multi-homing-worker-1.maiqueb.org"
NODE0="${NODE0:-$DEFAULT_NODE0}"
NODE1="${NODE1:-$DEFAULT_NODE1}"
NODE0_HOSTNAME="${NODE0_HOSTNAME:-${NODE0%%.*}}"
NODE1_HOSTNAME="${NODE1_HOSTNAME:-${NODE1%%.*}}"

NET1_MVLN_NODE0_IP="10.200.11.50"
NET1_MVLN_NODE1_IP="10.200.11.51"

# ASNs
CLUSTER_NET_ASN=64514
EXT_NET_ASN=64512

# Stretched network
EXT_NET_VRF="red"
EXT_NET_L3VNI=100
EXT_NET_L2VNI=110
EXT_NET_L2VNI_GW_CIDR="192.170.1.1/24"

# Bridge used for connecting VMs to EVPN
VNI_BR_NNCP_NAME="linux-bridge-perouter-vni-110"
VNI_BR_NAD_NAME="evpn-l2vni-110"
L2VNI_BRIDGE="brvni110"

# External client container
EXT_APP_NAME="external-client"
EXT_APP_IMG="registry.k8s.io/e2e-test-images/agnhost:2.45"

SCRIPT_PATH=$(dirname "$(realpath "$0")")
DIR=$(dirname $SCRIPT_PATH)
REPO_ROOT=$(dirname $DIR)

# External router container
EXT_FRR_NAME="frr"
EXT_FRR_IMG="frr-router"
FRR_CONFIG="${REPO_ROOT}/external-router"
EXT_FRR_NET1_NIC="eth1" # net1-ext interface; stays in the default VRF

# Templates and manifests
TMPL_DIR="${DIR}/templates"

NNCP_VNI_BR_TEMPLATE="${TMPL_DIR}/vni-linux-bridge-nncp.yaml"
NNCP_VNI_BR_MANIFEST="${DIR}/00-vni-linux-bridge-nncp.yaml"

NAD_VNI_BR_TEMPLATE="${TMPL_DIR}/vni-linux-bridge-nad.yaml"
NAD_VNI_BR_MANIFEST="${DIR}/03-vni-linux-bridge-nad.yaml"

UNDERLAY_TEMPLATE="${TMPL_DIR}/openperouter-underlay.yaml"
UNDERLAY_MANIFEST="${DIR}/01-openperouter-underlay.yaml"

VNIS_TEMPLATE="${TMPL_DIR}/openperouter-vnis.yaml"
VNIS_MANIFEST="${DIR}/02-openperouter-vnis.yaml"

WORKLOADS_TEMPLATE="${TMPL_DIR}/workloads.yaml"
WORKLOADS_MANIFEST="${DIR}/04-workloads.yaml"

# OpenPERouter system namespace
NAMESPACE="openshift-openperouter"

# Tests namespace
TEST_NS="test-evpn-linux-bridge"

# VMs
VM1_NAME="vm1"
VM1_IP="192.170.1.3/24"
VM2_NAME="vm2"
VM2_IP="192.170.1.5/24"
VMS_GW="192.170.1.1"
VMS_PUBLIC_KEY="$(realpath ~/.ssh/kcli.pub)"
VMS_KEY="$(realpath ~/.ssh/kcli)"

# Aggregated entities for teardown
CONTAINERS=($EXT_FRR_NAME $EXT_APP_NAME)

# Parse harness options shared by the scripts. Unknown options are left in
# REMAINING_ARGS so each script can handle its own flags.
parse_harness_args() {
  REMAINING_ARGS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --node0)
        [[ $# -ge 2 ]] || { echo "missing value for --node0" >&2; exit 1; }
        NODE0="$2"; shift 2 ;;
      --node1)
        [[ $# -ge 2 ]] || { echo "missing value for --node1" >&2; exit 1; }
        NODE1="$2"; shift 2 ;;
      *)
        REMAINING_ARGS+=("$1"); shift ;;
    esac
  done
  NODE0_HOSTNAME="${NODE0%%.*}"
  NODE1_HOSTNAME="${NODE1%%.*}"
}
