# Localnet on br-ex

Reference configurations for integrating localnet secondary attachments directly on br-ex, co-existing with OVN-Kubernetes and the Open PE Router on the same bridge.

This is an alternative to the [dedicated-bridge](../dedicated-bridge/) approach which creates a separate OVS bridge.

## Files

| File | Description |
|------|-------------|
| `01-localnet-bridge-mapping.yaml` | NNCP: adds `datanet:br-ex` bridge mapping |
| `02-macvlan-underlay.yaml` | NNCP: creates macvlan0 on ens4 for OPR underlay |
| `03-openperouter-logical-infra.yaml` | L3VNI, L2VNI (targeting br-ex), and Underlay CRs |
| `04-localnet-nad.yaml` | Localnet NetworkAttachmentDefinition |
| `05-external-router-frr.conf` | FRR config for the external router (br-ex variant) |
| `06-workloads.yaml` | Test pods with static dual-stack IPs on the localnet |
| `results/` | Captured outputs proving co-existence and EVPN type-2 routes |

## Prerequisites

- OpenShift 4.22 with OVN-Kubernetes
- kubernetes-nmstate operator
- Open PE Router operator (installed via `operator-sdk run bundle`)
- Extra NIC on workers connected to the underlay network (e.g. `ens4`)

## Apply order

```bash
# 1. Bridge mapping
oc apply -f 01-localnet-bridge-mapping.yaml
oc wait nncp localnet-bridge-mapping --for=condition=Available --timeout=120s

# 2. Macvlan underlay
oc apply -f 02-macvlan-underlay.yaml
oc wait nncp macvlan-underlay --for=condition=Available --timeout=120s

# 3. Open PE Router CRs
oc apply -f 03-openperouter-logical-infra.yaml

# 4. Assign static IPs to macvlan0 in each worker's router pod (see "Macvlan IP assignment" below)

# 5. Localnet NAD
oc create namespace evpn-localnet-test
oc apply -f 04-localnet-nad.yaml

# 6. Workloads (edit WORKER_NODE_1/WORKER_NODE_2 first)
oc apply -f 06-workloads.yaml
```

## Macvlan IP assignment

The `02-macvlan-underlay.yaml` NNCP creates macvlan0 without an IP address. The Open PE Router controller moves macvlan0 from the host into its router network namespace (`perouter`). After the controller reconciles, assign a static IP to macvlan0 inside each worker's router pod:

```bash
# For each worker node:
ROUTER_POD=$(oc get pods -n openshift-openperouter -l app=router \
  -o jsonpath='{.items[?(@.spec.nodeName=="<WORKER_NODE>")].metadata.name}')

oc exec -n openshift-openperouter $ROUTER_POD -c frr -- \
  ip addr add <UNIQUE_IP>/16 dev macvlan0
```

Use a unique IP per worker within the underlay network range (e.g. `10.100.11.50/16`, `10.100.11.51/16`). This is needed for BGP peering to establish.

Automating this IP assignment is a known gap tracked in CNV-79005.

## External router differences from dedicated-bridge

The external FRR router setup for br-ex differs from the dedicated-bridge variant:

| | Dedicated-bridge | br-ex |
|---|---|---|
| BGP listen range | `10.200.0.0/16` (net2) | `10.100.0.0/16` (net1) |
| Extra networks needed | net1 + net2 | net1 only |
| Container networking | podman networks (net1-ex, net2-ex) | veth injection to net1 bridge |

The FRR config is provided as `05-external-router-frr.conf`. To set up the external router container:

```bash
# Create isolated network for external client
podman network create --subnet 192.169.1.0/24 --driver macvlan my-isolated-network

# Start FRR container
podman run -d --privileged \
  --network my-isolated-network \
  --name frr \
  --volume /path/to/05-external-router-frr.conf:/etc/frr/frr.conf:Z \
  quay.io/frrouting/frr:10.6.0 sleep infinity

# Connect FRR to the underlay network via veth
FRR_PID=$(podman inspect frr --format '{{.State.Pid}}')
ip link add vfrrn1 type veth peer name vfrrn1br
ip link set vfrrn1br master net1
ip link set vfrrn1br up
ip link set vfrrn1 netns $FRR_PID
nsenter -t $FRR_PID -n ip link set vfrrn1 name eth1
nsenter -t $FRR_PID -n ip addr add 10.100.11.4/16 dev eth1
nsenter -t $FRR_PID -n ip link set eth1 up

# Set up VRF, VXLAN, and start FRR
podman exec frr bash -c '
  sysctl -w net.ipv6.conf.all.keep_addr_on_down=1
  ip addr add 100.64.0.1/32 dev lo
  ip link add red type vrf table 1100
  ip link set red up
  ip link add br100 type bridge
  ip link set br100 master red
  ip link set br100 addr aa:bb:cc:00:00:65
  ip link set br100 addrgenmode none
  ip link add vni100 type vxlan local 100.64.0.1 dstport 4789 id 100 nolearning
  ip link set vni100 master br100
  bridge link set dev vni100 neigh_suppress on learning off
  ip link set vni100 up
  ip link set br100 up
  /usr/lib/frr/frrinit.sh start
'
```

Note: the `10.100.11.4` address must match the `neighbors[0].address` in the Underlay CR (`03-openperouter-logical-infra.yaml`).

## Known issues

- **Macvlan IP**: Must be assigned manually after OPR moves macvlan0 to the router namespace. Automating this is tracked in CNV-79005.
- **RouterNodeConfigurationStatus stays Unknown**: The OPR controller configures everything correctly but doesn't update the status CR. See [openperouter-status-bug.md](../../../openperouter-status-bug.md).
- **Control plane errors**: The OPR controller DaemonSet runs on all nodes. The control plane node doesn't have macvlan0, so its controller logs errors. These are expected and harmless.
- **Balance-slb bond**: Not tested in this setup due to kcli limitations (can't bond NICs from different libvirt networks). In production, br-ex would have a balance-slb bond configured at day 0.
