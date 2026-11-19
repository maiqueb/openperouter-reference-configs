#! /bin/bash

set -e

SCRIPT_PATH=$(dirname "$(realpath "$0")")
source $SCRIPT_PATH/env.sh

parse_harness_args "$@"
if [[ ${#REMAINING_ARGS[@]} -gt 0 ]]; then
  echo "FATAL: unknown arguments: ${REMAINING_ARGS[*]}" >&2
  exit 1
fi

require_podman_network() {
  if ! podman network inspect "$1" >/dev/null 2>&1; then
    echo "FATAL: podman network [$1] not found" >&2
    exit 1
  fi
}

inspect_network_ip() {
  local container="$1" network="$2"
  podman inspect \
    -f "{{(index .NetworkSettings.Networks \"$network\").IPAddress}}" \
    "$container"
}

is_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

for net in "$DEFAULT_CRI_NET_NAME" "$NET1_CRI_NET_NAME" "$EXT_NET_CRI_NET_NAME"; do
  require_podman_network "$net"
done

echo "INFO: Build external-router image [$EXT_FRR_IMG]"
podman build -t "$EXT_FRR_IMG" -f "$REPO_ROOT/external-router/Containerfile" "$REPO_ROOT"

echo "INFO: Remove stale containers"
podman rm -f "$EXT_APP_NAME" "$EXT_FRR_NAME" >/dev/null 2>&1 || true

echo "INFO: Run external router [$EXT_FRR_NAME]"
podman run -d --privileged \
  --network "$DEFAULT_CRI_NET_NAME" \
  --network "$NET1_CRI_NET_NAME" \
  --network "$EXT_NET_CRI_NET_NAME" \
  --rm \
  --ulimit core=-1 \
  --name "$EXT_FRR_NAME" \
  --volume "$FRR_CONFIG:/etc/frr" \
  "$EXT_FRR_IMG"

echo "INFO: Read the external router addresses from podman"
EXT_FRR_IP=""
EXT_FRR_CLIENT_IP=""
for _ in {1..60}; do
  EXT_FRR_IP=$(inspect_network_ip "$EXT_FRR_NAME" "$NET1_CRI_NET_NAME" 2>/dev/null) || true
  EXT_FRR_CLIENT_IP=$(inspect_network_ip "$EXT_FRR_NAME" "$EXT_NET_CRI_NET_NAME" 2>/dev/null) || true
  is_ipv4 "$EXT_FRR_IP" && is_ipv4 "$EXT_FRR_CLIENT_IP" && break
  sleep 1
done
if ! is_ipv4 "$EXT_FRR_IP" || ! is_ipv4 "$EXT_FRR_CLIENT_IP"; then
  echo "FATAL: could not read the external router addresses" >&2
  exit 1
fi
echo "INFO: External router underlay address [$EXT_FRR_IP]"
echo "INFO: External router client-network address [$EXT_FRR_CLIENT_IP]"

echo "INFO: Run external client [$EXT_APP_NAME], default route via [$EXT_FRR_CLIENT_IP]"
podman run --name "$EXT_APP_NAME" \
  --rm -d \
  --privileged \
  --network "$EXT_NET_CRI_NET_NAME" \
  --entrypoint sh \
  "$EXT_APP_IMG" \
  -c "ip route del default 2>/dev/null || true; ip route replace default via $EXT_FRR_CLIENT_IP; exec /agnhost netexec"

echo "INFO: Verify the external client default route"
for _ in {1..10}; do
  podman exec "$EXT_APP_NAME" ip route show 2>/dev/null | grep -q "default via $EXT_FRR_CLIENT_IP" && break
  sleep 1
done
if ! podman exec "$EXT_APP_NAME" ip route show | grep -q "default via $EXT_FRR_CLIENT_IP"; then
  echo "FATAL: external client default route is not via [$EXT_FRR_CLIENT_IP]" >&2
  exit 1
fi

echo "INFO: Generate NNCP for creating the VNI linux-bridge"
(
  export \
    META_NAME=$VNI_BR_NNCP_NAME \
    L2VNI_BRIDGE=$L2VNI_BRIDGE
  echo "\
    META_NAME=$META_NAME
    L2VNI_BRIDGE=$L2VNI_BRIDGE"
  envsubst <<< $(cat $NNCP_VNI_BR_TEMPLATE) > $NNCP_VNI_BR_MANIFEST
)

echo "INFO: Generate OpenPERouter VNI manifest"
(
  export \
    NAMESPACE=$NAMESPACE \
    VRF=$EXT_NET_VRF \
    L3VNI=$EXT_NET_L3VNI \
    L2VNI=$EXT_NET_L2VNI \
    L2VNI_GW_CIDR=$EXT_NET_L2VNI_GW_CIDR \
    L2VNI_BRIDGE=$L2VNI_BRIDGE
  echo "\
    NAMESPACE: $NAMESPACE
    VRF: $VRF
    L3VNI: $L3VNI
    L2VNI: $L2VNI
    L2VNI_GW_CIDR: $L2VNI_GW_CIDR
    L2VNI_BRIDGE: $L2VNI_BRIDGE"
  envsubst <<< $(cat $VNIS_TEMPLATE) > $VNIS_MANIFEST
)

echo "INFO: Generate OpenPERouter Underlay manifest"
(
  export \
    NAMESPACE=$NAMESPACE \
    CLUSTER_ASN=$CLUSTER_NET_ASN \
    NEI_ASN=$EXT_NET_ASN \
    NEI_IP=$EXT_FRR_IP \
    NODE0=$NODE0 \
    NODE1=$NODE1 \
    NODE0_HOSTNAME=$NODE0_HOSTNAME \
    NODE1_HOSTNAME=$NODE1_HOSTNAME \
    NET1_NODE_NIC=$NET1_NODE_NIC \
    UNDERLAY_IFACE_NAME=$UNDERLAY_IFACE_NAME \
    NET1_MVLN_NODE0_IP=$NET1_MVLN_NODE0_IP \
    NET1_MVLN_NODE1_IP=$NET1_MVLN_NODE1_IP \
    UNDERLAY_PREFIX=$UNDERLAY_PREFIX
  echo "\
    NAMESPACE=$NAMESPACE
    CLUSTER_ASN=$CLUSTER_ASN
    NEI_ASN=$NEI_ASN
    NEI_IP=$NEI_IP
    NODE0=$NODE0
    NODE1=$NODE1
    NODE0_HOSTNAME=$NODE0_HOSTNAME
    NODE1_HOSTNAME=$NODE1_HOSTNAME
    NET1_NODE_NIC=$NET1_NODE_NIC
    UNDERLAY_IFACE_NAME=$UNDERLAY_IFACE_NAME
    NET1_MVLN_NODE0_IP=$NET1_MVLN_NODE0_IP
    NET1_MVLN_NODE1_IP=$NET1_MVLN_NODE1_IP
    UNDERLAY_PREFIX=$UNDERLAY_PREFIX"
  envsubst <<< $(cat $UNDERLAY_TEMPLATE) > $UNDERLAY_MANIFEST
)

echo "INFO: Create NNCP for creating the VNI linux-bridge"
oc apply -f $NNCP_VNI_BR_MANIFEST
echo "INFO: Create underlay"
oc -n $NAMESPACE apply -f $UNDERLAY_MANIFEST

echo "INFO: Waiting for underlay settings to converge"
sleep 25

echo "INFO: Create VNIs"
oc -n $NAMESPACE apply -f $VNIS_MANIFEST

# TODO: uncomment once fix for status showing UNKNOWN bug is consumed
# oc -n $NAMESPACE wait routernodeconfigurationstatus/$NODE0 --for condition=Ready --timeout 5m
# oc -n $NAMESPACE wait routernodeconfigurationstatus/$NODE1 --for condition=Ready --timeout 5m

echo "INFO: Wait for BGP neighbor convergence"
sleep 5
(
  set -x
  podman exec "$EXT_FRR_NAME" vtysh -c 'show bgp summary'
  podman exec "$EXT_FRR_NAME" vtysh -c 'show bgp l2vpn evpn'
) 2>&1 | tee "${SCRIPT_PATH}/setup.log"
