#!/usr/bin/env bash
# verify.sh - Verify Kata Containers is working on the k3s cluster
#
# Runs several checks:
#   1. Verifies RuntimeClasses exist
#   2. Checks kata-deploy DaemonSet status
#   3. Deploys a test pod with runtimeClassName: kata
#   4. Validates the test pod runs with a different (guest) kernel
#
# Usage:
#   ./scripts/verify.sh
#   ./scripts/verify.sh --skip-pod    # Skip test pod deployment

source "$(dirname "$0")/common.sh"

SKIP_POD=false
for arg in "$@"; do
    if [[ "$arg" == "--skip-pod" ]]; then
        SKIP_POD=true
    fi
done

check_runtimeclasses() {
    log_info "Checking RuntimeClasses..."

    local classes
    classes=$(kubectl get runtimeclass -o name 2>/dev/null || true)

    if echo "$classes" | grep -q "kata"; then
        log_ok "Kata RuntimeClasses found:"
        kubectl get runtimeclass 2>/dev/null | grep -E "^(NAME|kata)" || true
    else
        log_error "No kata RuntimeClasses found"
        log_info "Run 'just install' first"
        return 1
    fi
}

check_daemonset() {
    log_info "Checking kata-deploy DaemonSet..."

    if kubectl get daemonset kata-deploy -n "$K8S_NAMESPACE" &>/dev/null; then
        local desired ready
        desired=$(kubectl get daemonset kata-deploy -n "$K8S_NAMESPACE" -o jsonpath='{.status.desiredNumberScheduled}')
        ready=$(kubectl get daemonset kata-deploy -n "$K8S_NAMESPACE" -o jsonpath='{.status.numberReady}')

        if [[ "$desired" -gt 0 && "$desired" == "$ready" ]]; then
            log_ok "kata-deploy DaemonSet: $ready/$desired pods ready"
        else
            log_warn "kata-deploy DaemonSet: $ready/$desired pods ready (not fully rolled out)"
        fi

        echo ""
        log_info "DaemonSet pods:"
        kubectl get pods -n "$K8S_NAMESPACE" -l app=kata-deploy -o wide
    else
        log_error "kata-deploy DaemonSet not found"
        return 1
    fi
}

check_node_labels() {
    log_info "Checking node labels..."

    local labeled_nodes
    labeled_nodes=$(kubectl get nodes -l katacontainers.io/kata-runtime=true -o name 2>/dev/null || true)

    if [[ -n "$labeled_nodes" ]]; then
        log_ok "Nodes labeled for Kata:"
        echo "$labeled_nodes" | while read -r node; do
            echo "  - $node"
        done
    else
        log_warn "No nodes labeled with katacontainers.io/kata-runtime=true"
    fi
}

deploy_test_pod() {
    log_info "Deploying test pod with runtimeClassName: kata..."

    # Clean up existing test pod
    kubectl delete pod kata-test --ignore-not-found=true 2>/dev/null
    sleep 2

    # Get the host kernel version for comparison
    local host_kernel
    host_kernel=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kernelVersion}' 2>/dev/null)
    log_info "Host kernel: $host_kernel"

    # Deploy test pod
    kubectl_apply "$REPO_ROOT/manifests/test-pod.yaml"
    echo ""

    # Wait for pod to complete
    log_info "Waiting for test pod to start..."
    if kubectl wait --for=condition=Ready pod/kata-test --timeout=120s 2>/dev/null; then
        log_ok "Test pod is running"
    else
        # Pod might have already completed (it sleeps only 10s)
        local phase
        phase=$(kubectl get pod kata-test -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        if [[ "$phase" == "Succeeded" ]]; then
            log_ok "Test pod completed successfully"
        else
            log_warn "Test pod status: $phase"
        fi
    fi

    echo ""
    log_info "Test pod logs:"
    echo "--------------------------------------------"
    kubectl logs kata-test 2>/dev/null || log_warn "Could not retrieve logs yet"
    echo "--------------------------------------------"

    # Compare kernel versions
    local pod_kernel
    pod_kernel=$(kubectl logs kata-test 2>/dev/null | grep "^Kernel:" | awk '{print $2}' || true)

    echo ""
    if [[ -n "$pod_kernel" && "$pod_kernel" != "$host_kernel" ]]; then
        log_ok "SUCCESS: Pod kernel ($pod_kernel) differs from host ($host_kernel)"
        log_ok "Kata Containers is working! The pod is running inside a VM."
    elif [[ -n "$pod_kernel" && "$pod_kernel" == "$host_kernel" ]]; then
        log_error "FAIL: Pod kernel matches host kernel — Kata may not be active"
        log_info "The pod may be using the default runtime instead of kata"
    else
        log_warn "Could not determine pod kernel version from logs"
        log_info "Check manually: kubectl logs kata-test"
    fi
}

cleanup_test_pod() {
    log_info "Cleaning up test pod..."
    kubectl delete pod kata-test --ignore-not-found=true 2>/dev/null
    log_ok "Test pod removed"
}

main() {
    echo "============================================"
    echo "  Kata Containers - Verification"
    echo "============================================"
    echo ""

    require_kubeconfig

    local failed=0

    check_runtimeclasses || (( failed++ ))
    echo ""

    check_daemonset || (( failed++ ))
    echo ""

    check_node_labels || true
    echo ""

    if [[ "$SKIP_POD" == "false" ]]; then
        deploy_test_pod || (( failed++ ))
        echo ""

        log_info "Leave the test pod for inspection, or clean up with: just clean-test"
    fi

    echo ""
    echo "============================================"
    if [[ $failed -gt 0 ]]; then
        log_error "Some checks failed. Review the output above."
        exit 1
    else
        log_ok "All verification checks passed"
    fi
}

main "$@"
