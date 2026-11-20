#!/bin/bash

# this is to avoid to loose the ipv6 address after enslaving to the vrf
sysctl -w net.ipv6.conf.all.keep_addr_on_down=1

# VTEP IP
ip addr add 100.64.0.1/32 dev lo

ip link add red type vrf table 1100

# External-client leg. With the recommended podman invocation:
#   --network default-network --network net1-ext --network my-isolated-network
# eth0 is the default network, eth1 is net1-ext (the BGP underlay, which must
# stay in the default VRF), and eth2 is the isolated external-client network.
# Override CLIENT_NIC if podman names the interfaces differently.
CLIENT_NIC="${CLIENT_NIC:-eth2}"
if ! ip link show "$CLIENT_NIC" >/dev/null 2>&1; then
  echo "FATAL: external-client NIC [$CLIENT_NIC] not found; set CLIENT_NIC" >&2
  exit 1
fi
ip link set "$CLIENT_NIC" master red

ip link set red up
ip link add br100 type bridge
ip link set br100 master red addrgenmode none
ip link set br100 addr aa:bb:cc:00:00:65
ip link add vni100 type vxlan local 100.64.0.1 dstport 4789 id 100 nolearning
ip link set vni100 master br100 addrgenmode none
ip link set vni100 type bridge_slave neigh_suppress on learning off
ip link set vni100 up
ip link set br100 up

/usr/lib/frr/frrinit.sh start
sleep infinity

