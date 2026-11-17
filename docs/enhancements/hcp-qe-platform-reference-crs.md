# Reference manifests — HCP QE platform

Two recipes, one per phase. Phase 2 works with the current dataplane; phase 3
needs trunk support in OpenPERouter first, but is written against the API as it
is defined today.

Placeholders in angle brackets are values the framework supplies per guest
cluster. VLAN tags are fixed: `1000`–`1019`.

| Placeholder | Meaning |
|---|---|
| `<cluster>` | guest cluster token, used in every object name |
| `<guest-ns>` | `clusters-<cluster>` |
| `<mtu>` | bridge / NAD MTU = underlay MTU − 50 |
| `<mgmt-if>` | host NIC the macvlan underlay is based on |
| `<underlay-subnet>` | management subnet shared by router and workers |
| `<rr-ip>`, `<worker-ip>` | static underlay address of that node |
| `<asn>`, `<cluster-id>` | underlay ASN and BGP cluster ID |

`<cluster>` is **enforced to at most 8 characters** (lowercase alphanumeric,
e.g. an 8-hex token). The hardest constraint is `host-t-<cluster>`, which must
fit the 15-character interface name limit: `7 + len(<cluster>) <= 15`. The
same limit is then satisfied by `br-<cluster>` (3), `dmy-<cluster>` (4) and
`br-<cluster>-<n>` (5). The token must be unique per guest cluster on the
management cluster, since every generated name is tied to it.

## Shared prerequisite — `Underlay` (once per management cluster)

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
  namespace: openperouter-system
spec:
  nodeSelector:
    matchLabels:
      kubernetes.io/hostname: <cp-node>
  asn: <asn>
  routerIDCIDR: <rr-router-id-cidr>
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
  routeReflector:
    clusterID: <cluster-id>
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
  namespace: openperouter-system
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

## Phase 2 — untagged, one bridge per NIC

Usable with the current dataplane. Four untagged L2 domains, one per NIC slot.

### Phase 2 prerequisites (admin-owned)

Bridge NNCP, one policy per bridge. No `vlan` block (filtering stays off), no
`port` list (the ports are the bridge-CNI veths, created later, and
`allow-extra-ports: true` prevents a re-apply from pruning them). The selector
must cover every worker a guest node may run on or migrate to.

```yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: qe-<cluster>-br<n>
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ""
  desiredState:
    interfaces:
      - name: br-<cluster>-<n>
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
          allow-extra-ports: true
```

NAD per bridge. The `resourceName` annotation is mandatory: it is what makes
KubeVirt place a VM and its live-migration target only on workers that have the
bridge.

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: nic<n>
  namespace: <guest-ns>
  annotations:
    k8s.v1.cni.cncf.io/resourceName: bridge.network.kubevirt.io/br-<cluster>-<n>
spec:
  config: |-
    {
      "cniVersion": "0.3.1",
      "name": "nic<n>",
      "type": "bridge",
      "bridge": "br-<cluster>-<n>",
      "mtu": <mtu>,
      "macspoofchk": false,
      "disableContainerInterface": true
    }
```

### Phase 2 recipe

Namespace (HyperShift only creates it together with the `HostedCluster`, but the
NADs and CRs must already be there):

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: <guest-ns>
```

One `L2VNI` per NIC. `hostMaster` with `lifecycle: External` attaches the veth
to the NNCP-created bridge without OpenPERouter owning it. VNI = `4000 + n`.

```yaml
apiVersion: network.openperouter.io/v1alpha1
kind: L2VNI
metadata:
  name: l2-<cluster>-<n>
  namespace: <guest-ns>
spec:
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/worker: ""
  vni: 400<n>
  hostMaster:
    type: LinuxBridge
    linuxBridge:
      lifecycle: External
      name: br-<cluster>-<n>
```

Repeat for `n = 1..4` (VNIs `4001`–`4004`). No `routingDomain`, no
`gatewayIPs`: pure L2.

NodePool: the only relevant setting is the NAD list. Each entry is a single
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

## Phase 3 — one VLAN-aware bridge and one trunk

Needs trunk support in the dataplane (`L2Trunk`, `L2VNI.spec.trunk`) before it
can be used. 20 tagged segments `1000`–`1019`, five per NIC.

### Phase 3 prerequisites (admin-owned)

One bridge plus a dummy port carrying the `vlan` block — that port is what makes
NetworkManager enable VLAN filtering at creation, and it stays for the life of
the bridge. `allow-extra-ports: true` again guards the CNI-created ports.

```yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: qe-<cluster>-br
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ""
  desiredState:
    interfaces:
      - name: br-<cluster>
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
          allow-extra-ports: true
          port:
            - name: dmy-<cluster>
              vlan:
                mode: trunk
                trunk-tags:
                  - id-range:
                      min: 1000
                      max: 1019
      - name: dmy-<cluster>
        type: dummy
        state: up
        mtu: <mtu>
```

Confirm the result per node:
`cat /sys/class/net/br-<cluster>/bridge/vlan_filtering` must print `1`.

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
    k8s.v1.cni.cncf.io/resourceName: bridge.network.kubevirt.io/br-<cluster>
spec:
  config: |-
    {
      "cniVersion": "0.3.1",
      "name": "nic1",
      "type": "bridge",
      "bridge": "br-<cluster>",
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
`vlanTrunk` range.

### Phase 3 recipe

Namespace, as in phase 2:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: <guest-ns>
```

One `L2Trunk` on the bridge (`type: Host` is required). The trunk has no tag
list of its own: its span is the union of the tags of the `L2VNI`s that
reference it, plus its port membership on the bridge.

```yaml
apiVersion: network.openperouter.io/v1alpha1
kind: L2Trunk
metadata:
  name: trunk-<cluster>
  namespace: <guest-ns>
spec:
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/worker: ""
  type: Host
  hostMaster:
    type: LinuxBridge
    linuxBridge:
      lifecycle: External
      name: br-<cluster>
```

One `L2VNI` per tag, `1000`–`1019`, with **VNI = `9001 + tag`** (so `1000` →
`10001`, `1019` → `10020`). Two shown, the other eighteen are the same with the
counter bumped:

```yaml
apiVersion: network.openperouter.io/v1alpha1
kind: L2VNI
metadata:
  name: l2-<cluster>-1000
  namespace: <guest-ns>
spec:
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/worker: ""
  vni: 10001
  trunk:
    name: trunk-<cluster>
    vlan:
      tag: 1000
---
apiVersion: network.openperouter.io/v1alpha1
kind: L2VNI
metadata:
  name: l2-<cluster>-1019
  namespace: <guest-ns>
spec:
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/worker: ""
  vni: 10020
  trunk:
    name: trunk-<cluster>
    vlan:
      tag: 1019
```

Step 2 of the phase 3 prerequisites is re-applied with the trunk host veth
`host-t-<cluster>` added as a second port, same `vlan` block as the dummy. It
must run after the `L2Trunk` exists (nmstate can only name a port that already
exists). Both `allow-extra-ports: true` and the dummy port stay on that apply,
and the four VM-side veths are never listed — their names are generated by the
CNI plugin.

```yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: qe-<cluster>-br
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ""
  desiredState:
    interfaces:
      - name: br-<cluster>
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
          allow-extra-ports: true
          port:
            - name: dmy-<cluster>
              vlan:
                mode: trunk
                trunk-tags:
                  - id-range:
                      min: 1000
                      max: 1019
            - name: host-t-<cluster>
              vlan:
                mode: trunk
                trunk-tags:
                  - id-range:
                      min: 1000
                      max: 1019
      - name: dmy-<cluster>
        type: dummy
        state: up
        mtu: <mtu>
```

This apply must land on every worker a guest node may run on or migrate to,
before any migration targets it.

`NodePool` is the same as in phase 2.

## Teardown

Reverse of setup, so a bridge is never removed under running VMs:

1. `HostedCluster` and `NodePool`, wait for the virt-launcher pods to go.
2. Delete the `<guest-ns>` namespace — this removes the OpenPERouter CRs and the
   NADs together.
3. Delete the bridge NNCP(s); this removes the bridge, the dummy port and the
   trunk port membership.
4. Check that `RouterNodeConfigurationStatus` reports no `failedResources`.

## Open questions

- **Guest namespace ownership.** The recipe assumes the framework creates
  `clusters-<cluster>`, because HyperShift creates it only together with the
  `HostedCluster`. If the namespace has to be admin-owned like the NNCPs and
  NADs, the namespace manifest moves to the prerequisites and the recipe only
  references it.
- **Trunk host veth name.** The phase 3 re-apply names the trunk port
  `host-t-<cluster>`. Nothing derives that name from an `L2Trunk` today, so the
  policy cannot be generated until trunk support defines it (derived from
  `L2Trunk` vs. configured explicitly). The 8-character token limit exists
  because of this name.
