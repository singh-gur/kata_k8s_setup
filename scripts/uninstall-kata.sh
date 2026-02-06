#!/usr/bin/env bash
# uninstall-kata.sh - Cleanly remove Kata Containers from a k3s cluster
#
# This follows the official removal process:
#   1. Delete any pods using kata runtimeClassName
#   2. Deploy the kata-cleanup DaemonSet to remove binaries + containerd config
#   3. Wait for cleanup to complete
#   4. Remove kata-cleanup, kata-deploy DaemonSets
#   5. Remove RuntimeClasses
#   6. Remove node labels
#
# Usage:
#   ./scripts/uninstall-kata.sh
#   DRY_RUN=true ./scripts/uninstall-kata.sh

source "$(dirname "$0")/common.sh"

main() {
    echo "============================================"
    echo "  Kata Containers - Uninstall from k3s"
    echo "============================================"
    echo ""

    require_kubeconfig

    log_info "This will:"
    echo "  1. Delete the test pod (if exists)"
    echo "  2. Run kata-cleanup DaemonSet on all worker nodes"
    echo "  3. Remove kata-deploy and kata-cleanup DaemonSets"
    echo "  4. Remove RuntimeClasses (kata, kata-qemu, kata-clh)"
    echo "  5. Remove node labels"
    echo ""

    if [[ "$DRY_RUN" != "true" ]]; then
        confirm_action "This will completely remove Kata Containers from your cluster."
    fi

    # Step 1: Remove test pod if it exists
    log_info "Step 1: Removing test pod (if present)..."
    kubectl delete pod kata-test --ignore-not-found=true 2>/dev/null || true
    log_ok "Test pod cleaned up"
    echo ""

    # Step 2: Delete the kata-deploy DaemonSet (this triggers preStop cleanup)
    log_info "Step 2: Deleting kata-deploy DaemonSet..."
    if [[ "$DRY_RUN" != "true" ]]; then
        kubectl delete daemonset kata-deploy -n "$K8S_NAMESPACE" --ignore-not-found=true
    else
        log_warn "[DRY-RUN] Would delete kata-deploy DaemonSet"
    fi
    log_ok "kata-deploy removed"
    echo ""

    # Step 3: Deploy cleanup DaemonSet to ensure full cleanup
    log_info "Step 3: Running kata-cleanup DaemonSet..."
    local tmp_manifest
    tmp_manifest=$(mktemp /tmp/kata-cleanup-XXXXXX.yaml)
    export KATA_VERSION
    envsubst '${KATA_VERSION}' < "$REPO_ROOT/manifests/kata-cleanup.yaml" > "$tmp_manifest"

    kubectl_apply "$tmp_manifest"
    rm -f "$tmp_manifest"

    if [[ "$DRY_RUN" != "true" ]]; then
        log_info "Waiting for cleanup DaemonSet to run on all nodes (60s)..."
        sleep 15
        wait_for_daemonset "kata-cleanup" "$K8S_NAMESPACE" 120 || true
        # Give it a moment to run the cleanup script
        sleep 15
    fi
    log_ok "Cleanup DaemonSet ran"
    echo ""

    # Step 4: Remove cleanup DaemonSet
    log_info "Step 4: Removing cleanup DaemonSet..."
    if [[ "$DRY_RUN" != "true" ]]; then
        kubectl delete daemonset kata-cleanup -n "$K8S_NAMESPACE" --ignore-not-found=true
    else
        log_warn "[DRY-RUN] Would delete kata-cleanup DaemonSet"
    fi
    log_ok "Cleanup DaemonSet removed"
    echo ""

    # Step 5: Remove RuntimeClasses
    log_info "Step 5: Removing RuntimeClasses..."
    kubectl_delete "$REPO_ROOT/manifests/kata-runtimeclass.yaml"
    log_ok "RuntimeClasses removed"
    echo ""

    # Step 6: Remove RBAC
    log_info "Step 6: Removing RBAC resources..."
    if [[ "$DRY_RUN" != "true" ]]; then
        kubectl delete clusterrolebinding kata-deploy-rb --ignore-not-found=true 2>/dev/null || true
        kubectl delete clusterrole kata-deploy-role --ignore-not-found=true 2>/dev/null || true
        kubectl delete serviceaccount kata-deploy-sa -n "$K8S_NAMESPACE" --ignore-not-found=true 2>/dev/null || true
    else
        log_warn "[DRY-RUN] Would delete RBAC resources"
    fi
    log_ok "RBAC resources removed"
    echo ""

    # Step 7: Remove node labels
    log_info "Step 7: Removing node labels..."
    local all_nodes
    all_nodes=$(kubectl get nodes -o name 2>/dev/null || true)
    for node in $all_nodes; do
        if [[ "$DRY_RUN" != "true" ]]; then
            kubectl label "$node" katacontainers.io/kata-runtime- 2>/dev/null || true
        fi
    done
    log_ok "Node labels removed"
    echo ""

    echo "============================================"
    log_ok "Kata Containers has been removed from the cluster"
    echo ""
    log_info "Note: You may want to restart k3s on worker nodes to ensure"
    log_info "containerd picks up the config changes cleanly."
}

main "$@"
