# Worker-0 Results

## OVS Topology

```
$ oc debug node/multi-homing-worker-0.ralavi.corp -- chroot /host ovs-vsctl show
d9631aa8-b201-4fd8-b2ae-3a90aa0c6eb8
    Bridge ovsbr1
        Port ovsbr1
            Interface ovsbr1
                type: internal
        Port patch-evpn_ovn_localnet_port-to-br-int
            Interface patch-evpn_ovn_localnet_port-to-br-int
                type: patch
                options: {peer=patch-br-int-to-evpn_ovn_localnet_port}
        Port host-110
            Interface host-110
                type: system
    Bridge br-ex
        Port ens3
            Interface ens3
                type: system
        Port br-ex
            Interface br-ex
                type: internal
        Port patch-br-ex_multi-homing-worker-0.ralavi.corp-to-br-int
            Interface patch-br-ex_multi-homing-worker-0.ralavi.corp-to-br-int
                type: patch
                options: {peer=patch-br-int-to-br-ex_multi-homing-worker-0.ralavi.corp}
    Bridge br-int
        fail_mode: secure
        datapath_type: system
        Port f6dafcedf67eaaf
            Interface f6dafcedf67eaaf
        Port "716ed5f4bbca0c6"
            Interface "716ed5f4bbca0c6"
        Port "1c409b5505377c7"
            Interface "1c409b5505377c7"
        Port eb5a1eebf544bbe
            Interface eb5a1eebf544bbe
        Port "634dc86782c5ce3"
            Interface "634dc86782c5ce3"
        Port "1b789df87f5869e"
            Interface "1b789df87f5869e"
        Port "0e6136dc454b860"
            Interface "0e6136dc454b860"
        Port f3c9f79a23b1e2f
            Interface f3c9f79a23b1e2f
        Port "6295d6ee823faec"
            Interface "6295d6ee823faec"
        Port ec2a7fb8b8d0ccf
            Interface ec2a7fb8b8d0ccf
        Port eecfbbf003d6335
            Interface eecfbbf003d6335
        Port patch-br-int-to-br-ex_multi-homing-worker-0.ralavi.corp
            Interface patch-br-int-to-br-ex_multi-homing-worker-0.ralavi.corp
                type: patch
                options: {peer=patch-br-ex_multi-homing-worker-0.ralavi.corp-to-br-int}
        Port fae09279af57581
            Interface fae09279af57581
        Port "66a30ba00d02a6c"
            Interface "66a30ba00d02a6c"
        Port "7ee6b4ac422e565"
            Interface "7ee6b4ac422e565"
        Port ovn-3730fb-0
            Interface ovn-3730fb-0
                type: geneve
                options: {csum="true", key=flow, local_ip="192.168.122.155", remote_ip="192.168.122.33"}
        Port ovn-k8s-mp0
            Interface ovn-k8s-mp0
                type: internal
        Port br-int
            Interface br-int
                type: internal
        Port f2d30e527675ab9
            Interface f2d30e527675ab9
        Port ovn-7ff036-0
            Interface ovn-7ff036-0
                type: geneve
                options: {csum="true", key=flow, local_ip="192.168.122.155", remote_ip="192.168.122.227"}
        Port "848e1c23699e413"
            Interface "848e1c23699e413"
        Port fdaadcf6883f161
            Interface fdaadcf6883f161
        Port patch-br-int-to-evpn_ovn_localnet_port
            Interface patch-br-int-to-evpn_ovn_localnet_port
                type: patch
                options: {peer=patch-evpn_ovn_localnet_port-to-br-int}
        Port d34127a551d55db
            Interface d34127a551d55db
        Port fae09279af575_3
            Interface fae09279af575_3
    ovs_version: "3.5.2-72.el9fdp"
```

## Bridge Mappings

```
$ oc debug node/multi-homing-worker-0.ralavi.corp -- chroot /host ovs-vsctl get open . external_ids:ovn-bridge-mappings
"datanet:ovsbr1,physnet:br-ex"
```

## EVPN Type-2 Routes

```
$ oc exec -n openshift-openperouter router-nqmkg -c frr -- vtysh -c "show bgp l2vpn evpn route type 2"
BGP table version is 9, local router ID is 10.0.0.2
Status codes: s suppressed, d damped, h history, * valid, > best, i - internal
Origin codes: i - IGP, e - EGP, ? - incomplete
EVPN type-1 prefix: [1]:[EthTag]:[ESI]:[IPlen]:[VTEP-IP]:[Frag-id]
EVPN type-2 prefix: [2]:[EthTag]:[MAClen]:[MAC]:[IPlen]:[IP]
EVPN type-3 prefix: [3]:[EthTag]:[IPlen]:[OrigIP]
EVPN type-4 prefix: [4]:[ESI]:[IPlen]:[OrigIP]
EVPN type-5 prefix: [5]:[EthTag]:[IPlen]:[IP]

   Network          Next Hop            Metric LocPrf Weight Path
                    Extended Community
Route Distinguisher: 10.0.0.2:3
 *> [2]:[0]:[48]:[00:f3:00:00:00:6f]:[32]:[192.170.1.1]
                    10.0.0.2                           32768 i
                    ET:8 RT:64514:110 RT:64514:100 Rmac:b6:dc:b2:ae:43:dd
 *> [2]:[0]:[48]:[00:f3:00:00:00:6f]:[128]:[fe80::5cf1:80ff:fe07:10dd]
                    10.0.0.2                           32768 i
                    ET:8 RT:64514:110
 *> [2]:[0]:[48]:[0a:58:c0:aa:01:0a]
                    100.65.0.1                         32768 i
                    ET:8 RT:64514:110
 *> [2]:[0]:[48]:[0a:58:c0:aa:01:0a]:[32]:[192.170.1.10]
                    100.65.0.1                         32768 i
                    ET:8 RT:64514:110 RT:64514:100 Rmac:aa:a2:f1:ce:85:b7
 *> [2]:[0]:[48]:[0a:58:c0:aa:01:0a]:[128]:[fe80::858:c0ff:feaa:10a]
                    100.65.0.1                         32768 i
                    ET:8 RT:64514:110
 *> [2]:[0]:[48]:[7e:8c:50:0a:0b:fa]
                    100.65.0.1                         32768 i
                    ET:8 RT:64514:110
 *> [2]:[0]:[48]:[7e:8c:50:0a:0b:fa]:[128]:[fe80::7c8c:50ff:fe0a:bfa]
                    100.65.0.1                         32768 i
                    ET:8 RT:64514:110
 *> [2]:[0]:[48]:[ee:a3:eb:4a:5e:44]
                    100.65.0.1                         32768 i
                    ET:8 RT:64514:110
Route Distinguisher: 10.0.0.3:3
 *> [2]:[0]:[48]:[0a:58:c0:aa:01:14]
                    100.65.0.2                             0 64512 64514 i
                    RT:64514:110 ET:8
 *> [2]:[0]:[48]:[0a:58:c0:aa:01:14]:[32]:[192.170.1.20]
                    100.65.0.2                             0 64512 64514 i
                    RT:64514:100 RT:64514:110 ET:8 Rmac:42:4e:f9:2f:40:cd
 *> [2]:[0]:[48]:[0a:58:c0:aa:01:14]:[128]:[fe80::858:c0ff:feaa:114]
                    100.65.0.2                             0 64512 64514 i
                    RT:64514:110 ET:8
 *> [2]:[0]:[48]:[42:3c:80:23:46:4e]
                    100.65.0.2                             0 64512 64514 i
                    RT:64514:110 ET:8
 *> [2]:[0]:[48]:[6a:f3:b2:62:a5:c9]
                    100.65.0.2                             0 64512 64514 i
                    RT:64514:110 ET:8
 *> [2]:[0]:[48]:[6a:f3:b2:62:a5:c9]:[128]:[fe80::68f3:b2ff:fe62:a5c9]
                    100.65.0.2                             0 64512 64514 i
                    RT:64514:110 ET:8
Route Distinguisher: 100.64.0.1:3
 *> [2]:[0]:[48]:[ca:43:ad:ce:09:2a]:[32]:[192.170.1.100]
                    100.64.0.1                             0 64512 i
                    RT:64512:100 RT:64512:110 ET:8 Rmac:aa:bb:cc:00:00:65

Displayed 15 prefixes (15 paths) (of requested type)
```
