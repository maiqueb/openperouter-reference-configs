# Reference manifests — HCP QE platform

Two shapes, one per phase group. The untagged shape (phases 1–2) works with
the current dataplane; the trunk shape (phase 3) needs trunk support in
OpenPERouter first, but is written against the API as it is defined today.

The objects split in two:

- **Platform overlay (admin, once):** the `Underlay`s, the shared bridges, the
  `L2Trunk` and the 20 `L2VNI`s. They live in `openshift-openperouter` and are
  shared by every guest cluster.
- **Guest-cluster wiring (QE framework, per cluster):** the namespace, the four
  NADs and the `NodePool` entries, pointing at the shared bridges.

Placeholders in angle brackets are environment-specific values (per node, per
guest cluster, or platform-wide). VLAN tags are fixed: `1000`–`1019`.

| Placeholder | Meaning |
|---|---|
| `<cluster>` | guest cluster token; only per-cluster objects use it |
| `<guest-ns>` | `clusters-<cluster>` |
| `<mtu>` | bridge / NAD MTU = underlay MTU − 50 |
| `<mgmt-if>` | host NIC the macvlan underlay is based on |
| `<underlay-subnet>` | management subnet shared by router and workers |
| `<rr-ip>`, `<worker-ip>` | static underlay address of that node |
| `<asn>`, `<cluster-id>` | underlay ASN and BGP cluster ID |
| `<platform-bridge>` | phase 3 shared bridge name |
| `<platform-bridge-n>` | phases 1–2 shared bridge names, `n = 1..4` |
| `<platform-dummy>` | phase 3 dummy port name |
| `<platform-trunk>` | phase 3 `L2Trunk` name |
| `<platform-l2vni>` | prefix of the `L2VNI` names |

Platform objects use placeholders too: `<platform-bridge>`, `<platform-dummy>`,
`<platform-trunk>` and `<platform-l2vni>-<tag>` in the trunk shape, and
`<platform-bridge-n>` / `<platform-l2vni>-nic<n>` in the untagged shape. Only
`<guest-ns>`, the four NADs and the `NodePool` entries are per guest cluster,
so `<cluster>` no longer has to fit the 15-character interface-name limit. It
must still be unique per guest cluster on the management cluster, since it
names the guest namespace and the `NodePool`.

## Platform overlay (admin, once)

### `Underlay`s

One object per node, because each one embeds that node's own static address
(`rawConfig` is immutable). The interface is created by the macvlan CNI plugin
inside the router netns, so the host's own device is left in place. Selectors
are per hostname, which also satisfies the one-`Underlay`-per-node rule. The
reflector (router pod on a control-plane node) carries no `tunnelEndpoint`; a
worker carries one. The reflector's neighbors name their address families
explicitly, otherwise EVPN is dropped from reflector-to-reflector sessions.

```yaml
# One per control-plane node, all with the same clusterID.
apiVersion: network.openperouter.io/v1alpha1
kind: Underlay
metadata:
  name: underlay-rr-<n>
  namespace: openshift-openperouter
spec:
  nodeSelector:
    matchLabels:
      kubernetes.io/hostname: <cp-node>
  asn: <asn>
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
              master: <mgmt-if>
              mode: bridge
              ipam:
                type: static
                addresses:
                  - address: <rr-ip>/<prefix>
  routeReflector: {}
  neighbors:
    - type: Internal
      listenRange: <underlay-subnet>
      addressFamilies:
        - type: ipv4unicast
          properties:
            - type: routeReflectorClient
        - type: evpn
          properties:
            - type: routeReflectorClient
    - type: Internal
      address: <other-rr-ip>
      addressFamilies:
        - type: ipv4unicast
        - type: evpn
---
# One per worker node, each with its own address and name.
apiVersion: network.openperouter.io/v1alpha1
kind: Underlay
metadata:
  name: underlay-worker-<n>
  namespace: openshift-openperouter
spec:
  nodeSelector:
    matchLabels:
      kubernetes.io/hostname: <worker-node>
  asn: <asn>
  routerIDCIDR: <worker-router-id-cidr>
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
              master: <mgmt-if>
              mode: bridge
              ipam:
                type: static
                addresses:
                  - address: <worker-ip>/<prefix>
  tunnelEndpoint:
    cidrs:
      - <vtep-cidr>
  neighbors:
    - type: Internal
      address: <rr-ip>
```

The `listenRange` only accepts sessions; reflectors peer with each other
through the explicit `address` neighbors, and every client lists every RR
address.

### Phases 1–2 — four shared untagged bridges

Four untagged L2 domains, one per NIC slot, each backed by its own shared
bridge and standalone `L2VNI`. Usable with the current dataplane.

Bridge NNCP, one policy per bridge. No `vlan` block (filtering stays off), no
`port` list (the ports are the bridge-CNI veths, created later). No
`allow-extra-ports` is needed: OCP marks every `veth` unmanaged in
NetworkManager (`driver:veth` in `/etc/NetworkManager/conf.d/sdn.conf`), so
nmstate sees those ports as ignored and does not prune them. The selector must
cover every worker a guest node may run on or migrate to.

```yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: qe-<platform-bridge-n>
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ""
  desiredState:
    interfaces:
      - name: <platform-bridge-n>
        type: linux-bridge
        state: up
        mtu: <mtu>
        ipv4:
          enabled: false
        ipv6:
          enabled: false
        bridge:
          options:
            stp:
              enabled: false
```

One `L2VNI` per NIC. `hostMaster` with `lifecycle: External` attaches the veth
to the NNCP-created bridge without OpenPERouter owning it. VNI = `4000 + n`.

```yaml
apiVersion: network.openperouter.io/v1alpha1
kind: L2VNI
metadata:
  name: <platform-l2vni>-nic<n>
  namespace: openshift-openperouter
spec:
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/worker: ""
  vni: 400<n>
  hostMaster:
    type: LinuxBridge
    linuxBridge:
      lifecycle: External
      name: <platform-bridge-n>
```

Repeat for `n = 1..4` (VNIs `4001`–`4004`). No `routingDomain`, no
`gatewayIPs`: pure L2.

### Phase 3 — shared VLAN-aware bridge and trunk

Needs trunk support in the dataplane (`L2Trunk`, `L2VNI.spec.trunk`) before it
can be used. 20 tagged segments `1000`–`1019`, five per NIC.

One bridge plus a dummy port carrying the `vlan` block — that port is what makes
NetworkManager enable VLAN filtering at creation, and it stays for the life of
the bridge. The CNI-created veth ports are not reported as managed by nmstate
(NetworkManager leaves `veth` devices unmanaged on OCP), so no
`allow-extra-ports` is needed to preserve them. The NNCP does not list the
trunk port and is not re-applied: OpenPERouter creates the trunk veth, enslaves
it and programs its VLAN membership from the `L2Trunk`.

```yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: qe-<platform-bridge>
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ""
  desiredState:
    interfaces:
      - name: <platform-bridge>
        type: linux-bridge
        state: up
        mtu: <mtu>
        ipv4:
          enabled: false
        ipv6:
          enabled: false
        bridge:
          options:
            stp:
              enabled: false
          port:
            - name: <platform-dummy>
              vlan:
                mode: trunk
                trunk-tags:
                  - id-range:
                      min: 1000
                      max: 1019
      - name: <platform-dummy>
        type: dummy
        state: up
        mtu: <mtu>
```

Confirm the result per node:
`cat /sys/class/net/<platform-bridge>/bridge/vlan_filtering` must print `1`.

One `L2Trunk` on the bridge (`type: Host` is required). The trunk has no tag
list of its own: its span is the union of the tags of the `L2VNI`s that
reference it, plus the port membership OpenPERouter programs on the bridge.
The trunk and the `L2VNI`s live in `openshift-openperouter`, because
cross-object references are same-namespace only.

```yaml
apiVersion: network.openperouter.io/v1alpha1
kind: L2Trunk
metadata:
  name: <platform-trunk>
  namespace: openshift-openperouter
spec:
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/worker: ""
  type: Host
  hostMaster:
    type: LinuxBridge
    linuxBridge:
      lifecycle: External
      name: <platform-bridge>
```

One `L2VNI` per tag, `1000`–`1019`, with **VNI = `9001 + tag`** (so `1000` →
`10001`, `1019` → `10020`). Two shown, the other eighteen are the same with the
counter bumped:

```yaml
apiVersion: network.openperouter.io/v1alpha1
kind: L2VNI
metadata:
  name: <platform-l2vni>-1000
  namespace: openshift-openperouter
spec:
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/worker: ""
  vni: 10001
  trunk:
    name: <platform-trunk>
    vlan:
      tag: 1000
---
apiVersion: network.openperouter.io/v1alpha1
kind: L2VNI
metadata:
  name: <platform-l2vni>-1019
  namespace: openshift-openperouter
spec:
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/worker: ""
  vni: 10020
  trunk:
    name: <platform-trunk>
    vlan:
      tag: 1019
```

The trunk host veth and its membership on the bridge are entirely
OpenPERouter's: they follow the `L2Trunk` lifecycle and are not named in any
NNCP. There is no second apply, so no host veth name has to be derived or kept
in sync by the platform.

## Per guest cluster (QE framework)

These are the only per-cluster objects. The framework never creates, updates or
deletes the bridges, the trunk or the segments. Its service account therefore
needs write access only to the guest namespace, where it creates the NADs; the
shared overlay stays admin-owned in `openshift-openperouter`.

### Namespace

HyperShift only creates it together with the `HostedCluster`, but the NADs must
already be there:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: <guest-ns>
```

### NADs — phase 3

NADs share the one bridge, so the same mandatory `resourceName` annotation is on
all four. `vlan` is the native (untagged) tag of the port; `vlanTrunk` holds the
tagged members. A tag cannot be both, so the native tag is kept out of
`vlanTrunk` — it is reachable from the guest only untagged. Give each NIC a
dedicated out-of-range native tag (e.g. `2001`–`2004`) and keep all five slice
tags in `vlanTrunk` if it must be tested tagged.

| NAD | native `vlan` | `vlanTrunk` |
|---|---|---|
| `nic1` | 1000 | 1001–1004 |
| `nic2` | 1005 | 1006–1009 |
| `nic3` | 1010 | 1011–1014 |
| `nic4` | 1015 | 1016–1019 |

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: nic1
  namespace: <guest-ns>
  annotations:
    k8s.v1.cni.cncf.io/resourceName: bridge.network.kubevirt.io/<platform-bridge>
spec:
  config: |-
    {
      "cniVersion": "0.3.1",
      "name": "nic1",
      "type": "bridge",
      "bridge": "<platform-bridge>",
      "mtu": <mtu>,
      "vlan": 1000,
      "vlanTrunk": [
        { "minID": 1001, "maxID": 1004 }
      ],
      "preserveDefaultVlan": false,
      "macspoofchk": false,
      "disableContainerInterface": true
    }
```

`nic2`–`nic4` are the same with `"vlan": 1005 | 1010 | 1015` and the matching
`vlanTrunk` range. The `resourceName` annotation is mandatory: it is what makes
KubeVirt place a VM and its live-migration target only on workers that have the
bridge.

### NADs — phases 1–2

One NAD per bridge, pointing at the shared untagged bridge for its NIC.

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: nic<n>
  namespace: <guest-ns>
  annotations:
    k8s.v1.cni.cncf.io/resourceName: bridge.network.kubevirt.io/<platform-bridge-n>
spec:
  config: |-
    {
      "cniVersion": "0.3.1",
      "name": "nic<n>",
      "type": "bridge",
      "bridge": "<platform-bridge-n>",
      "mtu": <mtu>,
      "macspoofchk": false,
      "disableContainerInterface": true
    }
```

Repeat for `n = 1..4`; no `vlan` or `vlanTrunk` in this shape. The
`resourceName` annotation is mandatory for the same migration reason as in
phase 3.

### NodePool

The only relevant setting is the NAD list. Each entry is a single
`<namespace>/<name>` string, bridge binding is implied, and the list cannot be
changed after creation.

```yaml
apiVersion: hypershift.openshift.io/v1beta1
kind: NodePool
metadata:
  name: <cluster>
  namespace: clusters
spec:
  platform:
    type: KubeVirt
    kubevirt:
      attachDefaultNetwork: true
      additionalNetworks:
        - name: <guest-ns>/nic1
        - name: <guest-ns>/nic2
        - name: <guest-ns>/nic3
        - name: <guest-ns>/nic4
```

### HostedCluster

The NICs exist on each VM at first boot, so no hot-plug is involved. Wait for
the virt-launcher pods to be running before declaring the cluster ready.

## Teardown

Reverse of setup, so a bridge is never removed under running VMs.

**Per cluster (framework):**

1. `HostedCluster` and `NodePool`, waiting for the virt-launcher pods to go.
2. Delete the `<guest-ns>` namespace, which removes the NADs.

The shared overlay is not deleted: the other clusters are still using it.

**Platform (admin), only when no guest cluster uses the overlay:**

1. The `L2VNI`s and the `L2Trunk`.
2. The bridge NNCP(s), which remove the bridges and the dummy ports. The trunk
   veth and its VLAN membership were removed with the `L2Trunk`s.
3. Check that `RouterNodeConfigurationStatus` reports no `failedResources`.

Every per-cluster object carries a `cnv-qe/cluster=<id>` label so a later job
can sweep a failed run; a failed run leaks only its NADs.

## Open questions

- **Cross-cluster acceptance.** The shared segments mean every cluster sees
  every other cluster's traffic on a tag. Confirm with QE which suites can run
  concurrently on the same tag without a quiet-domain assumption.
- **Phase 1→3 migration.** `L2VNI.spec.trunk` is immutable and exclusive with
  `hostMaster`, so the four untagged `L2VNI`s must be deleted before the trunk
  ones are created; there is no in-place conversion. The guest clusters are
  untouched apart from their NAD contents, which point at `<platform-bridge>`
  instead of `<platform-bridge-n>`.
