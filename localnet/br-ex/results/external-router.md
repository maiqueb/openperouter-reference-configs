# External Router Results

## BGP Summary

```
$ oc exec -n openshift-openperouter router-nqmkg -c frr -- vtysh -c "show bgp l2vpn evpn summary"
BGP router identifier 10.0.0.2, local AS number 64514 vrf-id 0
BGP table version 0
RIB entries 9, using 1728 bytes of memory
Peers 1, using 725 KiB of memory

Neighbor        V         AS   MsgRcvd   MsgSent   TblVer  InQ OutQ  Up/Down State/PfxRcd   PfxSnt Desc
10.100.11.4     4      64512       309       311        0    0    0 04:52:39           11       21 N/A

Total number of neighbors 1

$ podman exec frr vtysh -c "show bgp l2vpn evpn summary"
BGP router identifier 100.64.0.1, local AS number 64512 VRF default vrf-id 0
BGP table version 0
RIB entries 11, using 1672 bytes of memory
Peers 2, using 33 KiB of memory
Peer groups 1, using 64 bytes of memory

Neighbor        V         AS   MsgRcvd   MsgSent   TblVer  InQ OutQ  Up/Down State/PfxRcd   PfxSnt Desc
*10.100.11.50   4      64514       311       309        7    0    0 04:52:40           10       18 N/A
*10.100.11.51   4      64514       311       309        7    0    0 04:52:34           10       18 N/A

Total number of neighbors 2
* - dynamic neighbor
2 dynamic neighbor(s), limit 100
```

## EVPN Type-2 Routes

```
$ podman exec frr vtysh -c "show bgp l2vpn evpn route type 2"
BGP table version is 7, local router ID is 100.64.0.1
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
     [2]:[0]:[48]:[00:f3:00:00:00:6f]:[32]:[192.170.1.1] RD 10.0.0.2:3
                    10.0.0.2                               0 64514 i
                    RT:64514:100 RT:64514:110 ET:8 Rmac:b6:dc:b2:ae:43:dd
     [2]:[0]:[48]:[00:f3:00:00:00:6f]:[128]:[fe80::5cf1:80ff:fe07:10dd] RD 10.0.0.2:3
                    10.0.0.2                               0 64514 i
                    RT:64514:110 ET:8
 *>  [2]:[0]:[48]:[0a:58:c0:aa:01:0a] RD 10.0.0.2:3
                    100.65.0.1                             0 64514 i
                    RT:64514:110 ET:8
 *>  [2]:[0]:[48]:[0a:58:c0:aa:01:0a]:[32]:[192.170.1.10] RD 10.0.0.2:3
                    100.65.0.1                             0 64514 i
                    RT:64514:100 RT:64514:110 ET:8 Rmac:aa:a2:f1:ce:85:b7
 *>  [2]:[0]:[48]:[0a:58:c0:aa:01:0a]:[128]:[fe80::858:c0ff:feaa:10a] RD 10.0.0.2:3
                    100.65.0.1                             0 64514 i
                    RT:64514:110 ET:8
 *>  [2]:[0]:[48]:[7e:8c:50:0a:0b:fa] RD 10.0.0.2:3
                    100.65.0.1                             0 64514 i
                    RT:64514:110 ET:8
 *>  [2]:[0]:[48]:[7e:8c:50:0a:0b:fa]:[128]:[fe80::7c8c:50ff:fe0a:bfa] RD 10.0.0.2:3
                    100.65.0.1                             0 64514 i
                    RT:64514:110 ET:8
 *>  [2]:[0]:[48]:[ee:a3:eb:4a:5e:44] RD 10.0.0.2:3
                    100.65.0.1                             0 64514 i
                    RT:64514:110 ET:8
Route Distinguisher: 10.0.0.3:3
     [2]:[0]:[48]:[00:f3:00:00:00:6f]:[32]:[192.170.1.1] RD 10.0.0.3:3
                    10.0.0.3                               0 64514 i
                    RT:64514:100 RT:64514:110 ET:8 Rmac:b6:b0:dd:38:fb:94
     [2]:[0]:[48]:[00:f3:00:00:00:6f]:[128]:[fe80::6ca6:c9ff:fef0:a8eb] RD 10.0.0.3:3
                    10.0.0.3                               0 64514 i
                    RT:64514:110 ET:8
 *>  [2]:[0]:[48]:[0a:58:c0:aa:01:14] RD 10.0.0.3:3
                    100.65.0.2                             0 64514 i
                    RT:64514:110 ET:8
 *>  [2]:[0]:[48]:[0a:58:c0:aa:01:14]:[32]:[192.170.1.20] RD 10.0.0.3:3
                    100.65.0.2                             0 64514 i
                    RT:64514:100 RT:64514:110 ET:8 Rmac:42:4e:f9:2f:40:cd
 *>  [2]:[0]:[48]:[0a:58:c0:aa:01:14]:[128]:[fe80::858:c0ff:feaa:114] RD 10.0.0.3:3
                    100.65.0.2                             0 64514 i
                    RT:64514:110 ET:8
 *>  [2]:[0]:[48]:[42:3c:80:23:46:4e] RD 10.0.0.3:3
                    100.65.0.2                             0 64514 i
                    RT:64514:110 ET:8
 *>  [2]:[0]:[48]:[6a:f3:b2:62:a5:c9] RD 10.0.0.3:3
                    100.65.0.2                             0 64514 i
                    RT:64514:110 ET:8
 *>  [2]:[0]:[48]:[6a:f3:b2:62:a5:c9]:[128]:[fe80::68f3:b2ff:fe62:a5c9] RD 10.0.0.3:3
                    100.65.0.2                             0 64514 i
                    RT:64514:110 ET:8
Route Distinguisher: 100.64.0.1:3
 *>  [2]:[0]:[48]:[ca:43:ad:ce:09:2a]:[32]:[192.170.1.100] RD 100.64.0.1:3
                    100.64.0.1                         32768 i
                    ET:8 RT:64512:110 RT:64512:100 Rmac:aa:bb:cc:00:00:65

Displayed 17 prefixes (17 paths) (of requested type)
```
