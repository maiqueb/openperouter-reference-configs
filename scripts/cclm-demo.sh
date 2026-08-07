#!/bin/bash
# Cross-Cluster Live Migration (CCLM) Demo Script
#
# Orchestrates live migration of a KubeVirt VM between two OpenShift clusters
# over an EVPN stretched L2 network, measuring connectivity and throughput impact.
#
# Prerequisites:
#   - OpenPERouter EVPN infrastructure already provisioned on both clusters
#   - EVPN NAD "evpn" in the target namespace on both clusters
#   - SSH access to both cluster nodes via beaker key
#   - FRR ToR router running as podman container "frr" on each cluster node
#   - External client running as podman container "client" on destination node
#
# Usage:
#   ./cclm-demo.sh setup              Create VMs on both clusters
#   ./cclm-demo.sh exchange-ca        Exchange kubevirt-ca certs between clusters
#   ./cclm-demo.sh demo-connectivity   Show L2 connectivity + external client access
#   ./cclm-demo.sh demo-migration      iperf3 sessions + migrate + analyze impact
#   ./cclm-demo.sh cleanup             Tear down all demo resources

set -euo pipefail

# ============================================================================
# Configuration (override via environment variables)
# ============================================================================
SRC_HOST="${SRC_HOST:-zeus22.lab.eng.tlv2.redhat.com}"
DST_HOST="${DST_HOST:-zeus20.lab.eng.tlv2.redhat.com}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/beaker}"
NS="${NS:-evpn-localnet-test}"
VM_IMAGE="${VM_IMAGE:-quay.io/kubevirt/fedora-with-test-tooling-container-disk:v1.7.0}"

VM_A_NAME="vm-a"
VM_A_IP="192.170.1.3"
VM_A_MAC="02:00:00:00:00:0a"

VM_MIGRATE_NAME="vm-migrate"
VM_MIGRATE_IP="192.170.1.10"
VM_MIGRATE_MAC="02:00:00:00:00:01"

VM_B_NAME="vm-b"
VM_B_IP="192.170.1.30"
VM_B_MAC="02:00:00:00:00:0b"

VM_GW="192.170.1.1"

EXT_CLIENT_CONTAINER="client"
EXT_CLIENT_HOST="$DST_HOST"

IPERF_DURATION="${IPERF_DURATION:-120}"

SRC_KUBECONFIG="${SRC_KUBECONFIG:-/root/.kube/config}"
DST_KUBECONFIG="${DST_KUBECONFIG:-/root/.kube/config}"

SSH_CTL_DIR="/tmp/cclm-ssh-ctl"
mkdir -p "$SSH_CTL_DIR"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  -o ControlMaster=auto -o ControlPath=$SSH_CTL_DIR/%r@%h:%p -o ControlPersist=600"

# ============================================================================
# Colors and output helpers
# ============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${YELLOW}> $1${NC}"; }
success() { echo -e "${GREEN}✓ $1${NC}"; }
fail()    { echo -e "${RED}✗ $1${NC}"; }

header() {
    echo ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}================================================================${NC}"
    echo ""
}

pause() {
    echo ""
    echo -e "${YELLOW}Press Enter to continue...${NC}"
    read -r
}

# ============================================================================
# Remote access helpers
# ============================================================================
src_ssh() { ssh -i "$SSH_KEY" $SSH_OPTS root@"$SRC_HOST" "$@"; }
dst_ssh() { ssh -i "$SSH_KEY" $SSH_OPTS root@"$DST_HOST" "$@"; }
src_oc()  { src_ssh "oc --kubeconfig=$SRC_KUBECONFIG $*"; }
dst_oc()  { dst_ssh "oc --kubeconfig=$DST_KUBECONFIG $*"; }
src_tor() { src_ssh "podman exec frr vtysh -c '$*'"; }
dst_tor() { dst_ssh "podman exec frr vtysh -c '$*'"; }

# Verify KUBECONFIG files exist on the cluster nodes.
detect_kubeconfig() {
    src_ssh "test -f $SRC_KUBECONFIG" || { fail "KUBECONFIG not found at $SRC_KUBECONFIG on $SRC_HOST"; exit 1; }
    dst_ssh "test -f $DST_KUBECONFIG" || { fail "KUBECONFIG not found at $DST_KUBECONFIG on $DST_HOST"; exit 1; }
}

# Execute a command inside a VM via QEMU guest agent.
# $1 = ssh function name (src_ssh or dst_ssh)
# $2 = VM name
# $3 = command string to run inside the VM
vm_exec() {
    local ssh_fn="$1" vm="$2" cmd="$3"
    local kc="$SRC_KUBECONFIG"
    [[ "$ssh_fn" == "dst_ssh" ]] && kc="$DST_KUBECONFIG"
    $ssh_fn "/tmp/cclm-vm-exec.sh $kc $NS $vm '$cmd'"
}

deploy_vm_exec_helper() {
    local helper='#!/bin/bash
KC="$1" NS="$2" VM="$3" CMD="$4"
POD=$(oc --kubeconfig="$KC" get pods -n "$NS" -l "kubevirt.io/vm=$VM" -o jsonpath="{.items[0].metadata.name}" 2>/dev/null)
if [[ -z "$POD" ]]; then echo "ERROR: No pod for VM $VM" >&2; exit 1; fi
CMD_ESC=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$CMD")
RESULT=$(oc --kubeconfig="$KC" exec -n "$NS" "$POD" -- \
    virsh qemu-agent-command 1 \
    "{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"/bin/sh\",\"arg\":[\"-c\",$CMD_ESC],\"capture-output\":true}}" 2>/dev/null)
PID=$(python3 -c "import json,sys; print(json.load(sys.stdin)[\"return\"][\"pid\"])" <<< "$RESULT")
for _ in $(seq 1 120); do
    STATUS=$(oc --kubeconfig="$KC" exec -n "$NS" "$POD" -- \
        virsh qemu-agent-command 1 \
        "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$PID}}" 2>/dev/null)
    DONE=$(python3 -c "import json,sys; print(json.load(sys.stdin)[\"return\"].get(\"exited\",False))" <<< "$STATUS")
    if [[ "$DONE" == "True" ]]; then
        python3 -c "
import json,sys,base64
r=json.load(sys.stdin)[\"return\"]
if \"out-data\" in r: sys.stdout.write(base64.b64decode(r[\"out-data\"]).decode())
if \"err-data\" in r: sys.stderr.write(base64.b64decode(r[\"err-data\"]).decode())
sys.exit(r.get(\"exitcode\",0))
" <<< "$STATUS"
        exit $?
    fi
    sleep 0.5
done
echo "ERROR: Timeout waiting for command in VM $VM" >&2; exit 1
'
    src_ssh "cat > /tmp/cclm-vm-exec.sh && chmod +x /tmp/cclm-vm-exec.sh" <<< "$helper"
    dst_ssh "cat > /tmp/cclm-vm-exec.sh && chmod +x /tmp/cclm-vm-exec.sh" <<< "$helper"
}

# ============================================================================
# VM manifest generator
# ============================================================================
gen_vm_manifest() {
    local name="$1" ip="$2" mac="$3" run_strategy="$4" nad_ref="$5"

    cat <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: $name
  namespace: $NS
EOF
    if [[ "$run_strategy" == "WaitAsReceiver" ]]; then
        cat <<EOF
  annotations:
    kubevirt.io/restore-run-strategy: Always
EOF
    fi
    cat <<EOF
spec:
  runStrategy: $run_strategy
  template:
    metadata:
      labels:
        kubevirt.io/vm: $name
    spec:
      domain:
        cpu:
          model: Nehalem
        devices:
          disks:
            - name: containerdisk
              disk: { bus: virtio }
            - name: cloudinitdisk
              disk: { bus: virtio }
          interfaces:
            - name: default
              masquerade: {}
            - name: evpn
              bridge: {}
              macAddress: "$mac"
        resources:
          requests:
            memory: 1Gi
      networks:
        - name: default
          pod: {}
        - name: evpn
          multus:
            networkName: $nad_ref
      terminationGracePeriodSeconds: 0
      volumes:
        - name: containerdisk
          containerDisk:
            image: $VM_IMAGE
        - name: cloudinitdisk
          cloudInitNoCloud:
            networkData: |
              version: 2
              ethernets:
                evpnnet:
                  match:
                    macaddress: "$mac"
                  set-name: eth1
                  addresses:
                    - $ip/24
                  routes:
                    - to: 0.0.0.0/0
                      via: $VM_GW
            userData: |
              #cloud-config
              password: fedora
              chpasswd: { expire: False }
              ssh_pwauth: True
              runcmd:
                - ['sh', '-c', 'ip route del default dev eth0 && ip route add default via 10.0.2.1 dev eth0 metric 200 || true']
EOF
}

# ============================================================================
# Wait helpers
# ============================================================================
wait_for_vmi_phase() {
    local ssh_fn="$1" vm_name="$2" expected="$3" timeout="${4:-300}"

    info "Waiting for $vm_name → $expected (timeout: ${timeout}s)..."
    local elapsed=0 phase=""
    while (( elapsed < timeout )); do
        phase=$($ssh_fn "oc get vmi $vm_name -n $NS -o jsonpath='{.status.phase}'" 2>/dev/null || echo "NotFound")
        phase="${phase//\'/}"
        if [[ "$phase" == "$expected" ]]; then
            success "$vm_name is $phase"
            return 0
        fi
        printf "."
        sleep 3
        (( elapsed += 3 )) || true
    done
    echo ""
    fail "Timeout: $vm_name stuck at '$phase', expected '$expected'"
    return 1
}

# ============================================================================
# KubeVirt CA exchange
# ============================================================================
CNV_NS="openshift-cnv"

exchange_kubevirt_ca() {
    info "Exchanging KubeVirt CA certificates between clusters..."

    local src_ca dst_ca
    src_ca=$(src_oc "get configmap kubevirt-ca -n $CNV_NS -o json") || {
        fail "Could not read kubevirt-ca configmap from source cluster ($CNV_NS namespace)"
        exit 1
    }

    dst_ca=$(dst_oc "get configmap kubevirt-ca -n $CNV_NS -o json") || {
        fail "Could not read kubevirt-ca configmap from destination cluster ($CNV_NS namespace)"
        exit 1
    }

    info "Applying source cluster CA as kubevirt-external-ca on destination cluster..."
    echo "$src_ca" \
        | python3 -c "
import json, sys
cm = json.load(sys.stdin)
cm['metadata'] = {'name': 'kubevirt-external-ca', 'namespace': '$CNV_NS'}
json.dump(cm, sys.stdout)
" | dst_oc "apply -f -"

    info "Applying destination cluster CA as kubevirt-external-ca on source cluster..."
    echo "$dst_ca" \
        | python3 -c "
import json, sys
cm = json.load(sys.stdin)
cm['metadata'] = {'name': 'kubevirt-external-ca', 'namespace': '$CNV_NS'}
json.dump(cm, sys.stdout)
" | src_oc "apply -f -"

    success "KubeVirt CA certificates exchanged between clusters"
}

# ============================================================================
# setup
# ============================================================================
do_setup() {
    header "SETUP: Creating VMs on both clusters"

    detect_kubeconfig
    deploy_vm_exec_helper

    info "Ensuring namespace '$NS' exists..."
    src_oc "create ns $NS" 2>/dev/null || true
    dst_oc "create ns $NS" 2>/dev/null || true

    exchange_kubevirt_ca

    info "Verifying EVPN NAD on both clusters..."
    local nad_err
    if ! nad_err=$(src_oc "get net-attach-def evpn -n $NS" 2>&1); then
        fail "NAD 'evpn' check failed on source cluster:"
        echo "  $nad_err"
        exit 1
    fi
    if ! nad_err=$(dst_oc "get net-attach-def evpn -n $NS" 2>&1); then
        fail "NAD 'evpn' check failed on destination cluster:"
        echo "  $nad_err"
        exit 1
    fi
    success "EVPN NAD present on both clusters"

    # --- Cluster A VMs ---
    info "Creating $VM_A_NAME on source cluster (A)..."
    gen_vm_manifest "$VM_A_NAME" "$VM_A_IP" "$VM_A_MAC" "Always" "evpn" \
        | src_oc "apply -f -"

    info "Creating $VM_MIGRATE_NAME on source cluster (A)..."
    gen_vm_manifest "$VM_MIGRATE_NAME" "$VM_MIGRATE_IP" "$VM_MIGRATE_MAC" "Always" "evpn" \
        | src_oc "apply -f -"

    # --- Cluster B VMs ---
    info "Creating $VM_B_NAME on destination cluster (B)..."
    gen_vm_manifest "$VM_B_NAME" "$VM_B_IP" "$VM_B_MAC" "Always" "evpn" \
        | dst_oc "apply -f -"

    info "Creating $VM_MIGRATE_NAME receiver on destination cluster (B)..."
    gen_vm_manifest "$VM_MIGRATE_NAME" "$VM_MIGRATE_IP" "$VM_MIGRATE_MAC" "WaitAsReceiver" "$NS/evpn" \
        | dst_oc "apply -f -"

    # --- Wait for readiness ---
    wait_for_vmi_phase src_ssh "$VM_A_NAME" "Running"
    wait_for_vmi_phase src_ssh "$VM_MIGRATE_NAME" "Running"
    wait_for_vmi_phase dst_ssh "$VM_B_NAME" "Running"

    info "Verifying $VM_MIGRATE_NAME receiver on destination cluster..."
    local strategy
    strategy=$(dst_oc "get vm $VM_MIGRATE_NAME -n $NS -o jsonpath='{.spec.runStrategy}'" 2>/dev/null)
    strategy="${strategy//\'/}"
    if [[ "$strategy" == "WaitAsReceiver" ]]; then
        success "$VM_MIGRATE_NAME receiver is parked (WaitAsReceiver)"
    else
        fail "Unexpected runStrategy: $strategy"
        exit 1
    fi

    header "VM Summary"
    printf "  ${CYAN}%-15s %-8s %-17s %-17s %s${NC}\n" "VM" "CLUSTER" "EVPN IP (eth1)" "MAC" "STATUS"
    printf "  %-15s %-8s %-17s %-17s %s\n" "───────────────" "────────" "─────────────────" "─────────────────" "──────────────"

    local vm_ip vm_phase
    for vm in "$VM_A_NAME" "$VM_MIGRATE_NAME"; do
        vm_ip=$(src_oc "get vmi $vm -n $NS -o jsonpath='{.status.interfaces[?(@.name==\"evpn\")].ipAddress}'" 2>/dev/null)
        vm_phase=$(src_oc "get vmi $vm -n $NS -o jsonpath='{.status.phase}'" 2>/dev/null)
        vm_ip="${vm_ip//\'/}"; vm_phase="${vm_phase//\'/}"
        local vm_mac="$VM_A_MAC"
        [[ "$vm" == "$VM_MIGRATE_NAME" ]] && vm_mac="$VM_MIGRATE_MAC"
        printf "  %-15s %-8s %-17s %-17s %s\n" "$vm" "A (src)" "${vm_ip:-n/a}" "$vm_mac" "${vm_phase:-n/a}"
    done

    vm_ip=$(dst_oc "get vmi $VM_B_NAME -n $NS -o jsonpath='{.status.interfaces[?(@.name==\"evpn\")].ipAddress}'" 2>/dev/null)
    vm_phase=$(dst_oc "get vmi $VM_B_NAME -n $NS -o jsonpath='{.status.phase}'" 2>/dev/null)
    vm_ip="${vm_ip//\'/}"; vm_phase="${vm_phase//\'/}"
    printf "  %-15s %-8s %-17s %-17s %s\n" "$VM_B_NAME" "B (dst)" "${vm_ip:-n/a}" "$VM_B_MAC" "${vm_phase:-n/a}"

    vm_phase=$(dst_oc "get vm $VM_MIGRATE_NAME -n $NS -o jsonpath='{.spec.runStrategy}'" 2>/dev/null)
    vm_phase="${vm_phase//\'/}"
    printf "  %-15s %-8s %-17s %-17s %s\n" "$VM_MIGRATE_NAME" "B (dst)" "$VM_MIGRATE_IP" "$VM_MIGRATE_MAC" "${vm_phase:-n/a}"

    echo ""
    success "Setup complete!"
}

# ============================================================================
# demo-connectivity
# ============================================================================
do_demo_connectivity() {
    detect_kubeconfig
    deploy_vm_exec_helper
    header "DEMO: Stretched L2 Connectivity"

    # --- EVPN Type-2 Routes ---
    header "Step 1: EVPN Type-2 Routes on ToR Routers"
    info "Source cluster ToR:"
    src_tor "show bgp l2vpn evpn route type 2" || true
    echo ""
    info "Destination cluster ToR:"
    dst_tor "show bgp l2vpn evpn route type 2" || true
    pause

    # --- L2 Ping Tests ---
    header "Step 2: Stretched L2 Ping Tests"
    local failures=0

    info "$VM_A_NAME ($VM_A_IP) -> $VM_MIGRATE_NAME ($VM_MIGRATE_IP) [same cluster A]"
    vm_exec src_ssh "$VM_A_NAME" "ping -I eth1 -c 3 -W 2 $VM_MIGRATE_IP" && success "reachable" || { fail "unreachable"; (( failures++ )); }
    echo ""

    info "$VM_A_NAME ($VM_A_IP) -> $VM_B_NAME ($VM_B_IP) [cross-cluster A -> B]"
    vm_exec src_ssh "$VM_A_NAME" "ping -I eth1 -c 3 -W 2 $VM_B_IP" && success "reachable" || { fail "unreachable"; (( failures++ )); }
    echo ""

    info "$VM_B_NAME ($VM_B_IP) -> $VM_MIGRATE_NAME ($VM_MIGRATE_IP) [cross-cluster B -> A]"
    vm_exec dst_ssh "$VM_B_NAME" "ping -I eth1 -c 3 -W 2 $VM_MIGRATE_IP" && success "reachable" || { fail "unreachable"; (( failures++ )); }
    echo ""

    info "$VM_MIGRATE_NAME ($VM_MIGRATE_IP) -> $VM_B_NAME ($VM_B_IP) [cross-cluster A -> B]"
    vm_exec src_ssh "$VM_MIGRATE_NAME" "ping -I eth1 -c 3 -W 2 $VM_B_IP" && success "reachable" || { fail "unreachable"; (( failures++ )); }
    echo ""

    if (( failures > 0 )); then
        fail "L2 connectivity: $failures test(s) failed"
    else
        success "L2 connectivity tests passed"
    fi
    pause

    # --- External Client Access ---
    header "Step 3: External Client Access (L3 routed)"

    info "External client -> $VM_A_NAME ($VM_A_IP):"
    ssh -i "$SSH_KEY" $SSH_OPTS root@"$EXT_CLIENT_HOST" \
        "podman exec $EXT_CLIENT_CONTAINER ping -c 3 -W 2 $VM_A_IP" \
        && success "reachable" || { fail "unreachable"; (( failures++ )); }
    echo ""

    info "External client -> $VM_MIGRATE_NAME ($VM_MIGRATE_IP):"
    ssh -i "$SSH_KEY" $SSH_OPTS root@"$EXT_CLIENT_HOST" \
        "podman exec $EXT_CLIENT_CONTAINER ping -c 3 -W 2 $VM_MIGRATE_IP" \
        && success "reachable" || { fail "unreachable"; (( failures++ )); }
    echo ""

    if (( failures > 0 )); then
        fail "Connectivity demo: $failures total test(s) failed"
        exit 1
    else
        success "All connectivity tests passed!"
    fi
}

# ============================================================================
# demo-migration
# ============================================================================
do_demo_migration() {
    detect_kubeconfig
    deploy_vm_exec_helper
    header "DEMO: Live Migration with iperf3 Impact Analysis"

    # --- Step 1: Start iperf3 servers ---
    header "Step 1: Start iperf3 Servers on $VM_MIGRATE_NAME"
    info "Starting iperf3 server on port 5201 (for $VM_A_NAME)..."
    vm_exec src_ssh "$VM_MIGRATE_NAME" "iperf3 -s -p 5201 -D" || true
    info "Starting iperf3 server on port 5202 (for $VM_B_NAME)..."
    vm_exec src_ssh "$VM_MIGRATE_NAME" "iperf3 -s -p 5202 -D" || true
    success "iperf3 servers running"
    pause

    # --- Step 2: Start iperf3 clients + continuous ping ---
    header "Step 2: Start iperf3 Clients and Continuous Ping"

    info "Starting iperf3 client on $VM_A_NAME -> $VM_MIGRATE_NAME:5201..."
    vm_exec src_ssh "$VM_A_NAME" \
        "nohup iperf3 -c $VM_MIGRATE_IP -p 5201 -t $IPERF_DURATION -i 1 --forceflush </dev/null > /tmp/iperf.log 2>&1 &" || true

    info "Starting iperf3 client on $VM_B_NAME -> $VM_MIGRATE_NAME:5202..."
    vm_exec dst_ssh "$VM_B_NAME" \
        "nohup iperf3 -c $VM_MIGRATE_IP -p 5202 -t $IPERF_DURATION -i 1 --forceflush </dev/null > /tmp/iperf.log 2>&1 &" || true

    info "Starting continuous ping from $VM_A_NAME -> $VM_MIGRATE_NAME (100ms interval)..."
    vm_exec src_ssh "$VM_A_NAME" \
        "nohup ping -I eth1 -i 0.1 $VM_MIGRATE_IP </dev/null > /tmp/ping.log 2>&1 &" || true

    success "Background traffic running"

    info "Establishing baseline (10s)..."
    sleep 10

    echo ""
    echo -e "${CYAN}Baseline iperf3 from $VM_A_NAME:${NC}"
    vm_exec src_ssh "$VM_A_NAME" "tail -3 /tmp/iperf.log" || true
    echo ""
    echo -e "${CYAN}Baseline iperf3 from $VM_B_NAME:${NC}"
    vm_exec dst_ssh "$VM_B_NAME" "tail -3 /tmp/iperf.log" || true
    pause

    # --- Step 3: Provision destination migration CR ---
    header "Step 3: Provision Destination Migration CR"

    local migration_id
    migration_id=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    info "Migration ID: $migration_id"

    info "Cleaning up stale migration objects..."
    src_oc "delete vmim --all -n $NS" 2>/dev/null || true
    dst_oc "delete vmim --all -n $NS" 2>/dev/null || true
    sleep 2

    info "Creating destination migration CR on cluster B..."
    cat <<EOF | dst_oc "apply -f -"
apiVersion: kubevirt.io/v1
kind: VirtualMachineInstanceMigration
metadata:
  name: vmim-target
  namespace: $NS
spec:
  receive:
    migrationID: "$migration_id"
  vmiName: $VM_MIGRATE_NAME
EOF

    info "Waiting for synchronization address..."
    local sync_addr=""
    for _ in $(seq 1 60); do
        sync_addr=$(dst_oc "get vmim vmim-target -n $NS -o jsonpath='{.status.synchronizationAddresses[0]}'" 2>/dev/null || echo "")
        sync_addr="${sync_addr//\'/}"
        if [[ -n "$sync_addr" ]]; then break; fi
        printf "."
        sleep 1
    done
    echo ""

    if [[ -z "$sync_addr" ]]; then
        fail "Failed to get synchronization address"
        dst_oc "get vmim vmim-target -n $NS -o yaml" || true
        exit 1
    fi

    success "Synchronization address: $sync_addr"
    echo ""
    echo -e "${CYAN}  Migration ID:            $migration_id${NC}"
    echo -e "${CYAN}  Synchronization Address: $sync_addr${NC}"
    pause

    # --- Step 4: Trigger migration ---
    header "Step 4: Trigger Migration"
    local migration_start
    migration_start=$(date +"%Y-%m-%d %H:%M:%S")

    info "Creating source migration CR on cluster A..."
    cat <<EOF | src_oc "apply -f -"
apiVersion: kubevirt.io/v1
kind: VirtualMachineInstanceMigration
metadata:
  name: vmim-source
  namespace: $NS
spec:
  sendTo:
    connectURL: "$sync_addr"
    migrationID: "$migration_id"
  vmiName: $VM_MIGRATE_NAME
EOF

    success "Migration triggered at $migration_start"
    pause

    # --- Step 5: Monitor migration ---
    header "Step 5: Monitor Migration Progress"
    echo -e "${CYAN}=== Real-time Status ===${NC}"
    echo ""

    local migration_done=false
    for _ in $(seq 1 90); do
        local ts src_mig dst_mig vmi_a vmi_b
        ts=$(date +"%H:%M:%S")
        src_mig=$(src_oc "get vmim vmim-source -n $NS -o jsonpath='{.status.phase}'" 2>/dev/null || echo "?")
        dst_mig=$(dst_oc "get vmim vmim-target -n $NS -o jsonpath='{.status.phase}'" 2>/dev/null || echo "?")
        vmi_a=$(src_oc "get vmi $VM_MIGRATE_NAME -n $NS -o jsonpath='{.status.phase}'" 2>/dev/null || echo "Gone")
        vmi_b=$(dst_oc "get vmi $VM_MIGRATE_NAME -n $NS -o jsonpath='{.status.phase}'" 2>/dev/null || echo "-")

        src_mig="${src_mig//\'/}"; dst_mig="${dst_mig//\'/}"
        vmi_a="${vmi_a//\'/}"; vmi_b="${vmi_b//\'/}"

        echo "[$ts] Migration: src=$src_mig dst=$dst_mig | VMI: A=$vmi_a B=$vmi_b"

        if [[ "$vmi_b" == "Running" ]] && { [[ "$vmi_a" == "Gone" ]] || [[ -z "$vmi_a" ]]; }; then
            echo ""
            success "Migration complete! $VM_MIGRATE_NAME is now running on cluster B"
            migration_done=true
            break
        fi

        sleep 2
    done

    if [[ "$migration_done" != "true" ]]; then
        fail "Migration did not complete within timeout"
    fi
    pause

    # --- Step 6: EVPN route convergence ---
    header "Step 6: EVPN Route Convergence"
    info "Source cluster ToR ($VM_MIGRATE_MAC should be withdrawn):"
    src_tor "show bgp l2vpn evpn route type 2" || true
    echo ""
    info "Destination cluster ToR ($VM_MIGRATE_MAC now local):"
    dst_tor "show bgp l2vpn evpn route type 2" || true
    pause

    # --- Step 7: Collect and analyze results ---
    header "Step 7: Post-Migration Analysis"

    info "Letting traffic run for 10 more seconds..."
    sleep 10

    info "Stopping background processes..."
    vm_exec src_ssh "$VM_A_NAME" "pkill iperf3; pkill ping; true" || true
    vm_exec dst_ssh "$VM_B_NAME" "pkill iperf3; true" || true
    sleep 2

    echo ""
    echo -e "${CYAN}=== iperf3 Results: $VM_A_NAME -> $VM_MIGRATE_NAME ===${NC}"
    echo -e "${CYAN}    (was intra-cluster, now cross-cluster after migration)${NC}"
    echo ""
    vm_exec src_ssh "$VM_A_NAME" "cat /tmp/iperf.log" || true
    echo ""

    echo -e "${CYAN}=== iperf3 Results: $VM_B_NAME -> $VM_MIGRATE_NAME ===${NC}"
    echo -e "${CYAN}    (was cross-cluster, now intra-cluster after migration)${NC}"
    echo ""
    vm_exec dst_ssh "$VM_B_NAME" "cat /tmp/iperf.log" || true
    echo ""

    # --- Ping packet loss analysis ---
    echo -e "${CYAN}=== Ping Packet Loss Analysis ===${NC}"
    echo ""
    local ping_output
    ping_output=$(vm_exec src_ssh "$VM_A_NAME" "cat /tmp/ping.log" 2>/dev/null || echo "")

    if [[ -n "$ping_output" ]]; then
        echo "$ping_output" | grep -E "packets transmitted|rtt" || true
        echo ""

        echo "$ping_output" | grep -oP 'seq=\K\d+' > /tmp/cclm-seq.txt 2>/dev/null || true

        if [[ -s /tmp/cclm-seq.txt ]]; then
            python3 <<'PYEOF'
nums = [int(x.strip()) for x in open("/tmp/cclm-seq.txt") if x.strip()]
if not nums:
    print("  No ping data found")
else:
    gaps = []
    for i in range(1, len(nums)):
        if nums[i] != nums[i-1] + 1:
            lost = nums[i] - nums[i-1] - 1
            gaps.append((nums[i-1], nums[i], lost))

    total_lost = sum(g[2] for g in gaps)
    expected = nums[-1] - nums[0] + 1
    print(f"  Responses received: {len(nums)} / {expected} expected")
    print(f"  Total packets lost: {total_lost}")
    print(f"  Loss duration:      ~{total_lost * 0.1:.1f}s")
    if gaps:
        print(f"  Gaps detected:")
        for prev, curr, lost in gaps:
            print(f"    seq {prev} -> {curr}: {lost} packets (~{lost * 0.1:.1f}s)")
    print()
    if total_lost == 0:
        print("  RESULT: Zero packet loss!")
    elif total_lost <= 10:
        print("  RESULT: Minimal packet loss (< 1s downtime)")
    elif total_lost <= 50:
        print("  RESULT: Moderate packet loss — check route convergence")
    else:
        print("  RESULT: Significant packet loss — investigate EVPN routes")
PYEOF
        fi
        rm -f /tmp/cclm-seq.txt
    else
        fail "No ping data collected"
    fi

    # --- Post-migration connectivity check ---
    echo ""
    header "Step 8: Post-Migration Connectivity"
    info "$VM_A_NAME ($VM_A_IP, cluster A) -> $VM_MIGRATE_NAME ($VM_MIGRATE_IP, now on cluster B):"
    vm_exec src_ssh "$VM_A_NAME" "ping -I eth1 -c 3 -W 2 $VM_MIGRATE_IP" \
        && success "reachable" || fail "unreachable"
    echo ""

    info "External client -> $VM_MIGRATE_NAME ($VM_MIGRATE_IP, now on cluster B):"
    ssh -i "$SSH_KEY" $SSH_OPTS root@"$EXT_CLIENT_HOST" \
        "podman exec $EXT_CLIENT_CONTAINER ping -c 3 -W 2 $VM_MIGRATE_IP" \
        && success "reachable" || fail "unreachable"

    echo ""
    header "Migration Summary"
    echo "  Migration ID:  $migration_id"
    echo "  Started:       $migration_start"
    echo "  VM:            $VM_MIGRATE_NAME ($VM_MIGRATE_IP / $VM_MIGRATE_MAC)"
    echo "  Source:        Cluster A ($SRC_HOST)"
    echo "  Destination:   Cluster B ($DST_HOST)"
    echo ""
    echo "  Final VM states:"
    echo "    A $VM_A_NAME:      $(src_oc "get vmi $VM_A_NAME -n $NS -o jsonpath='{.status.phase}'" 2>/dev/null || echo 'n/a')"
    echo "    A $VM_MIGRATE_NAME: $(src_oc "get vmi $VM_MIGRATE_NAME -n $NS -o jsonpath='{.status.phase}'" 2>/dev/null || echo 'Gone')"
    echo "    B $VM_B_NAME:      $(dst_oc "get vmi $VM_B_NAME -n $NS -o jsonpath='{.status.phase}'" 2>/dev/null || echo 'n/a')"
    echo "    B $VM_MIGRATE_NAME: $(dst_oc "get vmi $VM_MIGRATE_NAME -n $NS -o jsonpath='{.status.phase}'" 2>/dev/null || echo 'n/a')"
    echo ""
    success "Demo complete!"
}

# ============================================================================
# cleanup
# ============================================================================
do_cleanup() {
    detect_kubeconfig
    header "CLEANUP: Removing all demo resources"

    info "Deleting migration objects..."
    src_oc "delete vmim --all -n $NS" 2>/dev/null || true
    dst_oc "delete vmim --all -n $NS" 2>/dev/null || true

    info "Deleting VMs on source cluster (A)..."
    src_oc "delete vm $VM_A_NAME $VM_MIGRATE_NAME -n $NS" 2>/dev/null || true

    info "Deleting VMs on destination cluster (B)..."
    dst_oc "delete vm $VM_B_NAME $VM_MIGRATE_NAME -n $NS" 2>/dev/null || true

    info "Waiting for resources to terminate..."
    src_oc "wait --for=delete vm/$VM_A_NAME -n $NS --timeout=60s" 2>/dev/null || true
    dst_oc "wait --for=delete vm/$VM_B_NAME -n $NS --timeout=60s" 2>/dev/null || true

    echo ""
    echo -e "${CYAN}Remaining resources:${NC}"
    src_oc "get vm,vmi,vmim -n $NS" 2>/dev/null || echo "  (none on source cluster)"
    dst_oc "get vm,vmi,vmim -n $NS" 2>/dev/null || echo "  (none on destination cluster)"

    info "Cleaning up helper scripts on cluster nodes..."
    src_ssh "rm -f /tmp/cclm-vm-exec.sh" 2>/dev/null || true
    dst_ssh "rm -f /tmp/cclm-vm-exec.sh" 2>/dev/null || true

    rm -f /tmp/cclm-seq.txt 2>/dev/null || true

    success "Cleanup complete!"
}

# ============================================================================
# Main
# ============================================================================
case "${1:-}" in
    setup)             do_setup ;;
    exchange-ca)       detect_kubeconfig; exchange_kubevirt_ca ;;
    demo-connectivity) do_demo_connectivity ;;
    demo-migration)    do_demo_migration ;;
    cleanup)           do_cleanup ;;
    *)
        echo "Cross-Cluster Live Migration Demo Script"
        echo ""
        echo "Usage: $0 <command>"
        echo ""
        echo "Commands:"
        echo "  setup              Create VMs on both clusters, wait for readiness"
        echo "  exchange-ca        Exchange kubevirt-ca certificates between clusters"
        echo "  demo-connectivity  Ping tests across stretched L2 + external client access"
        echo "  demo-migration     iperf3 sessions, live migrate, analyze impact"
        echo "  cleanup            Tear down all demo resources"
        echo ""
        echo "Environment overrides:"
        echo "  SRC_HOST           Source cluster node   (default: $SRC_HOST)"
        echo "  DST_HOST           Dest cluster node     (default: $DST_HOST)"
        echo "  SSH_KEY            SSH private key        (default: \$HOME/.ssh/beaker)"
        echo "  NS                 Namespace              (default: $NS)"
        echo "  VM_IMAGE           Container disk image   (default: $VM_IMAGE)"
        echo "  IPERF_DURATION     iperf3 test duration   (default: $IPERF_DURATION)"
        echo "  SRC_KUBECONFIG     Source cluster config   (default: /root/.kube/config)"
        echo "  DST_KUBECONFIG     Dest cluster config     (default: /root/.kube/config)"
        ;;
esac
