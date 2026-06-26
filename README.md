# OpenShift Cluster Network MTU Migration Guide

> **WARNING: This procedure is disruptive.** Nodes will be rebooted in a rolling fashion. Plan for downtime.

## Overview

This guide documents the procedure for changing the cluster network MTU on an OpenShift Container Platform (OCP) cluster using the OVN-Kubernetes network plugin. The migration is performed post-installation and requires three rolling reboots to complete.

**Reference:** [Red Hat Documentation — Changing the MTU for the cluster network](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/advanced_networking/changing-cluster-network-mtu#changing-cluster-network-mtu)

---

## Architecture: Luke Cluster

| Field | Value |
|---|---|
| **OCP Version** | 4.22 |
| **Network Plugin** | OVN-Kubernetes |
| **Current Hardware MTU** | 1500 |
| **Current Cluster MTU** | 1400 (1500 − 100 OVN overhead) |
| **Target Hardware MTU** | 9000 |
| **Target Cluster MTU** | 8900 (9000 − 100 OVN overhead) |
| **Physical Interfaces** | `eno1`, `eno2` |
| **Bond** | `bond0` (LACP bond of eno1 + eno2) |
| **VLANs on bond0** | `.40` (external), `.60`, `.80`, `.90` |
| **OVS Bridges** | `br-ex` (external), `br-vmdata`, `br-int` |
| **Nodes** | 2 master, 1 arbiter, 0 worker |

### Network Topology

```
eno1 ─┐
      ├─ bond0 ─┬─ bond0.40 ── ovs-if-phys0 ── br-ex (external, 192.168.40.x)
      │         ├─ bond0.60 ── ovs-port-60 ──── ovs-br-vlan-60
      │         ├─ bond0.80 ── (VLAN 80)
      │         └─ bond0.90 ── (VLAN 90)
eno2 ─┘
```

The MTU must be set on **`bond0`** (the bond interface), not on individual VLAN subinterfaces. The bond carries traffic across both physical links (`eno1` + `eno2`).

---

## Prerequisites

- `oc` CLI installed
- Cluster-admin access to the cluster
- Physical network switches supporting jumbo frames (MTU 9000) on the ports where cluster nodes are connected

### Download Butane

Butane is Red Hat's configuration transpiler for MachineConfig objects. Select the correct version for your OCP release:

| OCP Version | Butane Version | Release |
|---|---|---|
| 4.20 | v0.25.0 | [Release](https://github.com/coreos/butane/releases/tag/v0.25.0) |
| 4.21 | v0.26.0 | [Release](https://github.com/coreos/butane/releases/tag/v0.26.0) |
| 4.22 | v0.28.0 | [Release](https://github.com/coreos/butane/releases/tag/v0.28.0) |

Download the binary for your platform (example for OCP 4.22 / Butane v0.28.0):

```bash
# Linux x86_64
curl -Lo /tmp/butane https://github.com/coreos/butane/releases/download/v0.28.0/butane-x86_64-unknown-linux-gnu

# Linux aarch64
# curl -Lo /tmp/butane https://github.com/coreos/butane/releases/download/v0.28.0/butane-aarch64-unknown-linux-gnu

# Linux ppc64le
# curl -Lo /tmp/butane https://github.com/coreos/butane/releases/download/v0.28.0/butane-ppc64le-unknown-linux-gnu

# Linux s390x
# curl -Lo /tmp/butane https://github.com/coreos/butane/releases/download/v0.28.0/butane-s390x-unknown-linux-gnu

# macOS Intel (x86_64)
# curl -Lo /tmp/butane https://github.com/coreos/butane/releases/download/v0.28.0/butane-x86_64-apple-darwin

# macOS Apple Silicon (aarch64)
# curl -Lo /tmp/butane https://github.com/coreos/butane/releases/download/v0.28.0/butane-aarch64-apple-darwin

# Windows x86_64 (replace .exe extension)
# curl -Lo /tmp/butane.exe https://github.com/coreos/butane/releases/download/v0.28.0/butane-x86_64-pc-windows-gnu.exe

chmod +x /tmp/butane
sudo mv /tmp/butane /usr/local/bin/butane
butane --version
```

> **Note:** The Butane version must match your OCP major.minor version. Earlier versions do not support newer specs.

### Verify Switch Port MTU

Before proceeding, confirm that the physical switches support jumbo frames on the relevant ports.

### Verify Node Interface maxmtu

```bash
oc debug node/<node_name> -- chroot /host ip -d link show bond0
```

Look for `maxmtu` in the output — it should be 65535 (or at least 9000).

### Find Primary Interface

```bash
oc debug node/<node_name> -- chroot /host nmcli -g connection.interface-name c show ovs-if-phys0
```

Returns the VLAN subinterface name (e.g., `bond0.40`). The **bond** interface (`bond0`) is what needs the MTU change.

### Check Current MTU

```bash
oc describe network.config cluster | grep "Cluster Network MTU"
```

Expected: `Cluster Network MTU: 1400`

### Check MachineConfigPools

```bash
oc get machineconfigpools
```

All pools should show `UPDATED=true`, `UPDATING=false`, `DEGRADED=false` before starting.

---

## Step 1: Create NetworkManager Config File

Create a NetworkManager configuration file that sets the MTU on the bond interface.

```bash
cat > bond0-mtu.conf << 'EOF'
[connection-bond0-mtu]
match-device=interface-name:bond0
ethernet.mtu=9000
EOF
```

> **Note:** The file name (`bond0-mtu.conf`) is arbitrary — it's the content that matters. The `match-device` directive targets the `bond0` interface specifically.

---

## Step 2: Create Butane Configs

Butane is Red Hat's configuration transpiler for MachineConfig objects. Create two Butane configs — one for control plane (master) nodes and one for worker nodes.

### Control Plane Butane Config

Save as `control-plane-interface.bu`:

```yaml
variant: openshift
version: 4.22.0
metadata:
  name: 01-control-plane-interface
  labels:
    machineconfiguration.openshift.io/role: master
storage:
  files:
    - path: /etc/NetworkManager/conf.d/99-bond0-mtu.conf
      contents:
        local: bond0-mtu.conf
      mode: 0600
```

### Worker Butane Config

Save as `worker-interface.bu`:

```yaml
variant: openshift
version: 4.22.0
metadata:
  name: 01-worker-interface
  labels:
    machineconfiguration.openshift.io/role: worker
storage:
  files:
    - path: /etc/NetworkManager/conf.d/99-bond0-mtu.conf
      contents:
        local: bond0-mtu.conf
      mode: 0600
```

> **Important:** The Butane `version` must match your OCP version and always ends in `.0` (e.g., `4.22.0`).

---

## Step 3: Generate MachineConfig YAMLs

```bash
for manifest in control-plane-interface worker-interface; do
    butane --files-dir . $manifest.bu > $manifest.yaml
done
```

This produces:
- `control-plane-interface.yaml` — MachineConfig for master nodes
- `worker-interface.yaml` — MachineConfig for worker nodes

> **⚠️ CRITICAL: Do NOT apply these MachineConfigs yet.** The Red Hat documentation explicitly warns: *"Do not apply these machine configs until explicitly instructed later in this procedure. Applying these machine configs now causes a loss of stability for the cluster."*

---

## Step 4: Begin the MTU Migration

This step tells the Cluster Network Operator (CNO) to start the migration. It sets up a temporary migration script (`mtu-migration.sh`) and triggers the first rolling reboot.

```bash
oc login --insecure-skip-tls-verify https://<api_url>:6443 -u <username> -p '<password>'

oc patch Network.operator.openshift.io cluster --type=merge --patch \
  '{"spec": { "migration": { "mtu": { "network": { "from": <overlay_from>, "to": <overlay_to> } , "machine": { "to" : <machine_to> } } } } }'
```

### Parameter Values

| Parameter | Value | Description |
|---|---|---|
| `<overlay_from>` | `1400` | Current cluster network MTU |
| `<overlay_to>` | `8900` | Target cluster network MTU (hardware MTU − 100 OVN overhead) |
| `<machine_to>` | `9000` | Target hardware MTU for physical interfaces |

### Example (Luke Cluster)

```bash
oc patch Network.operator.openshift.io cluster --type=merge --patch \
  '{"spec": { "migration": { "mtu": { "network": { "from": 1400, "to": 8900 } , "machine": { "to" : 9000 } } } } }'
```

### What Happens

1. CNO validates the migration parameters
2. CNO writes a temporary `mtu-migration.sh` script to nodes
3. Machine Config Operator (MCO) performs a rolling reboot of each node
4. During reboot, nodes run the migration script

---

## Step 5: Wait for First Rolling Reboot

Monitor the MachineConfigPools until all nodes have been updated:

```bash
oc get machineconfigpools
```

### Expected Output

| Pool | UPDATED | UPDATING | DEGRADED |
|---|---|---|---|
| arbiter | True | False | False |
| master | True | False | False |
| worker | True | False | False |

> **Note:** By default, MCO updates one machine per pool at a time. For a 3-node cluster this is fast; for larger clusters this can take significant time.

---

## Step 6: Verify Migration Applied

Confirm that the migration script was deployed correctly to all nodes.

### Check Node MachineConfig State

```bash
oc describe node | egrep "hostname|machineconfig"
```

### Expected Output

```
kubernetes.io/hostname=control01.syangsao.net
machineconfiguration.openshift.io/currentConfig: rendered-master-<hash>
machineconfiguration.openshift.io/desiredConfig: rendered-master-<hash>
machineconfiguration.openshift.io/reason:
machineconfiguration.openshift.io/state: Done
```

### Verification Criteria

1. `machineconfiguration.openshift.io/state` field = `Done`
2. `currentConfig` = `desiredConfig` (both point to the same rendered config)

### Verify Migration Script

```bash
oc get machineconfig <config_name> -o yaml | grep ExecStart
```

Where `<config_name>` is the value from `machineconfiguration.openshift.io/currentConfig`.

Expected: `ExecStart=/usr/local/bin/mtu-migration.sh`

---

## Step 7: Apply the MachineConfigs (Hardware MTU)

Now apply the MachineConfig objects that set the bond interface MTU to 9000 via NetworkManager. This triggers the second rolling reboot.

```bash
for manifest in control-plane-interface worker-interface; do
    oc create -f $manifest.yaml
done
```

### What Happens

1. MCO picks up the new MachineConfig objects
2. MCO generates new rendered configs for each pool
3. MCO performs a rolling reboot of each node
4. On reboot, NetworkManager applies the new MTU (9000) to `bond0`

---

## Step 8: Wait for Second Rolling Reboot

```bash
oc get machineconfigpools
```

Wait until all pools show:
- `UPDATED=true`
- `UPDATING=false`
- `DEGRADED=false`

### Verify Bond MTU

After the reboot, verify the bond interface has the new MTU:

```bash
oc debug node/<node_name> -- chroot /host ip -d link show bond0
```

Expected: `bond0 ... mtu 9000`

---

## Step 9: Finalize the MTU Migration

This step tells the CNO to apply the new MTU to the OVN-Kubernetes network plugin and clears the migration state. It triggers the third and final rolling reboot.

```bash
oc patch Network.operator.openshift.io cluster --type=merge --patch \
  '{"spec": { "migration": null, "defaultNetwork":{ "ovnKubernetesConfig": { "mtu": <mtu> }}}}'
```

### Parameter Value

| Parameter | Value |
|---|---|
| `<mtu>` | `8900` (the cluster network MTU set in Step 4's `<overlay_to>`) |

### Example (Luke Cluster)

```bash
oc patch Network.operator.openshift.io cluster --type=merge --patch \
  '{"spec": { "migration": null, "defaultNetwork":{ "ovnKubernetesConfig": { "mtu": 8900 }}}}'
```

### What Happens

1. CNO applies the new MTU to the OVN-Kubernetes default network configuration
2. `migration` is set to `null` (migration complete)
3. MCO performs a rolling reboot of each node
4. OVN-Kubernetes reconfigures with the new MTU

---

## Step 10: Final Verification

### Verify Cluster Network MTU

```bash
oc describe network.config cluster
```

Expected:
```
Status:
  Cluster Network:
    Cidr:               10.128.0.0/14
    Host Prefix:        23
  Cluster Network MTU:  8900
  Network Type:         OVNKubernetes
```

### Verify Physical Interface MTU

```bash
oc get nodes
```

Then for any node:

```bash
oc debug node/<node_name> -- chroot /host ip -d link show bond0
```

Expected:
```
<some_number>: bond0@eno1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 9000 ...
```

### Verify OVN-Kubernetes MTU

```bash
oc adm node-logs <node_name> -u ovs-configuration | grep configure-ovs.sh | grep mtu | grep bond0 | head -1
```

Expected:
```
bond0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 8900
```

> **Note:** The OVS bridge MTU (8900) is the cluster network MTU. The bond interface MTU (9000) is the hardware MTU. The 100-byte difference accounts for OVN-Kubernetes overlay overhead (Geneve header).

---

## Summary

| Phase | What Happens | Command |
|---|---|---|
| **Preparation** | Create config files & MachineConfigs | `butane` |
| **Step 4** | Start migration (1st reboot) | `oc patch` with migration spec |
| **Step 5** | Wait for nodes to update | `oc get machineconfigpools` |
| **Step 6** | Verify migration script | `oc get machineconfig <name>` + `grep ExecStart` |
| **Step 7** | Apply hardware MTU (2nd reboot) | `oc create -f *.yaml` |
| **Step 8** | Wait for nodes to update | `oc get machineconfigpools` |
| **Step 9** | Finalize OVN-Kubernetes (3rd reboot) | `oc patch` with `migration: null` |
| **Step 10** | Verify final state | `oc describe network.config cluster` |

---

## Troubleshooting

### MachineConfigPool Stuck in UPDATING

If a pool remains in `UPDATING` for an extended period:

```bash
# Check which node is stuck
oc get machineconfigpools -o wide

# Check node events
oc describe node <stuck_node>

# Check MCO logs
oc logs -n openshift-machine-config-operator deploy/machine-config-operator
```

### Nodes Not Rebooting

```bash
# Check if MCO is blocked
oc get machineconfigpool <pool_name> -o yaml

# Check for pending MachineConfigs
oc get machineconfig | grep -E "rendered-|99_"
```

### Network Connectivity Loss After Reboot

If pods lose connectivity after a reboot:

```bash
# Verify bond interface MTU
oc debug node/<node_name> -- chroot /host ip link show bond0

# Verify OVS bridge MTU
oc debug node/<node_name> -- chroot /host ovs-vsctl get Interface ovs-if-phys0 mtu

# Check OVN configuration
oc adm node-logs <node_name> -u ovs-configuration | grep mtu
```

### Rollback

You cannot roll back during the migration process. After the migration completes, you can reverse the changes:

1. Set the MTU back to the original values
2. Apply the MachineConfigs again
3. Patch the CNO with the original MTU values

---

## Important Notes

- **Cannot rollback during migration** — once started, you must complete the full procedure
- **One node at a time** — MCO updates one machine per pool at a time by default
- **Three rolling reboots** — expect significant downtime during the process
- **Physical switches must support jumbo frames** — verify before starting
- **The MTU value of 100 bytes** — this is the OVN-Kubernetes Geneve overlay overhead. For other network plugins, this value may differ.
- **Bond interface, not VLAN** — set MTU on `bond0`, not on individual VLAN subinterfaces like `bond0.40`
