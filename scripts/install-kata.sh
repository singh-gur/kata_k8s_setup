#!/usr/bin/env bash
# install-kata.sh - Install Kata Containers on a k3s cluster via kata-deploy
#
# This uses kubectl to apply the kata-deploy DaemonSet which handles:
#   1. Downloading and installing Kata binaries on each worker node
#   2. Configuring containerd with the kata runtime shims
#   3. Creating the kata RuntimeClass
#
# Usage:
#   ./scripts/install-kata.sh                # Install on all workers at once
#   ./scripts/install-kata.sh --staged       # Roll out one node at a time
#   DRY_RUN=true ./scripts/install-kata.sh   # Dry-run mode

source "$(dirname "$0")/common.sh"

STAGED=false
for arg in "$@"; do
    if [[ "$arg" == "--staged" ]]; then
        STAGED=true
    fi
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

discover_worker_nodes() {
    local nodes
    nodes=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o name 2>/dev/null || true)

    if [[ -z "$nodes" ]]; then
        # Try the older label format
        nodes=$(kubectl get nodes -l '!node-role.kubernetes.io/master' -o name 2>/dev/null || true)
    fi

    echo "$nodes"
}

apply_daemonset() {
    log_info "Deploying kata-deploy DaemonSet..."

    local tmp_manifest
    tmp_manifest=$(mktemp /tmp/kata-deploy-XXXXXX.yaml)
    export KATA_VERSION
    envsubst '${KATA_VERSION}' < "$REPO_ROOT/manifests/kata-deploy.yaml" > "$tmp_manifest"

    kubectl_apply "$tmp_manifest"
    rm -f "$tmp_manifest"
    log_ok "kata-deploy DaemonSet applied"
}

apply_runtimeclasses() {
    log_info "Applying RuntimeClass manifests..."
    kubectl_apply "$REPO_ROOT/manifests/kata-runtimeclass.yaml"
    log_ok "RuntimeClasses applied"
}

label_node() {
    local node="$1"
    log_info "  Labeling $node with katacontainers.io/kata-runtime=true"
    if [[ "$DRY_RUN" != "true" ]]; then
        kubectl label "$node" katacontainers.io/kata-runtime=true --overwrite
    fi
}

# Wait for kata-deploy to be ready specifically on a given node.
# Polls until the kata-deploy pod on that node is Running+Ready.
wait_for_node_pod() {
    local node_name="$1"
    local timeout="${2:-300}"

    log_info "Waiting for kata-deploy pod on $node_name (timeout: ${timeout}s)..."
    local elapsed=0
    while (( elapsed < timeout )); do
        local phase
        phase=$(kubectl get pods -n "$K8S_NAMESPACE" -l app=kata-deploy \
            --field-selector "spec.nodeName=${node_name}" \
            -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")

        local ready
        ready=$(kubectl get pods -n "$K8S_NAMESPACE" -l app=kata-deploy \
            --field-selector "spec.nodeName=${node_name}" \
            -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")

        if [[ "$phase" == "Running" && "$ready" == "True" ]]; then
            log_ok "kata-deploy pod on $node_name is ready"
            return 0
        fi

        # Check for errors
        local waiting_reason
        waiting_reason=$(kubectl get pods -n "$K8S_NAMESPACE" -l app=kata-deploy \
            --field-selector "spec.nodeName=${node_name}" \
            -o jsonpath='{.items[0].status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || echo "")

        if [[ "$waiting_reason" == "CrashLoopBackOff" || "$waiting_reason" == "ErrImagePull" || "$waiting_reason" == "ImagePullBackOff" ]]; then
            log_error "kata-deploy pod on $node_name is in $waiting_reason"
            log_info "Check logs: kubectl logs -n $K8S_NAMESPACE -l app=kata-deploy --field-selector spec.nodeName=${node_name}"
            return 1
        fi

        log_info "  $node_name: phase=$phase ready=$ready (${elapsed}s elapsed)"
        sleep 10
        (( elapsed += 10 ))
    done

    log_error "Timed out waiting for kata-deploy pod on $node_name"
    return 1
}

# Quick health check: verify existing pods on the node are still running
verify_node_health() {
    local node_name="$1"
    log_info "Verifying node $node_name health..."

    local not_running
    not_running=$(kubectl get pods --all-namespaces --field-selector "spec.nodeName=${node_name}" \
        -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null \
        | grep -cvE "^(Running|Succeeded)$" || echo "0")

    if [[ "$not_running" -gt 0 ]]; then
        log_warn "$node_name has $not_running pod(s) not in Running/Succeeded state"
        kubectl get pods --all-namespaces --field-selector "spec.nodeName=${node_name}" \
            --no-headers 2>/dev/null | grep -vE "Running|Succeeded|Completed" || true
    else
        log_ok "$node_name: all existing pods healthy"
    fi
}

# ---------------------------------------------------------------------------
# Install modes
# ---------------------------------------------------------------------------

install_all() {
    local worker_nodes="$1"

    # Step 1: Label all worker nodes
    log_info "Step 1: Labeling all worker nodes..."
    if [[ -z "$worker_nodes" ]]; then
        log_warn "No worker nodes found (all nodes may be control-plane). Proceeding anyway."
    else
        for node in $worker_nodes; do
            label_node "$node"
        done
        log_ok "All worker nodes labeled"
    fi
    echo ""

    # Step 2: Apply RuntimeClasses
    log_info "Step 2: Applying RuntimeClass manifests..."
    apply_runtimeclasses
    echo ""

    # Step 3: Apply kata-deploy DaemonSet
    log_info "Step 3: Deploying kata-deploy DaemonSet..."
    apply_daemonset
    echo ""

    # Step 4: Wait for DaemonSet to be ready
    if [[ "$DRY_RUN" != "true" ]]; then
        log_info "Step 4: Waiting for kata-deploy to complete on all nodes..."
        log_info "(This may take several minutes as it downloads and installs Kata on each node)"
        echo ""

        if wait_for_daemonset "kata-deploy" "$K8S_NAMESPACE" 600; then
            install_complete_message
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

install_staged() {
    local worker_nodes="$1"

    if [[ -z "$worker_nodes" ]]; then
        log_error "No worker nodes found. Cannot proceed with staged rollout."
        exit 1
    fi

    # Convert to array
    local nodes_array=()
    for node in $worker_nodes; do
        nodes_array+=("$node")
    done

    local total=${#nodes_array[@]}
    log_info "Staged rollout: $total worker node(s) to process"
    echo ""

    # Step 1: Apply RuntimeClasses (safe, no impact)
    log_info "Step 1: Applying RuntimeClass manifests..."
    apply_runtimeclasses
    echo ""

    # Step 2: Apply DaemonSet (won't schedule anywhere yet -- no nodes are labeled)
    log_info "Step 2: Deploying kata-deploy DaemonSet (will not schedule until nodes are labeled)..."
    apply_daemonset
    echo ""

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would roll out to each node one at a time:"
        for node in "${nodes_array[@]}"; do
            log_info "  - $node"
        done
        return 0
    fi

    # Step 3: Label nodes one at a time
    local i=0
    for node in "${nodes_array[@]}"; do
        (( i++ ))
        echo ""
        echo "============================================"
        log_info "Node $i/$total: $node"
        echo "============================================"

        # Extract short node name for field-selector (remove "node/" prefix)
        local node_name="${node#node/}"

        # Show current health before making changes
        verify_node_health "$node_name"
        echo ""

        # Label this node -- DaemonSet will immediately schedule a pod on it
        label_node "$node"
        echo ""

        # Wait for the kata-deploy pod on this specific node
        if ! wait_for_node_pod "$node_name" 300; then
            echo ""
            log_error "kata-deploy failed on $node_name"
            log_info "The remaining nodes have NOT been modified."
            log_info ""
            log_info "To debug:"
            log_info "  kubectl logs -n $K8S_NAMESPACE -l app=kata-deploy --field-selector spec.nodeName=$node_name"
            log_info ""
            log_info "To rollback this node:"
            log_info "  kubectl label $node katacontainers.io/kata-runtime-"
            echo ""
            read -rp "Continue to next node anyway? [y/N] " cont
            if [[ "$cont" != "y" && "$cont" != "Y" ]]; then
                log_info "Stopped. ${i} of ${total} nodes processed."
                exit 1
            fi
        fi

        # Post-install health check
        echo ""
        verify_node_health "$node_name"

        # Prompt before continuing to next node (skip for the last one)
        if (( i < total )); then
            echo ""
            log_ok "Node $node_name done ($i/$total)"
            read -rp "Proceed to next node? [Y/n] " next
            if [[ "$next" == "n" || "$next" == "N" ]]; then
                log_info "Paused. $i of $total nodes processed."
                log_info "Run 'just install-staged' again to continue (already-labeled nodes will be skipped)."
                exit 0
            fi
        fi
    done

    echo ""
    install_complete_message
}

install_complete_message() {
    echo ""
    log_ok "Kata Containers installation complete!"
    echo ""
    log_info "RuntimeClasses available:"
    kubectl get runtimeclass 2>/dev/null | grep -E "^(NAME|kata)" || true
    echo ""
    log_info "Next steps:"
    echo "  - Run 'just verify' to deploy a test pod"
    echo "  - Use 'runtimeClassName: kata' in your pod specs"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    echo "============================================"
    echo "  Kata Containers - Install on k3s"
    echo "  Version: ${KATA_VERSION}"
    if [[ "$STAGED" == "true" ]]; then
        echo "  Mode:    staged (one node at a time)"
    else
        echo "  Mode:    all workers at once"
    fi
    echo "============================================"
    echo ""

    require_kubeconfig

    local worker_nodes
    worker_nodes=$(discover_worker_nodes)

    local node_count
    node_count=$(echo "$worker_nodes" | grep -c . || echo "0")

    if [[ "$STAGED" == "true" ]]; then
        log_info "This will roll out Kata Containers one node at a time:"
        echo "  1. Apply RuntimeClasses (safe, no impact on existing pods)"
        echo "  2. Deploy kata-deploy DaemonSet (won't run until nodes are labeled)"
        echo "  3. For each of the $node_count worker node(s):"
        echo "     a. Check node health"
        echo "     b. Label the node (triggers kata-deploy on that node)"
        echo "     c. Wait for kata-deploy to complete on that node"
        echo "     d. Verify node health"
        echo "     e. Prompt before continuing to the next node"
    else
        log_info "This will:"
        echo "  1. Label all $node_count worker node(s) for kata deployment"
        echo "  2. Apply the kata RuntimeClass manifest"
        echo "  3. Deploy the kata-deploy DaemonSet to all worker nodes"
        echo "  4. Wait for kata-deploy to complete installation"
    fi
    echo ""
    log_info "Kata version: ${KATA_VERSION}"
    log_info "Namespace:    ${K8S_NAMESPACE}"
    echo ""

    if [[ "$DRY_RUN" != "true" ]]; then
        if [[ "$STAGED" == "true" ]]; then
            confirm_action "This will install Kata Containers on your k3s cluster (staged rollout)."
        else
            confirm_action "This will install Kata Containers on your k3s cluster."
        fi
    fi

    if [[ "$STAGED" == "true" ]]; then
        install_staged "$worker_nodes"
    else
        install_all "$worker_nodes"
    fi
}

main "$@"
