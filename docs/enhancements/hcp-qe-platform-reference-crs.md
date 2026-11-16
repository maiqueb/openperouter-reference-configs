# Reference manifests — HCP QE platform

Companion to `hcp-qe-platform.md` (design) and
`hcp-qe-platform-requirements.md` (object inventory and sources). This file
turns the six setup steps of section 4 of the design into concrete objects, for
both the interim untagged shape (phases 1–2) and the target trunk shape
(phase 3).

The values are illustrative but internally consistent: one guest cluster
identified by the token `c1a2b3c4`, a 9000-byte underlay so the MTU chain lands
at 8950 on the bridge and NADs, and one VNI block. The QE framework's allocator
owns the real VNI values; every number below is a placeholder that must come
from it.

Fields marked **upstream only** are not exercised anywhere in this repository;
they were taken from the upstream CNI/nmstate/HyperShift documentation or
source and should be verified once on the target OCP before the framework
depends on them. See *Verification status* at the end.

## Conventions used below

| Thing | Value |
|---|---|
| Guest cluster token | `c1a2b3c4` |
| HCP / guest namespace | `clusters-qe-c1a2b3c4` |
| OpenPERouter namespace | `openperouter-system` |
| Node selectors | NNCPs, NADs and overlay CRs: `node-role.kubernetes.io/worker: ""`; `Underlay`s: `kubernetes.io/hostname` |
| Underlay NIC | `mgmt0` (placeholder): the macvlan master for both the reflector and the datapath, left in place on the host |
| Underlay objects | one per node, static address: RRs `.2`, `.3`, …; workers `.10`, `.11`, … |
| MTU | underlay 9000 → bridge / NAD 8950 → guest OVN-K 8850 |
| ASN / VTEP pool | 64514 / `100.65.0.0/24` |
| Router ID pools | RR `100.66.0.0/24`, workers `100.66.1.0/24` |
| Bridges, phases 1–2 | `br-c1a2b3c4-1` … `br-c1a2b3c4-4` (13 chars) |
| Bridge, phase 3 | `br-c1a2b3c4` (11 chars) |
| Dummy port, phase 3 | `dmy-c1a2b3c4` (12 chars) |
| Trunk host veth, phase 3 | `host-t-c1a2b3c4` (15 chars) |
| NAD names | `nic1` … `nic4` |
| VNI math | phases 1–2 NIC *n* → `4000+n`; phase 3 tag `1000+k` → L2VNI `10001+k`, L3VNI `11001+k` |
| Segments | tags 1000–1019; each NIC owns a five-tag slice |
| Routed subnet (optional) | `10.101.<k>.0/24`, gateway `10.101.<k>.1` |
| VRF (optional) | `v-c1a2b3c4-<k>` (12 chars) |

VRFs and routed subnets appear only when the cluster request marks a segment as
routed; routing is off by default.

## Step 0 — platform prerequisites (once per management cluster)

Two things belong here rather than in the per-cluster steps.

**Underlay.** Every underlay interface is provisioned by the macvlan CNI
plugin (a `CNIDevice` with static IPAM), so the plugin creates a new interface
inside the router netns and the host's own device stays where it is. No
`Underlay` moves a host device: `NetworkDevice` would take the node's
management interface out of the host netns, which neither the hypervisor nor
the router pod can afford. Because the plugin config embeds that node's own
static address, one object cannot cover several nodes: one object matching
several nodes applies the same `rawConfig`, and therefore the same address, on
each of them. The reflector is therefore **one object per control-plane node**
and the datapath **one object per worker**, each selected by
`kubernetes.io/hostname`.

This also follows from where the reflector runs: the RR is the router pod on a
control-plane node, and a pod cannot hand its netns a host device, whereas it
can invoke the CNI plugin for its own interface.

The two roles cannot be merged — a reflector must not also carry a VTEP, and a
VTEP-carrying client must not reflect — and no node may match two: the
validating webhook rejects any create that would leave a node matching two
`Underlay`s, "can't have more than one underlay per node"
(`internal/conversion/validate_underlay.go:36-45`). The selectors stay
disjoint because every object names exactly one node. That rule is also what
keeps the set **platform-scoped rather than per guest cluster**: every guest
cluster whose VMs land on those workers shares it.

**DHCP does not lift the per-node requirement.** A macvlan interface gets a
fresh random MAC on every CNI ADD, so the DHCP server sees a new client after
each netns rebuild and can hand out a different address. Pinning the MAC via
`runtimeConfig.mac` restores lease stability, but the MAC is itself per node —
two nodes sharing one would collide on the same lease — so DHCP with a pinned
MAC is the same one-object-per-node shape as static IPAM. Only DHCP *without*
pinning fits a single shared object, and it buys an unstable underlay address
after every netns rebuild.

```yaml
# One per control-plane node. The reflector is the router pod running there, so
# it gets its own CNI-provisioned interface and mgmt0 stays in the host netns.
apiVersion: network.openperouter.io/v1alpha1
kind: Underlay
metadata:
  name: underlay-rr-0
  namespace: openperouter-system
spec:
  nodeSelector:
    matchLabels:
      kubernetes.io/hostname: cp-0
  asn: 64514
  routerIDCIDR: 100.66.0.0/24
  interfaces:
    - type: CNIDevice
      cniDevice:
        type: RawConfig
        interfaceName: net1
        rawConfig:
          cniVersion: "1.0.0"
          name: macvlan-rr
          plugins:
            - type: macvlan
              master: mgmt0
              mode: bridge
              ipam:
                type: static
                addresses:
                  - address: 192.168.11.2/24
  # No tunnelEndpoint: the reflector does not carry a VTEP.
  routeReflector:
    clusterID: 192.0.2.1
  neighbors:
    - type: Internal
      listenRange: 192.168.11.0/24
      addressFamilies:
        - type: ipv4unicast
          properties:
            - type: routeReflectorClient
        - type: evpn
          properties:
            - type: routeReflectorClient
    - type: Internal
      address: 192.168.11.3   # RR on cp-1
      addressFamilies:
        - type: ipv4unicast
        - type: evpn
---
# One per worker: the CNI config carries that node's own address.
apiVersion: network.openperouter.io/v1alpha1
kind: Underlay
metadata:
  name: underlay-worker-0
  namespace: openperouter-system
spec:
  nodeSelector:
    matchLabels:
      kubernetes.io/hostname: worker-0
  asn: 64514
  routerIDCIDR: 100.66.1.0/24
  interfaces:
    - type: CNIDevice
      cniDevice:
        type: RawConfig
        interfaceName: net1
        rawConfig:
          cniVersion: "1.0.0"
          name: macvlan-underlay
          plugins:
            - type: macvlan
              master: mgmt0
              mode: bridge
              ipam:
                type: static
                addresses:
                  - address: 192.168.11.10/24
  tunnelEndpoint:
    cidrs:
      - 100.65.0.0/24
  neighbors:
    - type: Internal
      address: 192.168.11.2   # RR on cp-0
    - type: Internal
      address: 192.168.11.3   # RR on cp-1
```

Repeat the worker object for each worker with a new `metadata.name`, a
`kubernetes.io/hostname` selector for that node, and the next address in the
block (`.10`, `.11`, `.12`, …); repeat the RR object for each control-plane
node (`.2`, `.3`, …), pointing it at the other RR addresses.

The `listenRange` only accepts sessions, it never dials one, so the reflectors
peer with each other through the explicit `address` neighbors, and every
client lists every RR address — a client that knows only one RR keeps working
right up until that RR goes away. Nothing in the conversion drops a neighbor
that is the local address, so each RR object lists the *other* RRs and no
node peers with itself. The inter-RR neighbors state their address families
explicitly because `evpn` is only enabled by default on a node that has an
`L2VNI` or `L3VNI`, and an RR matches neither — leaving it to the default
would drop EVPN from the reflector-to-reflector session, and each RR would
reflect into a fabric it shares no routes with. With three control-plane nodes
the RR set is three objects sharing one `clusterID`, which is what keeps
CLUSTER_LIST loop detection correct across them.

Router IDs and VTEPs are derived from the node index, not from the object
(`internal/conversion/frr_conversion.go:1163-1171` → `ipam.RouterID`), so
every object can share one `routerIDCIDR` and the same `tunnelEndpoint.cidrs`.
The two pools above stay disjoint only to keep RR and worker router IDs apart
by eye. Adding a node means adding one object; deleting one takes that node's
VTEP and segments down with it.

**Guest namespace.** HyperShift creates `clusters-<name>` only when the
`HostedCluster` exists — step 6. Steps 2 and 3 create NADs and overlay CRs in
that namespace, and `NodePool.additionalNetworks` must reference NADs from the
guest cluster's namespace, so the framework has to create the namespace here:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: clusters-qe-c1a2b3c4
```

The overlay CRs may live here or in `openperouter-system` — the controller's
watches are cluster-wide, but cross-object references such as
`L2VNI.spec.trunk.name` and `routingDomain.l3vni.name` are same-namespace only.

## Phases 1–2 — untagged, one bridge per NIC

### Step 1 — NNCP: four host bridges, no VLAN filtering

One policy per bridge, updated in place. No `vlan` block anywhere: filtering
must stay off, and no NIC is tagged. No `port` list either — the ports are the
bridge-CNI veths, which appear later and must not be declared here.

```yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: qe-c1a2b3c4-br1
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ""
  desiredState:
    interfaces:
      - name: br-c1a2b3c4-1
        type: linux-bridge
        state: up
        mtu: 8950
        ipv4:
          enabled: false
        ipv6:
          enabled: false
        bridge:
          options:
            stp:
              enabled: false
          allow-extra-ports: true
```

Objects 2–4 are the same body with `metadata.name: qe-c1a2b3c4-br2` (and `-3`,
`-4`) and `interfaces[0].name: br-c1a2b3c4-2` (and `-3`, `-4`).

`allow-extra-ports: true` is the guard for the port-pruning failure mode in
section 6 of the design: without it, a re-apply of the policy reaps the
CNI-created ports. It is not persisted, so it must be present on every apply.

The `node-role.kubernetes.io/worker: ""` selector must cover **every worker a
guest node may run on or be migrated to**, not just the ones hosting VMs when
the cluster is created. Live migration is a basic requirement, and the bridge
does not follow the VM.

### Step 2 — four NADs

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: nic1
  namespace: clusters-qe-c1a2b3c4
  annotations:
    k8s.v1.cni.cncf.io/resourceName: bridge.network.kubevirt.io/br-c1a2b3c4-1
spec:
  config: |-
    {
      "cniVersion": "0.3.1",
      "name": "nic1",
      "type": "bridge",
      "bridge": "br-c1a2b3c4-1",
      "mtu": 8950,
      "macspoofchk": false,
      "disableContainerInterface": true
    }
```

`nic2`–`nic4` are identical apart from `name`, the annotation and `"bridge"`,
pointing at `br-c1a2b3c4-2` … `br-c1a2b3c4-4`. No `vlan` or `vlanTrunk`: these
are untagged domains.

The `resourceName` annotation is **mandatory**, not an optimisation: the bridge
marker, which ships with OpenShift Virtualization, publishes
`bridge.network.kubevirt.io/<bridge>` as a per-node extended resource wherever
the bridge exists, and virt-launcher requests it. That is what keeps live
migration on prepared workers — KubeVirt schedules the source pod *and* the
migration target onto nodes that advertise the bridge. Drop the annotation and
a VM can be migrated onto a worker whose four NICs have no bridge behind them.

The annotation covers the bridge alone. The trunk membership, the segments and
the MTU are per-worker state the framework must have reconciled on every
eligible worker before a migration can be targeted there.

### Step 3 — four standalone L2VNIs

`hostMaster` with `lifecycle: External` attaches the veth to the NNCP-created
bridge without OpenPERouter owning it.

```yaml
apiVersion: network.openperouter.io/v1alpha1
kind: L2VNI
metadata:
  name: l2-c1a2b3c4-1
  namespace: clusters-qe-c1a2b3c4
spec:
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/worker: ""
  vni: 4001
  hostMaster:
    type: LinuxBridge
    linuxBridge:
      lifecycle: External
      name: br-c1a2b3c4-1
```

NIC 2/3/4: `l2-c1a2b3c4-2` (VNI 4002, bridge `-2`), `-3` (4003, `-3`),
`-4` (4004, `-4`). No `routingDomain` and no `gatewayIPs`: pure L2.

A routed segment adds exactly three things — an `L3VNI`, a `routingDomain`
pointing at it, and `gatewayIPs` — as shown for phase 3 below. Steps 4 and 5
of the design do not apply to this shape.

## Phase 3 — one VLAN-aware bridge and one trunk

### Step 1 — NNCP: bridge plus dummy port

nmstate has no standalone VLAN-filtering switch, so the policy declares the
bridge together with a dummy port carrying a `vlan` block; that is what makes
NetworkManager enable `vlan-filtering` at creation. The dummy stays for the
life of the bridge.

```yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: qe-c1a2b3c4-br
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ""
  desiredState:
    interfaces:
      - name: br-c1a2b3c4
        type: linux-bridge
        state: up
        mtu: 8950
        ipv4:
          enabled: false
        ipv6:
          enabled: false
        bridge:
          options:
            stp:
              enabled: false
          allow-extra-ports: true
          port:
            - name: dmy-c1a2b3c4
              vlan:
                mode: trunk
                trunk-tags:
                  - id-range:
                      min: 1000
                      max: 1019
      - name: dmy-c1a2b3c4
        type: dummy
        state: up
        mtu: 8950
```

The dummy port has no `tag` and no `enable-native`, so 1000–1019 stay tagged.
Verify the outcome rather than trusting it: `cat
/sys/class/net/br-c1a2b3c4/bridge/vlan_filtering` must be `1` on every node.

As in phases 1–2, the selector must cover every worker a guest node may run on
or be migrated to; live migration is a basic requirement and the bridge does
not follow the VM.

### Step 2 — four NADs with per-NIC slices

`vlan` is the port's native (PVID, untagged) tag; `vlanTrunk` entries are
tagged members. It is set here to the first tag of the NIC's slice, and that
tag is **left out of `vlanTrunk`** — the tagged add clears the PVID/untagged
flags, so a tag cannot be both. Consequence: whichever tag is native is
reachable from the guest only untagged. If QE must run tagged tests on it, give
each NIC a dedicated out-of-range native tag instead (for example 2001–2004)
and keep all five slice tags in `vlanTrunk`.

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: nic1
  namespace: clusters-qe-c1a2b3c4
  annotations:
    k8s.v1.cni.cncf.io/resourceName: bridge.network.kubevirt.io/br-c1a2b3c4
spec:
  config: |-
    {
      "cniVersion": "0.3.1",
      "name": "nic1",
      "type": "bridge",
      "bridge": "br-c1a2b3c4",
      "mtu": 8950,
      "vlan": 1000,
      "vlanTrunk": [
        { "minID": 1001, "maxID": 1004 }
      ],
      "preserveDefaultVlan": false,
      "macspoofchk": false,
      "disableContainerInterface": true
    }
```

| NAD | native `vlan` | `vlanTrunk` |
|---|---|---|
| `nic1` | 1000 | `{"minID": 1001, "maxID": 1004}` |
| `nic2` | 1005 | `{"minID": 1006, "maxID": 1009}` |
| `nic3` | 1010 | `{"minID": 1011, "maxID": 1014}` |
| `nic4` | 1015 | `{"minID": 1016, "maxID": 1019}` |

All four share the one bridge, so the bridge-marker annotation is the same on
each, and it is **mandatory** on all four for the reason given in the phases
1–2 step 2: the bridge marker, part of OpenShift Virtualization, only lets
virt-launcher place the source pod and the migration target on workers that
advertise the bridge.

### Step 3 — one L2Trunk and 20 L2VNIs

`L2Trunk.spec.type` is required (the only value is `Host`). The trunk carries
no tag list of its own: its span is the union of the tags on the `L2VNI`s that
reference it, plus the NNCP port membership from step 4.

```yaml
apiVersion: network.openperouter.io/v1alpha1
kind: L2Trunk
metadata:
  name: trunk-c1a2b3c4
  namespace: clusters-qe-c1a2b3c4
spec:
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/worker: ""
  type: Host
  hostMaster:
    type: LinuxBridge
    linuxBridge:
      lifecycle: External
      name: br-c1a2b3c4
---
apiVersion: network.openperouter.io/v1alpha1
kind: L2VNI
metadata:
  name: l2-c1a2b3c4-1000
  namespace: clusters-qe-c1a2b3c4
spec:
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/worker: ""
  vni: 10001
  trunk:
    name: trunk-c1a2b3c4
    vlan:
      tag: 1000
---
apiVersion: network.openperouter.io/v1alpha1
kind: L2VNI
metadata:
  name: l2-c1a2b3c4-1005
  namespace: clusters-qe-c1a2b3c4
spec:
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/worker: ""
  vni: 10006
  trunk:
    name: trunk-c1a2b3c4
    vlan:
      tag: 1005
---
apiVersion: network.openperouter.io/v1alpha1
kind: L2VNI
metadata:
  name: l2-c1a2b3c4-1019
  namespace: clusters-qe-c1a2b3c4
spec:
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/worker: ""
  vni: 10020
  trunk:
    name: trunk-c1a2b3c4
    vlan:
      tag: 1019
```

For `k = 0..19`, object `l2-c1a2b3c4-<1000+k>` carries `vni: 10001+k` and
`trunk.vlan.tag: 1000+k`; 1001–1004 and 1006–1018 are the same three fields
with the counter bumped, 20 objects in all.

If the request marks a segment as routed, create its `L3VNI` and extend that
`L2VNI` (tag 1000 shown):

```yaml
apiVersion: network.openperouter.io/v1alpha1
kind: L3VNI
metadata:
  name: l3-c1a2b3c4-1000
  namespace: clusters-qe-c1a2b3c4
spec:
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/worker: ""
  vrf: v-c1a2b3c4-0
  vni: 11001
---
apiVersion: network.openperouter.io/v1alpha1
kind: L2VNI
metadata:
  name: l2-c1a2b3c4-1000
  namespace: clusters-qe-c1a2b3c4
spec:
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/worker: ""
  vni: 10001
  trunk:
    name: trunk-c1a2b3c4
    vlan:
      tag: 1000
  routingDomain:
    type: L3VNI
    l3vni:
      name: l3-c1a2b3c4-1000
  gatewayIPs:
    - 10.101.0.1/24
```

`hostSession` is omitted on purpose: gateway traffic never needs to reach the
host's default namespace. `gatewayIPs` is immutable, so the subnet must be
final here.

### Step 4 — NNCP re-apply: add the trunk host veth as a port

Same object, same name, both ports listed. This must run after step 3: the veth
exists only once the `L2Trunk` is reconciled, and nmstate can only describe a
port that already exists.

```yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: qe-c1a2b3c4-br
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ""
  desiredState:
    interfaces:
      - name: br-c1a2b3c4
        type: linux-bridge
        state: up
        mtu: 8950
        ipv4:
          enabled: false
        ipv6:
          enabled: false
        bridge:
          options:
            stp:
              enabled: false
          allow-extra-ports: true
          port:
            - name: dmy-c1a2b3c4
              vlan:
                mode: trunk
                trunk-tags:
                  - id-range:
                      min: 1000
                      max: 1019
            - name: host-t-c1a2b3c4
              vlan:
                mode: trunk
                trunk-tags:
                  - id-range:
                      min: 1000
                      max: 1019
      - name: dmy-c1a2b3c4
        type: dummy
        state: up
        mtu: 8950
```

The four VM-side veth ports stay out of this policy: their names are generated
by the CNI plugin when the pod starts, and their membership comes from the NADs
in step 2. Both `allow-extra-ports: true` and the dummy port are mandatory on
this apply.

`host-t-c1a2b3c4` is 15 characters, exactly IFNAMSIZ — there is no room for a
per-node suffix, so the 8-hex token has to carry the whole disambiguation.
Nothing in the repository derives this name from the `L2Trunk` today.

This apply must land on **every** worker eligible to host a guest node, and it
must land before any migration targets that worker. The bridge marker only
proves the bridge exists; the trunk port is what makes it carry traffic, and no
annotation schedules on it.

### Step 5 — NodePool `additionalNetworks`

```yaml
apiVersion: hypershift.openshift.io/v1beta1
kind: NodePool
metadata:
  name: qe-c1a2b3c4
  namespace: clusters
spec:
  platform:
    type: KubeVirt
    kubevirt:
      attachDefaultNetwork: true
      additionalNetworks:
        - name: clusters-qe-c1a2b3c4/nic1
        - name: clusters-qe-c1a2b3c4/nic2
        - name: clusters-qe-c1a2b3c4/nic3
        - name: clusters-qe-c1a2b3c4/nic4
```

Each entry is a single `<namespace>/<name>` string — there is no separate
namespace field. HyperShift always uses bridge binding for these interfaces,
and the list cannot be changed after the NodePool is created.

### Step 6 — HostedCluster and NodePool

The NICs exist on each VM at first boot, so no hot-plug is involved. Wait for
the virt-launcher pods to be running before declaring the cluster ready.

## Teardown order

Reverse of setup, so a bridge is never deleted under running VMs:

1. `HostedCluster` and `NodePool`, waiting for the virt-launcher pods to go.
2. The OpenPERouter CRs and the NADs — deleting the `clusters-<name>`
   namespace takes both together.
3. The bridge NNCP, which removes the bridge, the dummy port and the trunk
   port membership.
4. Check `RouterNodeConfigurationStatus` reports no `failedResources`.

Every object carries `cnv-qe/cluster=<id>` so a later job can sweep a failed
run; a stale `L2Trunk` is the object that leaks a veth and a bridge port.

## Verification status

Checked against this repository:

| Field | Source |
|---|---|
| `Underlay.spec.nodeSelector`, `asn`, `interfaces`, `tunnelEndpoint`, `routeReflector`, `neighbors` | `api/v1alpha1/underlay_types.go`, `neighbor.go` |
| Overlapping `Underlay` node selectors rejected | `api/v1alpha1/underlay_types.go:31`, `internal/conversion/validate_underlay.go:36-45` |
| `CNIDevice` fields (`type: RawConfig`, `interfaceName`, `rawConfig`, `runtimeConfig`) | `api/v1alpha1/underlay_types.go:172-228`; example at `examples/evpn/cni-underlay/openpe.yaml` |
| One node-scoped CNI `Underlay` per node, macvlan + static IPAM, hostname selector | `e2etests/pkg/infra/underlay_cni.go:36-104` |
| `listenRange` + `routeReflectorClient` render the RR peer-group and client stanzas | `internal/conversion/frr_conversion.go`, `enhancements/route-reflector.md` |
| `evpn` is a default address family only for a node matching an `L2VNI` or `L3VNI`, so RR-only neighbors must name their families | `internal/conversion/frr_conversion.go:1017-1049` |
| Router ID and VTEP derived from the node index, not from the object | `internal/conversion/frr_conversion.go:1163-1171`, `internal/ipam/ipam.go:91-103` |
| `L2Trunk.spec.type` required, enum `Host` | `api/v1alpha1/l2trunk_types.go:13,29-31`, `config/crd/bases/network.openperouter.io_l2trunks.yaml` |
| `L2VNI.spec.hostMaster` (External), `vni`, `trunk`, `routingDomain`, `gatewayIPs`; `trunk` immutable and exclusive with `hostMaster` | `api/v1alpha1/l2vni_types.go` |
| `L3VNI.spec.vrf`, `vni`; `hostSession` optional | `api/v1alpha1/l3vni_types.go` |
| NAD envelope and base bridge fields (`cniVersion`, `type`, `bridge`, `macspoofchk`, `disableContainerInterface`) | `examples/evpn/kubevirt/workload.yaml` |

**Upstream only — not exercised in this repository:** every
`NodeNetworkConfigurationPolicy` (there is no NNCP example here),
`bridge.allow-extra-ports`, the dummy port type, interface-level `mtu` in
nmstate, `mtu` in a bridge NAD, the bridge-marker `resourceName` annotation,
`vlanTrunk`/`vlan`, and the HyperShift `NodePool` kubevirt
`additionalNetworks` shape. Verify them once on the target OCP before the
framework depends on them.

## Open decisions

- **Duplicate RR addresses.** Every RR object in a fabric must carry the same
  `clusterID` and a distinct address; two nodes sharing one static address
  would collide on the segment and neither would establish a session.
  `rawConfig` is immutable, so a wrong address means delete and recreate.
- **Overlapping listen range and inter-RR neighbors.** The RR addresses sit
  inside each node's client `listenRange`, since everything is one management
  subnet. FRR has to use the configured neighbor for them instead of creating
  a dynamic RR-client peer, or the two RRs become each other's clients and the
  topology loops. Confirm the inter-RR sessions render as configured neighbors
  on the target FRR.
- **macvlan parent on the control-plane nodes.** The plugin needs a parent that
  stays in the host netns and reaches the RR subnet — typically not the device
  already carrying the node's cluster network. Nothing in the repository picks
  it; confirm it on the target OCP before generating the RR objects.
- **Trunk host veth name.** No code derives `host-t-<8 hex>` from the
  `L2Trunk` today; until it exists the step 4 policy cannot be written. This
  is the one hard blocker on phase 3.
- **Double attachment.** Step 3's `hostMaster` attaches the veth to the bridge
  and step 4's policy declares it as a port. One of them has to win; verify NM
  ownership on a single node before automating both.
- **`allow-extra-ports` availability.** Version-dependent on the
  OCP-shipped nmstate. If it is rejected, drop it and never re-apply the
  policy.
- **Native VLAN.** The choice in step 2 decides whether the first tag of each
  slice is usable as a tagged VLAN from the guest.
- **Phase 1→3 migration is delete-and-recreate.** `L2VNI.spec.trunk` is
  immutable and exclusive with `hostMaster`, so the four untagged `L2VNI`s
  must be deleted before the trunk ones are created; there is no in-place
  conversion.
- **Stale example.** `enhancements/l2vni-vlan-tag.md` shows `L2Trunk` objects
  without `spec.type`, which admission rejects today.
