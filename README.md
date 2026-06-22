# openperouter-reference-configs
Reference configuration for open pe router

## OpenShift cluster
Use kcli to spin up the OpenShift cluster. These are the parameters I'm using:
```bash
kcli create cluster openshift --pf <path to params file> multi-homing \
    -P version=stable \
    -P tag=4.22.1 \
    -P sslip=true \
    -P pull_secret=<path to pull secret> \
    -P ctlplanes=1 \
    -P workers=2
```

**NOTE:** I create 2 libvirt networks using `kcli` to plumb into the nodes.
For that, I use:
```bash
kcli create network -c 10.100.0.0/16 net1
kcli create network -c 10.200.0.0/16 net2
```

Once you have the cluster running, you need to deploy the following
dependencies:
- kubernetes-nmstate
- openshift-virtualization
- open pe router

## External router
The OpenShift cluster above implements the OpenShift nodes as libvirt VMs
running in your hypervisor.

We will implement the external router using a podman container, also in this
hypervisor. To interconnect both these technologies (libvirt and podman) we
will expose the libvirt networks we have created in the
[OpenShift cluster](#openshift-cluster) section to podman.

### Networking setup

Expose the libvirt networks to podman:
```bash
podman network create \
    --interface-name net1 \
    --opt mode=unmanaged \
    --disable-dns \
    --subnet 10.100.0.0/16 \
    --ip-range 10.100.11.0/24 \
    net1-ex

podman network create \
    --interface-name net2 \
    --opt mode=unmanaged \
    --disable-dns \
    --subnet 10.200.0.0/16 \
    --ip-range 10.200.11.0/24 \
    net2-ex
```

Create an isolated network so the external router and the external client can
communicate:
```bash
podman network create \
    --subnet 192.169.1.0/24 \
    --driver macvlan \
    my-isolated-network
```

### Building the external router image

The container image is built from the
[Containerfile](external-router/Containerfile). It extends the FRR base image
with an entrypoint script ([hack/setup-frr-router-red-vrf.sh](hack/setup-frr-router-red-vrf.sh))
that creates the VRF, VXLAN tunnel, and bridge devices on startup, then waits
in the background.

The build must be run from the **repository root** so that the build context
includes the `hack/` directory:
```bash
podman build -f external-router/Containerfile -t frr-router .
```

### Running the external router

The router connects to both the "isolated" network and the two OpenShift extra
networks:
```bash
podman run -d --privileged \
    --network net1-ext \
    --network net2-ext \
    --network my-isolated-network \
    --rm \
    --ulimit core=-1 \
    --name frr \
    --volume "$FRR_CONFIG":/etc/frr \
    frr-router
```

**NOTE:** `FRR_CONFIG` should point to a directory holding the
[external-router](/external-router) folder's contents.

### Running the external client

```bash
podman run -it -d \
    --name client \
    --network my-isolated-network \
    --entrypoint="bash" \
    --privileged \
    k8s.gcr.io/e2e-test-images/agnhost:2.45
```

