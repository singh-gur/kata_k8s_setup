#!/usr/bin/env bash
# prereq-check.sh - Check prerequisites for Kata Containers on cluster nodes
#
# This script is READ-ONLY. It only inspects nodes via SSH and never modifies
# anything. Safe to run at any time.
#
# Usage:
#   ./scripts/prereq-check.sh              # Check all worker nodes
#   ./scripts/prereq-check.sh --all        # Check all nodes (including control plane)
#   ./scripts/prereq-check.sh <ip> [<ip>]  # Check specific nodes

source "$(dirname "$0")/common.sh"

# ---------------------------------------------------------------------------
# Checks (all read-only)
# ---------------------------------------------------------------------------

check_virtualization() {
    local host="$1"
    log_info "[$host] Checking hardware virtualization support..."

    local virt_flags
    virt_flags=$(safe_ssh "$host" "grep -cE '(vmx|svm)' /proc/cpuinfo 2>/dev/null || echo 0")

    if [[ "$virt_flags" -gt 0 ]]; then
        log_ok "[$host] Hardware virtualization supported (${virt_flags} vCPUs with vmx/svm)"
    else
        log_error "[$host] No hardware virtualization (vmx/svm) detected"
        log_warn "[$host] Kata Containers requires nested virt or bare-metal with VT-x/AMD-V"
        return 1
    fi
}

check_kernel_modules() {
    local host="$1"
    log_info "[$host] Checking kernel modules..."

    local modules=("kvm" "kvm_intel" "kvm_amd" "vhost_net" "vhost_vsock")
    local found=0

    for mod in "${modules[@]}"; do
        if safe_ssh "$host" "lsmod | grep -q '^${mod} '" 2>/dev/null; then
            log_ok "[$host] Module loaded: $mod"
            (( found++ ))
        else
            # kvm_intel and kvm_amd are alternatives; only one needs to be present
            if [[ "$mod" == "kvm_intel" || "$mod" == "kvm_amd" ]]; then
                log_info "[$host] Module not loaded: $mod (may not apply to this CPU)"
            else
                log_warn "[$host] Module not loaded: $mod"
            fi
        fi
    done

    # At minimum we need kvm
    if safe_ssh "$host" "lsmod | grep -q '^kvm '" 2>/dev/null; then
        log_ok "[$host] KVM module is available"
    else
        log_error "[$host] KVM module not loaded — Kata requires KVM"
        return 1
    fi
}

check_dev_kvm() {
    local host="$1"
    log_info "[$host] Checking /dev/kvm..."

    if safe_ssh "$host" "test -c /dev/kvm" 2>/dev/null; then
        log_ok "[$host] /dev/kvm exists and is a character device"
    else
        log_error "[$host] /dev/kvm not found — Kata requires KVM device access"
        return 1
    fi
}

check_containerd() {
    local host="$1"
    log_info "[$host] Checking container runtime..."

    # k3s uses its own bundled containerd
    if safe_ssh "$host" "pgrep -f 'k3s.*containerd' >/dev/null 2>&1" 2>/dev/null; then
        log_ok "[$host] k3s containerd is running"
    elif safe_ssh "$host" "systemctl is-active --quiet containerd" 2>/dev/null; then
        log_ok "[$host] containerd is running (standalone)"
    else
        log_warn "[$host] containerd not detected — expected for k3s nodes"
    fi
}

check_kernel_version() {
    local host="$1"
    log_info "[$host] Checking kernel version..."

    local kver
    kver=$(safe_ssh "$host" "uname -r")
    log_info "[$host] Kernel: $kver"

    # Kata 3.x recommends kernel >= 5.4
    local major minor
    major=$(echo "$kver" | cut -d. -f1)
    minor=$(echo "$kver" | cut -d. -f2)

    if (( major > 5 || (major == 5 && minor >= 4) )); then
        log_ok "[$host] Kernel version $kver is compatible"
    else
        log_warn "[$host] Kernel $kver may be too old (recommended >= 5.4)"
    fi
}

check_node_resources() {
    local host="$1"
    log_info "[$host] Checking node resources..."

    local mem_kb
    mem_kb=$(safe_ssh "$host" "grep MemTotal /proc/meminfo | awk '{print \$2}'")
    local mem_gb=$(( mem_kb / 1024 / 1024 ))
    log_info "[$host] Memory: ${mem_gb}GB"

    local cpus
    cpus=$(safe_ssh "$host" "nproc")
    log_info "[$host] CPUs: ${cpus}"

    if (( mem_gb < 2 )); then
        log_warn "[$host] Less than 2GB RAM — Kata VMs need memory overhead"
    else
        log_ok "[$host] Memory looks sufficient"
    fi
}

check_os() {
    local host="$1"
    log_info "[$host] Checking OS..."

    local os_info
    os_info=$(safe_ssh "$host" "cat /etc/os-release | grep -E '^(NAME|VERSION_ID)=' | tr '\n' ' '")
    log_info "[$host] OS: $os_info"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo "============================================"
    echo "  Kata Containers - Node Prerequisite Check"
    echo "  (read-only — no changes will be made)"
    echo "============================================"
    echo ""

    local nodes=()
    if [[ $# -gt 0 ]]; then
        if [[ "$1" == "--all" ]]; then
            mapfile -t nodes < <(get_all_nodes)
        else
            nodes=("$@")
        fi
    else
        mapfile -t nodes < <(get_worker_nodes)
    fi

    if [[ ${#nodes[@]} -eq 0 ]]; then
        log_error "No nodes found. Set WORKER_NODES in .env or pass IPs as arguments."
        exit 1
    fi

    log_info "Checking ${#nodes[@]} node(s): ${nodes[*]}"
    echo ""

    local failed=0
    for node in "${nodes[@]}"; do
        echo "--------------------------------------------"
        log_info "Checking node: $node"
        echo "--------------------------------------------"

        local node_ok=true

        check_os "$node" || true
        check_kernel_version "$node" || true
        check_node_resources "$node" || true
        check_virtualization "$node" || node_ok=false
        check_dev_kvm "$node" || node_ok=false
        check_kernel_modules "$node" || node_ok=false
        check_containerd "$node" || true

        echo ""
        if [[ "$node_ok" == "true" ]]; then
            log_ok "Node $node: All critical checks passed"
        else
            log_error "Node $node: One or more critical checks failed"
            (( failed++ ))
        fi
        echo ""
    done

    echo "============================================"
    if [[ $failed -gt 0 ]]; then
        log_error "$failed node(s) have issues that need resolving before installing Kata"
        exit 1
    else
        log_ok "All nodes passed prerequisite checks"
    fi
}

main "$@"
