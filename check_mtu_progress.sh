#!/bin/bash
# check_mtu_progress.sh — Check MTU migration progress on an OpenShift cluster
# Usage: ./check_mtu_progress.sh
# Requires: oc CLI authenticated to the cluster

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Counters
PASSED=0
WARNED=0
FAILED=0

pass() {
    echo -e "  ${GREEN}✓${NC} $1"
    PASSED=$((PASSED + 1))
}

warn() {
    echo -e "  ${YELLOW}⚠${NC} $1"
    WARNED=$((WARNED + 1))
}

fail() {
    echo -e "  ${RED}✗${NC} $1"
    FAILED=$((FAILED + 1))
}

section() {
    echo -e "\n${BOLD}${CYAN}=== $1 ===${NC}"
}

# ──────────────────────────────────────────────
# Check oc auth
# ──────────────────────────────────────────────
if ! oc whoami &>/dev/null; then
    echo -e "${RED}Error: not authenticated to OpenShift. Run 'oc login' first.${NC}"
    exit 1
fi

section "MTU Migration Progress Check"

# ──────────────────────────────────────────────
# Step 1-3: Check if MachineConfigs exist (but are not applied yet)
# ──────────────────────────────────────────────
section "Step 1-3: MachineConfig Preparation"

for role in master worker; do
    mc_name="01-${role//-/_}-interface"
    if oc get machineconfig "$mc_name" &>/dev/null; then
        pass "MachineConfig '$mc_name' exists"
    else
        warn "MachineConfig '$mc_name' not found (create with Butane)"
    fi
done

# ──────────────────────────────────────────────
# Step 4: Check if migration has been started
# ──────────────────────────────────────────────
section "Step 4: Migration Started"

CNO_SPEC=$(oc get network.operator.openshift.io cluster -o jsonpath='{.spec.migration}' 2>/dev/null || echo "")

if [ -z "$CNO_SPEC" ] || [ "$CNO_SPEC" = "<none>" ] || [ "$CNO_SPEC" = "" ]; then
    fail "Migration not started — CNO migration spec is empty"
    echo -e "  ${NC}Run: oc patch Network.operator.openshift.io cluster --type=merge --patch '{\"spec\":{\"migration\":{\"mtu\":{\"network\":{\"from\":1400,\"to\":8900},\"machine\":{\"to\":9000}}}}}'"
else
    pass "Migration started — CNO migration spec is set"
    # Extract migration values
    OVERLAY_FROM=$(echo "$CNO_SPEC" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('mtu',{}).get('network',{}).get('from','N/A'))" 2>/dev/null || echo "N/A")
    OVERLAY_TO=$(echo "$CNO_SPEC" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('mtu',{}).get('network',{}).get('to','N/A'))" 2>/dev/null || echo "N/A")
    MACHINE_TO=$(echo "$CNO_SPEC" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('mtu',{}).get('machine',{}).get('to','N/A'))" 2>/dev/null || echo "N/A")
    echo -e "  ${NC}  Overlay MTU: ${OVERLAY_FROM} → ${OVERLAY_TO}"
    echo -e "  ${NC}  Machine MTU: ${MACHINE_TO}"
fi

# ──────────────────────────────────────────────
# Step 5: Check if first rolling reboot is complete
# ──────────────────────────────────────────────
section "Step 5: First Rolling Reboot"

MCP_STATUS=$(oc get machineconfigpools -o json 2>/dev/null)

ALL_UPDATED=true
UPDATING_COUNT=0
for pool in $(echo "$MCP_STATUS" | python3 -c "import sys,json; [print(i['metadata']['name']) for i in json.load(sys.stdin)['items']]" 2>/dev/null); do
    UPDATED=$(echo "$MCP_STATUS" | python3 -c "import sys,json; items=json.load(sys.stdin)['items']; p=[i for i in items if i['metadata']['name']=='$pool'][0]; print(p['status'].get('updated',False))" 2>/dev/null || echo "False")
    UPDATING=$(echo "$MCP_STATUS" | python3 -c "import sys,json; items=json.load(sys.stdin)['items']; p=[i for i in items if i['metadata']['name']=='$pool'][0]; print(p['status'].get('updating',False))" 2>/dev/null || echo "False")
    DEGRADED=$(echo "$MCP_STATUS" | python3 -c "import sys,json; items=json.load(sys.stdin)['items']; p=[i for i in items if i['metadata']['name']=='$pool'][0]; print(p['status'].get('degraded',False))" 2>/dev/null || echo "False")
    
    if [ "$UPDATING" = "True" ]; then
        warn "Pool '$pool' is still updating"
        UPDATING_COUNT=$((UPDATING_COUNT + 1))
    elif [ "$UPDATED" = "True" ] && [ "$DEGRADED" = "False" ]; then
        pass "Pool '$pool' is updated"
    else
        fail "Pool '$pool' is not updated (degraded=$DEGRADED)"
        ALL_UPDATED=false
    fi
done

if [ "$UPDATING_COUNT" -gt 0 ]; then
    echo -e "  ${NC}  $UPDATING_COUNT pool(s) still updating. Run: oc get machineconfigpools"
fi

# ──────────────────────────────────────────────
# Step 6: Check if migration script is deployed
# ──────────────────────────────────────────────
section "Step 6: Migration Script Verification"

NODES=$(oc get nodes -o name 2>/dev/null | sed 's|node/||')
MIGRATION_SCRIPT_FOUND=0

for node in $NODES; do
    CURRENT_CONFIG=$(oc get node "$node" -o jsonpath='{.metadata.annotations.machineconfiguration\.openshift\.io/currentConfig}' 2>/dev/null || echo "")
    if [ -z "$CURRENT_CONFIG" ]; then
        warn "Node '$node' has no currentConfig annotation"
        continue
    fi
    
    # Check if the current config contains the migration script
    HAS_MIGRATION=$(oc get machineconfig "$CURRENT_CONFIG" -o json 2>/dev/null | python3 -c "
import sys, json
try:
    mc = json.load(sys.stdin)
    units = mc.get('spec', {}).get('config', {}).get('systemd', {}).get('units', [])
    for u in units:
        if 'mtu-migration' in u.get('name', ''):
            print('yes')
            sys.exit(0)
    print('no')
except:
    print('no')
" 2>/dev/null || echo "no")
    
    if [ "$HAS_MIGRATION" = "yes" ]; then
        MIGRATION_SCRIPT_FOUND=$((MIGRATION_SCRIPT_FOUND + 1))
        pass "Node '$node' has migration script (config: $CURRENT_CONFIG)"
    else
        # Check node state
        NODE_STATE=$(oc get node "$node" -o jsonpath='{.metadata.annotations.machineconfiguration\.openshift\.io/state}' 2>/dev/null || echo "Unknown")
        if [ "$NODE_STATE" = "Done" ]; then
            pass "Node '$node' is in Done state"
        else
            warn "Node '$node' state: $NODE_STATE (config: $CURRENT_CONFIG)"
        fi
    fi
done

if [ "$MIGRATION_SCRIPT_FOUND" -eq 0 ]; then
    warn "No nodes have the migration script deployed yet"
fi

# ──────────────────────────────────────────────
# Step 7-8: Check if hardware MTU MachineConfigs are applied
# ──────────────────────────────────────────────
section "Step 7-8: Hardware MTU Applied"

# Check if the NM config file exists on nodes
for node in $NODES; do
    NM_EXISTS=$(oc debug node/"$node" -- chroot /host test -f /etc/NetworkManager/conf.d/99-bond0-mtu.conf && echo "yes" || echo "no" 2>/dev/null || echo "no")
    
    if [ "$NM_EXISTS" = "yes" ]; then
        # Check actual MTU values
        BOND_MTU=$(oc debug node/"$node" -- chroot /host ip -d link show bond0 2>/dev/null | grep -oP 'mtu \K\d+' || echo "unknown")
        ENO1_MTU=$(oc debug node/"$node" -- chroot /host ip -d link show eno1 2>/dev/null | grep -oP 'mtu \K\d+' || echo "unknown")
        ENO2_MTU=$(oc debug node/"$node" -- chroot /host ip -d link show eno2 2>/dev/null | grep -oP 'mtu \K\d+' || echo "unknown")
        
        pass "Node '$node': NM config exists — bond0=$BOND_MTU eno1=$ENO1_MTU eno2=$ENO2_MTU"
        
        if [ "$BOND_MTU" != "9000" ]; then
            warn "  bond0 MTU is $BOND_MTU (expected 9000)"
        fi
        if [ "$ENO1_MTU" != "9000" ]; then
            warn "  eno1 MTU is $ENO1_MTU (expected 9000)"
        fi
        if [ "$ENO2_MTU" != "9000" ]; then
            warn "  eno2 MTU is $ENO2_MTU (expected 9000)"
        fi
    else
        warn "Node '$node': NM config not found — hardware MTU not applied"
    fi
done

# ──────────────────────────────────────────────
# Step 9-10: Check final MTU values
# ──────────────────────────────────────────────
section "Step 9-10: Final Verification"

# Check cluster network MTU
CLUSTER_MTU=$(oc describe network.config cluster 2>/dev/null | grep "Cluster Network MTU" | awk '{print $NF}' || echo "unknown")
if [ "$CLUSTER_MTU" = "8900" ]; then
    pass "Cluster Network MTU: $CLUSTER_MTU ✓"
elif [ "$CLUSTER_MTU" = "1400" ]; then
    warn "Cluster Network MTU: $CLUSTER_MTU (migration not finalized)"
else
    warn "Cluster Network MTU: $CLUSTER_MTU (unexpected value)"
fi

# Check OVN-Kubernetes MTU
OVN_CONFIG=$(oc get network.operator.openshift.io cluster -o json 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    mtu = d.get('spec', {}).get('defaultNetwork', {}).get('ovnKubernetesConfig', {}).get('mtu', 'not set')
    print(mtu)
except:
    print('not set')
" 2>/dev/null || echo "not set")

if [ "$OVN_CONFIG" = "8900" ]; then
    pass "OVN-Kubernetes MTU: $OVN_CONFIG ✓"
elif [ "$OVN_CONFIG" = "not set" ]; then
    warn "OVN-Kubernetes MTU: not set (migration not finalized)"
else
    warn "OVN-Kubernetes MTU: $OVN_CONFIG (expected 8900)"
fi

# Check if migration is cleared
MIGRATION_CLEARED=$(oc get network.operator.openshift.io cluster -o jsonpath='{.spec.migration}' 2>/dev/null || echo "unknown")
if [ -z "$MIGRATION_CLEARED" ] || [ "$MIGRATION_CLEARED" = "<none>" ]; then
    pass "Migration spec cleared ✓"
else
    warn "Migration spec still active"
fi

# ──────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────
section "Summary"

TOTAL=$((PASSED + WARNED + FAILED))
echo -e "  ${GREEN}Passed: $PASSED${NC}"
echo -e "  ${YELLOW}Warnings: $WARNED${NC}"
echo -e "  ${RED}Failed: $FAILED${NC}"
echo -e "  Total: $TOTAL checks"

# Determine next step
echo -e "\n${BOLD}Next step:${NC}"

# Check which step we're at
if [ "$FAILED" -gt 0 ] || [ "$WARNED" -gt 0 ]; then
    # Find the first failing/warning step
    if [ "$OVN_CONFIG" = "8900" ] && [ "$CLUSTER_MTU" = "8900" ] && [ -z "$MIGRATION_CLEARED" ] || [ "$MIGRATION_CLEARED" = "<none>" ]; then
        echo -e "  ${GREEN}Migration complete. All steps verified.${NC}"
    else
        echo -e "  ${YELLOW}Review warnings above and continue with the next step in the guide.${NC}"
    fi
else
    echo -e "  ${GREEN}All checks passed. Migration complete.${NC}"
fi
