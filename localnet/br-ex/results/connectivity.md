# Connectivity Results

## Test Pods

```
$ oc get pods -n evpn-localnet-test -o wide
NAME               READY   STATUS    RESTARTS   AGE     IP            NODE                                NOMINATED NODE   READINESS GATES
test-localnet-w1   1/1     Running   0          4h54m   10.134.0.29   multi-homing-worker-0.ralavi.corp   <none>           <none>
test-localnet-w2   1/1     Running   0          4h54m   10.133.0.20   multi-homing-worker-1.ralavi.corp   <none>           <none>
```

## Pod Interfaces

```
$ oc exec -n evpn-localnet-test test-localnet-w1 -- ip addr show net1
3: net1@if42: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1400 qdisc noqueue state UP group default qlen 1000
    link/ether 0a:58:c0:aa:01:0a brd ff:ff:ff:ff:ff:ff link-netnsid 0
    inet 192.170.1.10/24 brd 192.170.1.255 scope global net1
       valid_lft forever preferred_lft forever
    inet6 fd00::a:1/64 scope global 
       valid_lft forever preferred_lft forever
    inet6 fe80::858:c0ff:feaa:10a/64 scope link 
       valid_lft forever preferred_lft forever

$ oc exec -n evpn-localnet-test test-localnet-w2 -- ip addr show net1
3: net1@if33: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1400 qdisc noqueue state UP group default qlen 1000
    link/ether 0a:58:c0:aa:01:14 brd ff:ff:ff:ff:ff:ff link-netnsid 0
    inet 192.170.1.20/24 brd 192.170.1.255 scope global net1
       valid_lft forever preferred_lft forever
    inet6 fd00::a:2/64 scope global 
       valid_lft forever preferred_lft forever
    inet6 fe80::858:c0ff:feaa:114/64 scope link 
       valid_lft forever preferred_lft forever
```

## Primary Network (cross-worker pod-to-pod)

```
$ oc exec -n evpn-localnet-test test-localnet-w1 -- ping -c 3 -W 2 10.133.0.20
PING 10.133.0.20 (10.133.0.20) 56(84) bytes of data.
64 bytes from 10.133.0.20: icmp_seq=1 ttl=62 time=6.32 ms
64 bytes from 10.133.0.20: icmp_seq=2 ttl=62 time=2.21 ms
64 bytes from 10.133.0.20: icmp_seq=3 ttl=62 time=0.918 ms

--- 10.133.0.20 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2003ms
rtt min/avg/max/mdev = 0.918/3.148/6.315/2.300 ms
```

## Stretched L2 — IPv4 (cross-worker via net1 on 192.170.1.0/24)

```
$ oc exec -n evpn-localnet-test test-localnet-w1 -- ping -c 3 -W 2 192.170.1.20
PING 192.170.1.20 (192.170.1.20) 56(84) bytes of data.
64 bytes from 192.170.1.20: icmp_seq=1 ttl=64 time=2.40 ms
64 bytes from 192.170.1.20: icmp_seq=2 ttl=64 time=0.753 ms
64 bytes from 192.170.1.20: icmp_seq=3 ttl=64 time=0.674 ms

--- 192.170.1.20 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2046ms
rtt min/avg/max/mdev = 0.674/1.274/2.396/0.793 ms
```

## Stretched L2 — IPv6 (cross-worker via net1 on fd00::a:x/64)

```
$ oc exec -n evpn-localnet-test test-localnet-w1 -- ping6 -c 3 -W 2 fd00::a:2
PING fd00::a:2 (fd00::a:2) 56 data bytes
64 bytes from fd00::a:2: icmp_seq=1 ttl=64 time=3.94 ms
64 bytes from fd00::a:2: icmp_seq=2 ttl=64 time=0.823 ms
64 bytes from fd00::a:2: icmp_seq=3 ttl=64 time=0.748 ms

--- fd00::a:2 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2009ms
rtt min/avg/max/mdev = 0.748/1.836/3.938/1.486 ms
```

## Stretched L2 — External FRR to pod (via br110/VNI 110 VXLAN tunnel)

```
$ podman exec frr ping -c 3 -W 3 -I br110 192.170.1.10
PING 192.170.1.10 (192.170.1.10): 56 data bytes
64 bytes from 192.170.1.10: seq=0 ttl=64 time=2.944 ms
64 bytes from 192.170.1.10: seq=1 ttl=64 time=0.484 ms

--- 192.170.1.10 ping statistics ---
2 packets transmitted, 2 packets received, 0% packet loss
round-trip min/avg/max = 0.484/1.714/2.944 ms
```

## L3 routing — External client to pod (cross-subnet via L3VNI)

Status: **NOT WORKING**

The routing and EVPN type-5 routes exist on both sides. VXLAN incoming packets
arrive at the worker (vni100 RX increments). However, the outbound L3VNI
encapsulation on the return path does not work — the Linux bridge does not
forward the reply frame to the vni100 VXLAN device despite correct FDB entries.

```
$ podman exec external-client ping -c 3 -W 5 192.170.1.10
PING 192.170.1.10 (192.170.1.10): 56 data bytes

--- 192.170.1.10 ping statistics ---
3 packets transmitted, 0 packets received, 100% packet loss
```

Worker VRF red has the correct route to the external client subnet:
```
$ oc exec -n openshift-openperouter <router-pod> -c frr -- vtysh -c "show ip route vrf red"
VRF red:
B>* 192.169.1.0/24 [20/0] via 100.64.0.1, br-pe-100 onlink, weight 1, 05:06:53
```

Investigation shows vni100 TX does not increment on the reply path. This appears
to be a Linux kernel bridge/VXLAN symmetric IRB forwarding issue on kernel
5.14.0-687.15.1.el9_8.x86_64. To be investigated further with Miguel.
