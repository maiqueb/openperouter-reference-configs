#! /bin/bash

SCRIPT_PATH=$(dirname "$(realpath "$0")")

OUT_DIR="${OUT_DIR:-$SCRIPT_PATH}"
NAMESPACE="${NAMESPACE:-openshift-openperouter}"

run_section() {
    local -r cmd="$1"
    echo '```bash'
    echo "$ $cmd"
    eval $cmd
    echo '```'
    echo
}

validate_targets() {
  if [[ -z "$targets" ]]; then
    echo "targets is empty"
    return 1
  fi
  
  for target in $targets; do
    target_type="${target%%:*}"
    target_name="${target#*:}"
    if [[ $type != "k8s" && $type != "podman" ]]; then
        echo "FATAL: unknown target type [$type] for [$target], expected 'k8s', 'podman'"
        exist 1
    fi
    if [[ $type == "k8s" ]]; then
        if ! $(oc -n $NAMESPACE get po -l app=router -o wide | grep -qe $name); then
          echo "FATAL: no router pod found for node [$name]"
          exit 1
        fi
        ROUTER_POD=$(echo "$ROUTER_POD" | awk '{print $1}')
    fi
    if [[ $type == "podman" ]]; then
        if ! $(podman ps | grep -qw $name); then
          echo "FATAL: no podman container found for [$name]"
          exit 1
        fi
    fi
  done
}

gen_target_report() {
  local -r type="$1"
  local -r name="$2"
  local -r title="$3"
  local -r out_file="$4"
 
  local target_show=""
  local target_exec=""
  if [[ $type = "k8s" ]]; then
    router_pod=$(oc -n $NAMESPACE get po -l app=router -o wide | grep $name | awk '{print $1}')
    target_show="oc -n $NAMESPACE get po $router_pod -o wide"
    target_exec="oc -n $NAMESPACE exec -it $router_pod --"
  fi
  if [[ $type = "podman" ]]; then
    target_show="podman ps | grep $name"
    target_exec="podman exec -it $name"
  fi
  
  echo "INFO: Generating results for $type target [$name] to [$out_file]"
  {
    echo "# ${title}"
    echo ""
    run_section "$target_show"
    echo "## Addresses" 
    run_section "$target_exec ip -color=never addr"
    echo "## Routes"
    run_section "$target_exec ip -color=never route"
    echo "## Neighbors"
    run_section "$target_exec ip -color=never nei"
    echo "### Bridge FDBs"
    run_section "$target_exec bridge -color=never fdb show"

    if [[ -n $($target_exec ip link show type vrf) ]]; then
      local -r vrfs="$($target_exec ip -color=never vrf show | tail -n +3 | awk '{print $1}')"
      for vrf in $vrfs; do
        echo "## Routes vrf: [$vrf]"
        run_section "$target_exec ip -color=never route show vrf $vrf"
        echo "## Neighbors vrf [$vrf]"
        run_section "$target_exec ip -color=never neigh show vrf $vrf"
      done
    fi

    if $target_exec which vtysh &> /dev/null; then
      echo "## BGP IPv4 Summary"
      run_section "$target_exec vtysh -c 'show bgp ipv4'"
      echo "## BGP L2VPN EVPN Summary"
      run_section "$target_exec vtysh -c 'show bgp l2vpn evpn summary'"
      echo "## EVPN Type-2 Routes"
      run_section "$target_exec vtysh -c 'show bgp l2vpn evpn route type 2'"
      echo "## EVPN Type-5 Routes"
      run_section "$target_exec vtysh -c 'show bgp l2vpn evpn route type 5'"
      echo "## BGP Neighbors"
      run_section "$target_exec vtysh -c 'show bgp nei'"

      echo "### EVPN VNI Summary"
      run_section "$target_exec vtysh -c 'show evpn vni'"

      local vnis="$($target_exec vtysh -c 'show evpn vni' | awk '{print $1}' | tail -n +2)"
      for vni in $vnis; do
        echo "### EVPN VNI [$vni]"
        run_section "$target_exec vtysh -c 'show evpn vni $vni json'"
      done
    fi
  } > "$out_file"
}

mkdir -p $OUT_DIR

gen_target_report "podman"   "external-client"   "external-client" "${OUT_DIR}/external-client.md"
gen_target_report "podman"        "frr"          "external router" "${OUT_DIR}/external-router.md"
gen_target_report "k8s"    "multi-homing-worker-0.maiqueb.org" "worker-0"        "${OUT_DIR}/worker-0.md"
gen_target_report "k8s"    "multi-homing-worker-1.maiqueb.org" "worker-1"        "${OUT_DIR}/worker-1.md"
