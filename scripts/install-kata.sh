#!/usr/bin/env bash
# install-kata.sh - Install Kata Containers on a k3s cluster via kata-deploy
#
# This uses kubectl to apply the kata-deploy DaemonSet which handles:
#   1. Downloading and installing Kata binaries on each worker node
#   2. Configuring containerd with the kata runtime shims
#   3. Creating RuntimeClasses for kata, kata-qemu, kata-clh
#
# Usage:
#   ./scripts/install-kata.sh              # Install with defaults
#   DRY_RUN=true ./scripts/install-kata.sh # Dry-run mode

source "$(dirname "$0")/common.sh"

main() {
    echo "============================================"
    echo "  Kata Containers - Install on k3s"
    echo "  Version: ${KATA_VERSION}"
    echo "============================================"
    echo ""

    require_kubeconfig

    # Show what we're about to do
    log_info "This will:"
    echo "  1. Label worker nodes for kata deployment"
    echo "  2. Apply RuntimeClass manifests (kata, kata-qemu, kata-clh)"
    echo "  3. Deploy the kata-deploy DaemonSet to all worker nodes"
    echo "  4. Wait for kata-deploy to complete installation"
    echo ""
    log_info "Kata version: ${KATA_VERSION}"
    log_info "Namespace:    ${K8S_NAMESPACE}"
    echo ""

    if [[ "$DRY_RUN" != "true" ]]; then
        confirm_action "This will install Kata Containers on your k3s cluster."
    fi

    # Step 1: Label nodes
    log_info "Step 1: Labeling worker nodes..."
    local worker_nodes
    worker_nodes=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o name 2>/dev/null || true)

    if [[ -z "$worker_nodes" ]]; then
        # Try the older label format
        worker_nodes=$(kubectl get nodes -l '!node-role.kubernetes.io/master' -o name 2>/dev/null || true)
    fi

    if [[ -z "$worker_nodes" ]]; then
        log_warn "No worker nodes found (all nodes may be control-plane). Proceeding anyway."
    else
        for node in $worker_nodes; do
            log_info "  Labeling $node with katacontainers.io/kata-runtime=true"
            if [[ "$DRY_RUN" != "true" ]]; then
                kubectl label "$node" katacontainers.io/kata-runtime=true --overwrite
            fi
        done
        log_ok "Worker nodes labeled"
    fi
    echo ""

    # Step 2: Apply RuntimeClasses
    log_info "Step 2: Applying RuntimeClass manifests..."
    kubectl_apply "$REPO_ROOT/manifests/kata-runtimeclass.yaml"
    log_ok "RuntimeClasses applied"
    echo ""

    # Step 3: Apply kata-deploy DaemonSet
    log_info "Step 3: Deploying kata-deploy DaemonSet..."

    # Substitute KATA_VERSION in the manifest
    local tmp_manifest
    tmp_manifest=$(mktemp /tmp/kata-deploy-XXXXXX.yaml)
    export KATA_VERSION
    envsubst '${KATA_VERSION}' < "$REPO_ROOT/manifests/kata-deploy.yaml" > "$tmp_manifest"

    kubectl_apply "$tmp_manifest"
    rm -f "$tmp_manifest"
    log_ok "kata-deploy DaemonSet applied"
    echo ""

    # Step 4: Wait for DaemonSet to be ready
    if [[ "$DRY_RUN" != "true" ]]; then
        log_info "Step 4: Waiting for kata-deploy to complete..."
        log_info "(This may take several minutes as it downloads and installs Kata on each node)"
        echo ""

        if wait_for_daemonset "kata-deploy" "$K8S_NAMESPACE" 600; then
            echo ""
            log_ok "Kata Containers installation complete!"
            echo ""
            log_info "RuntimeClasses available:"
            kubectl get runtimeclass 2>/dev/null | grep -E "^(NAME|kata)" || true
            echo ""
            log_info "Next steps:"
            echo "  - Run 'just verify' to deploy a test pod"
            echo "  - Use 'runtimeClassName: kata' in your pod specs"
        else
            echo ""
            log_error "kata-deploy did not become ready in time."
            log_info "Check pod logs: kubectl logs -n kube-system -l app=kata-deploy"
            exit 1
        fi
    else
        log_info "Step 4: [DRY-RUN] Would wait for kata-deploy DaemonSet to be ready"
    fi
}

main "$@"
