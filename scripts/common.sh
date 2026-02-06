#!/usr/bin/env bash
# common.sh - Shared utilities for kata k8s setup scripts
# Source this file from other scripts: source "$(dirname "$0")/common.sh"

set -euo pipefail

# ---------------------------------------------------------------------------
# Colors & logging
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ---------------------------------------------------------------------------
# Configuration - loaded from .env if present
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -f "$REPO_ROOT/.env" ]]; then
    # shellcheck source=/dev/null
    source "$REPO_ROOT/.env"
fi

# Defaults (override in .env)
KATA_VERSION="${KATA_VERSION:-3.12.0}"
SSH_USER="${SSH_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-}"
SSH_OPTIONS="${SSH_OPTIONS:--o StrictHostKeyChecking=accept-new -o ConnectTimeout=10}"
WORKER_NODES="${WORKER_NODES:-}"    # comma-separated IPs/hostnames
K8S_NAMESPACE="${K8S_NAMESPACE:-kube-system}"
DRY_RUN="${DRY_RUN:-false}"

# ---------------------------------------------------------------------------
# SSH wrapper with safeguards
# ---------------------------------------------------------------------------
# Usage: safe_ssh <host> <command> [--allow-write]
#
# By default, commands are logged and a confirmation is shown for any
# non-read-only command. Use --allow-write to skip the confirmation
# (e.g. when the caller has already confirmed).
safe_ssh() {
    local host="$1"
    shift

    local allow_write=false
    local cmd_args=()
    for arg in "$@"; do
        if [[ "$arg" == "--allow-write" ]]; then
            allow_write=true
        else
            cmd_args+=("$arg")
        fi
    done
    local cmd="${cmd_args[*]}"

    # Build SSH command
    local ssh_cmd=(ssh $SSH_OPTIONS)
    if [[ -n "$SSH_KEY" ]]; then
        ssh_cmd+=(-i "$SSH_KEY")
    fi
    ssh_cmd+=("${SSH_USER}@${host}")

    log_info "SSH → ${SSH_USER}@${host}: ${cmd}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "[DRY-RUN] Would execute: ${ssh_cmd[*]} ${cmd}"
        return 0
    fi

    # If the command looks like it could modify the system, require confirmation
    if [[ "$allow_write" != "true" ]]; then
        local dangerous_patterns="(install|remove|rm |mv |cp |dd |mkfs|mount|umount|systemctl|apt|yum|dnf|snap|chmod|chown|tee |>>|> )"
        if echo "$cmd" | grep -qEi "$dangerous_patterns"; then
            log_warn "This command may modify the remote system:"
            echo "  Host:    ${host}"
            echo "  Command: ${cmd}"
            read -rp "Proceed? [y/N] " confirm
            if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                log_warn "Skipped."
                return 1
            fi
        fi
    fi

    "${ssh_cmd[@]}" "$cmd"
}

# ---------------------------------------------------------------------------
# Kubectl helpers
# ---------------------------------------------------------------------------
require_kubectl() {
    if ! command -v kubectl &>/dev/null; then
        log_error "kubectl not found in PATH"
        exit 1
    fi
}

require_kubeconfig() {
    require_kubectl
    if ! kubectl cluster-info &>/dev/null 2>&1; then
        log_error "Cannot reach the cluster. Check KUBECONFIG or cluster status."
        exit 1
    fi
    log_ok "Cluster is reachable"
}

kubectl_apply() {
    local file="$1"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "[DRY-RUN] Would apply: $file"
        kubectl apply --dry-run=client -f "$file"
    else
        kubectl apply -f "$file"
    fi
}

kubectl_delete() {
    local file="$1"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "[DRY-RUN] Would delete: $file"
        kubectl delete --dry-run=client -f "$file" 2>/dev/null || true
    else
        kubectl delete -f "$file" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Node helpers
# ---------------------------------------------------------------------------
get_worker_nodes() {
    if [[ -n "$WORKER_NODES" ]]; then
        echo "$WORKER_NODES" | tr ',' '\n'
    else
        # Auto-discover from cluster
        require_kubectl
        kubectl get nodes -l '!node-role.kubernetes.io/control-plane' \
            -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}'
    fi
}

get_all_nodes() {
    if [[ -n "$WORKER_NODES" ]]; then
        echo "$WORKER_NODES" | tr ',' '\n'
    else
        require_kubectl
        kubectl get nodes \
            -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}'
    fi
}

# ---------------------------------------------------------------------------
# Wait helpers
# ---------------------------------------------------------------------------
wait_for_daemonset() {
    local name="$1"
    local namespace="${2:-$K8S_NAMESPACE}"
    local timeout="${3:-300}"

    log_info "Waiting for DaemonSet $name to be ready (timeout: ${timeout}s)..."
    local elapsed=0
    while (( elapsed < timeout )); do
        local desired ready
        desired=$(kubectl get daemonset "$name" -n "$namespace" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
        ready=$(kubectl get daemonset "$name" -n "$namespace" -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")

        if [[ "$desired" -gt 0 && "$desired" == "$ready" ]]; then
            log_ok "DaemonSet $name is ready ($ready/$desired)"
            return 0
        fi
        log_info "  $name: $ready/$desired ready (${elapsed}s elapsed)"
        sleep 10
        (( elapsed += 10 ))
    done

    log_error "Timed out waiting for DaemonSet $name"
    return 1
}

wait_for_pod() {
    local name="$1"
    local namespace="${2:-default}"
    local timeout="${3:-120}"

    log_info "Waiting for pod $name to be ready (timeout: ${timeout}s)..."
    kubectl wait --for=condition=Ready "pod/$name" -n "$namespace" --timeout="${timeout}s"
}

# ---------------------------------------------------------------------------
# Confirmation prompt
# ---------------------------------------------------------------------------
confirm_action() {
    local msg="${1:-Are you sure?}"
    echo ""
    log_warn "$msg"
    read -rp "Continue? [y/N] " answer
    if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
        log_info "Aborted."
        exit 0
    fi
}
