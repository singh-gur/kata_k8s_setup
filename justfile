# Kata Containers on k3s - Setup & Management
#
# Usage: just <recipe>
# Run `just --list` to see all available recipes.

set dotenv-load := true
set shell := ["bash", "-euo", "pipefail", "-c"]

# Default recipe - show help
default:
    @just --list

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

# Check prerequisites on all worker nodes (read-only, safe)
prereq-check *ARGS:
    @bash scripts/prereq-check.sh {{ARGS}}

# Check prerequisites on all nodes including control plane
prereq-check-all:
    @bash scripts/prereq-check.sh --all

# ---------------------------------------------------------------------------
# Installation
# ---------------------------------------------------------------------------

# Install Kata Containers on the k3s cluster
install:
    @bash scripts/install-kata.sh

# Install one node at a time with health checks between each (safer for production)
install-staged:
    @bash scripts/install-kata.sh --staged

# Install with dry-run (shows what would happen without making changes)
install-dry-run:
    @DRY_RUN=true bash scripts/install-kata.sh

# Staged install dry-run
install-staged-dry-run:
    @DRY_RUN=true bash scripts/install-kata.sh --staged

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

# Verify Kata Containers installation (deploys a test pod)
verify:
    @bash scripts/verify.sh

# Verify without deploying a test pod
verify-quick:
    @bash scripts/verify.sh --skip-pod

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

# Completely remove Kata Containers from the cluster
uninstall:
    @bash scripts/uninstall-kata.sh

# Uninstall dry-run
uninstall-dry-run:
    @DRY_RUN=true bash scripts/uninstall-kata.sh

# ---------------------------------------------------------------------------
# Cluster status & debugging
# ---------------------------------------------------------------------------

# Show kata-related resources in the cluster
status:
    @echo "=== RuntimeClasses ==="
    @kubectl get runtimeclass 2>/dev/null | grep -E "^(NAME|kata)" || echo "  (none)"
    @echo ""
    @echo "=== kata-deploy DaemonSet ==="
    @kubectl get daemonset kata-deploy -n kube-system 2>/dev/null || echo "  (not deployed)"
    @echo ""
    @echo "=== kata-deploy Pods ==="
    @kubectl get pods -n kube-system -l app=kata-deploy -o wide 2>/dev/null || echo "  (none)"
    @echo ""
    @echo "=== Nodes with kata label ==="
    @kubectl get nodes -l katacontainers.io/kata-runtime=true 2>/dev/null || echo "  (none)"
    @echo ""
    @echo "=== Test pod ==="
    @kubectl get pod kata-test 2>/dev/null || echo "  (not running)"

# Show logs from kata-deploy pods
logs *ARGS:
    kubectl logs -n kube-system -l app=kata-deploy --tail=50 {{ARGS}}

# Follow logs from kata-deploy pods
logs-follow:
    kubectl logs -n kube-system -l app=kata-deploy -f

# Show kata-deploy pod logs for a specific node
logs-node NODE:
    @POD=$(kubectl get pods -n kube-system -l app=kata-deploy --field-selector spec.nodeName={{NODE}} -o name 2>/dev/null | head -1); \
    if [ -n "$POD" ]; then kubectl logs -n kube-system "$POD" --tail=100; \
    else echo "No kata-deploy pod found on node {{NODE}}"; fi

# Describe the kata-deploy DaemonSet
describe:
    kubectl describe daemonset kata-deploy -n kube-system

# ---------------------------------------------------------------------------
# Test pod management
# ---------------------------------------------------------------------------

# Deploy a test pod using Kata runtime
test-pod:
    kubectl apply -f manifests/test-pod.yaml
    kubectl wait --for=condition=Ready pod/kata-test --timeout=120s 2>/dev/null || true
    @echo ""
    @echo "Pod status:"
    @kubectl get pod kata-test -o wide
    @echo ""
    @echo "Logs:"
    @kubectl logs kata-test 2>/dev/null || echo "(waiting for logs...)"

# Show test pod logs
test-logs:
    kubectl logs kata-test

# Delete the test pod
clean-test:
    kubectl delete pod kata-test --ignore-not-found=true

# Open a shell in a new kata pod (for debugging)
kata-shell:
    kubectl run kata-debug --rm -it --restart=Never \
        --image=ubuntu:22.04 \
        --overrides='{"spec":{"runtimeClassName":"kata"}}' \
        -- bash

# ---------------------------------------------------------------------------
# SSH node access (read-only checks)
# ---------------------------------------------------------------------------

# Check if a specific node has KVM support
check-kvm NODE:
    @bash -c 'source scripts/common.sh && safe_ssh {{NODE}} "ls -la /dev/kvm && lsmod | grep kvm"'

# Check containerd config on a node
check-containerd NODE:
    @bash -c 'source scripts/common.sh && safe_ssh {{NODE}} "cat /var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl 2>/dev/null || echo config.toml.tmpl not found; echo ---; cat /var/lib/rancher/k3s/agent/etc/containerd/config.toml 2>/dev/null || echo config.toml not found"'

# Check kata installation on a node
check-kata-node NODE:
    @bash -c 'source scripts/common.sh && safe_ssh {{NODE}} "ls -la /opt/kata/bin/ 2>/dev/null && /opt/kata/bin/kata-runtime --version 2>/dev/null || echo Kata not found on this node"'
