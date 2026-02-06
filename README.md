# Kata Containers on k3s

Scripts and manifests for installing [Kata Containers](https://katacontainers.io/) on an existing k3s cluster with Ubuntu worker nodes.

Kata Containers runs workloads inside lightweight virtual machines instead of sharing the host kernel, providing hardware-level isolation for each pod. This repo uses the official [kata-deploy](https://github.com/kata-containers/kata-containers/tree/main/tools/packaging/kata-deploy) method -- a DaemonSet that installs Kata binaries and configures containerd on each node automatically.

## Cluster assumptions

- k3s cluster (2 control-plane, 4 worker nodes)
- Worker nodes running Ubuntu with KVM support (bare metal or nested virtualization enabled)
- `kubectl` configured and pointing at the cluster
- SSH access to nodes (only needed for optional pre-flight checks)
- [just](https://github.com/casey/just) command runner installed locally

## Quick start

```bash
# 1. Configure
cp .env.example .env
# Edit .env with your SSH user, node IPs, desired Kata version, etc.

# 2. Check node prerequisites (read-only, uses SSH)
just prereq-check

# 3. Preview what the install will do
just install-dry-run

# 4. Install Kata Containers
just install

# 5. Verify it works
just verify
```

## Repository layout

```
.
├── justfile                         # All recipes (run `just` to list them)
├── .env.example                     # Configuration template
├── .gitignore
├── scripts/
│   ├── common.sh                    # Shared utilities, logging, SSH wrapper
│   ├── prereq-check.sh             # Read-only node checks via SSH
│   ├── install-kata.sh             # Install via kata-deploy DaemonSet
│   ├── uninstall-kata.sh           # Clean removal
│   └── verify.sh                   # Test pod deployment and validation
└── manifests/
    ├── kata-deploy.yaml            # kata-deploy DaemonSet (version templated)
    ├── kata-cleanup.yaml           # Cleanup DaemonSet for uninstall
    ├── kata-runtimeclass.yaml      # RuntimeClasses: kata, kata-qemu, kata-clh
    └── test-pod.yaml               # Test pod that proves Kata is active
```

## Configuration

Copy `.env.example` to `.env` and edit it:

```bash
cp .env.example .env
```

| Variable | Default | Description |
|---|---|---|
| `KATA_VERSION` | `3.12.0` | Kata Containers release. Must match a [kata-deploy image tag](https://quay.io/repository/kata-containers/kata-deploy?tab=tags). |
| `SSH_USER` | `ubuntu` | SSH username for connecting to nodes. |
| `SSH_KEY` | _(empty)_ | Path to SSH private key. Leave empty to use ssh-agent. |
| `WORKER_NODES` | _(empty)_ | Comma-separated node IPs/hostnames. If empty, auto-discovered via `kubectl`. |
| `K8S_NAMESPACE` | `kube-system` | Namespace for the kata-deploy DaemonSet. |
| `DRY_RUN` | `false` | Set to `true` to preview all operations without applying changes. |

## Recipes

Run `just` with no arguments to list all available recipes:

```
just --list
```

### Lifecycle

| Recipe | Description |
|---|---|
| `just prereq-check` | Check KVM, kernel, memory on all worker nodes via SSH. Read-only. |
| `just prereq-check-all` | Same as above but includes control-plane nodes. |
| `just install` | Install Kata on the cluster (labels nodes, applies manifests, waits for rollout). |
| `just install-dry-run` | Preview the install without making any changes. |
| `just verify` | Full verification: checks RuntimeClasses, DaemonSet, and deploys a test pod. |
| `just verify-quick` | Verification without deploying a test pod. |
| `just uninstall` | Completely remove Kata (runs cleanup DaemonSet, removes all resources). |
| `just uninstall-dry-run` | Preview the uninstall. |

### Status and debugging

| Recipe | Description |
|---|---|
| `just status` | Show all kata-related resources at a glance. |
| `just logs` | Tail logs from kata-deploy pods. |
| `just logs-follow` | Stream kata-deploy logs in real time. |
| `just logs-node <node>` | Logs for a specific node's kata-deploy pod. |
| `just describe` | Full `kubectl describe` of the kata-deploy DaemonSet. |

### Test pod

| Recipe | Description |
|---|---|
| `just test-pod` | Deploy a test pod using the `kata` RuntimeClass. |
| `just test-logs` | View test pod logs. |
| `just clean-test` | Delete the test pod. |
| `just kata-shell` | Open an interactive bash shell inside a kata-backed pod. |

### Node inspection (SSH)

| Recipe | Description |
|---|---|
| `just check-kvm <node-ip>` | Check if a specific node has `/dev/kvm` and KVM modules. |
| `just check-containerd <node-ip>` | View the containerd config on a node (useful for debugging). |
| `just check-kata-node <node-ip>` | Check if Kata binaries are installed on a node. |

## How it works

### Install flow

1. **Label worker nodes** with `katacontainers.io/kata-runtime=true`
2. **Apply RuntimeClasses** -- creates `kata`, `kata-qemu`, and `kata-clh` RuntimeClasses that map to the corresponding containerd handlers
3. **Deploy kata-deploy DaemonSet** -- runs on every worker node, where it:
   - Downloads Kata binaries into `/opt/kata/`
   - Patches the k3s containerd config (`config.toml.tmpl`) to register Kata runtime handlers
   - Stays running to maintain the configuration
4. **Wait for rollout** -- the script polls until all DaemonSet pods report ready

### Verification

The verify script deploys a busybox pod with `runtimeClassName: kata`. If Kata is working, the pod's kernel version will differ from the host kernel -- Kata runs a dedicated guest kernel inside each VM.

```
Host kernel:  5.15.0-91-generic
Pod kernel:   6.1.62                  <-- Kata guest kernel
```

### Uninstall flow

1. Delete any test pods
2. Delete the kata-deploy DaemonSet (triggers its `preStop` cleanup hook)
3. Deploy a kata-cleanup DaemonSet to ensure binaries and containerd config are fully removed
4. Remove the cleanup DaemonSet, RBAC resources, RuntimeClasses, and node labels

## Safety features

**Dry-run mode** -- Every script supports `DRY_RUN=true`. The justfile has dedicated `*-dry-run` recipes. In this mode:
- `kubectl apply` runs with `--dry-run=client`
- SSH commands are logged but not executed
- Confirmation prompts are skipped

**SSH safeguards** -- The `safe_ssh` wrapper in `scripts/common.sh`:
- Logs every SSH command before execution
- Detects commands that could modify the system (matching patterns like `install`, `rm`, `systemctl`, `apt`, etc.) and prompts for confirmation
- Supports a `--allow-write` flag for cases where the calling script has already confirmed
- Respects `DRY_RUN` mode

**Confirmation prompts** -- Both `install` and `uninstall` require an explicit `y/N` confirmation before proceeding.

**Read-only prerequisite checks** -- `just prereq-check` only reads from nodes. It checks:
- OS version
- Kernel version (>= 5.4 recommended)
- Hardware virtualization flags (vmx/svm in `/proc/cpuinfo`)
- `/dev/kvm` device availability
- KVM kernel modules loaded
- k3s containerd process running
- Available memory (warns below 2GB)

## Running scripts directly

All scripts can be run without `just`:

```bash
# Prereq check on specific nodes
./scripts/prereq-check.sh 10.0.1.10 10.0.1.11

# Install with custom version
KATA_VERSION=3.11.0 ./scripts/install-kata.sh

# Dry-run uninstall
DRY_RUN=true ./scripts/uninstall-kata.sh
```

## Using Kata in your workloads

Once installed, add `runtimeClassName: kata` to any pod spec:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-secure-pod
spec:
  runtimeClassName: kata
  containers:
    - name: app
      image: my-app:latest
```

Three RuntimeClasses are available:

| RuntimeClass | Hypervisor | Notes |
|---|---|---|
| `kata` | QEMU (default) | Most compatible, broadest feature support. |
| `kata-qemu` | QEMU | Explicit alias for the QEMU hypervisor. |
| `kata-clh` | Cloud Hypervisor | Lighter weight, faster boot, fewer features. |

## Troubleshooting

**kata-deploy pods stuck in CrashLoopBackOff**
```bash
just logs                            # Check pod logs
just check-kvm <node-ip>            # Verify KVM is available
just check-containerd <node-ip>     # Check containerd config state
```

**Test pod fails to schedule**
```bash
kubectl describe pod kata-test       # Look for RuntimeClass errors
just verify-quick                    # Check if RuntimeClasses exist
```

**Test pod runs but kernel matches the host**

Kata may not have configured containerd correctly. Check the containerd config on the node:
```bash
just check-containerd <node-ip>
```

Look for `kata` handler entries in the config. If missing, check the kata-deploy logs for errors. You may need to restart k3s on the affected node:
```bash
# SSH to the node, then:
sudo systemctl restart k3s-agent
```

**Containerd config path issues with k3s**

The manifests use k3s-specific paths:
- Socket: `/run/k3s/containerd/containerd.sock`
- Config: `/var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl`

If your k3s installation uses non-standard paths, update the environment variables in `manifests/kata-deploy.yaml`.
