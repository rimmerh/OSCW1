#!/bin/bash
#
# test_per_user_fairness.sh - Test per‑user fairness, including task weight monitoring.
#
# This script requires:
#   - debugfs mounted at /sys/kernel/debug
#   - 'stress' command available
#   - sudo privileges
#
# It records both user‑level runtime/weight and per‑task scheduler weight.

set -euo pipefail

# Configuration
DEBUGFS_BASE="/sys/kernel/debug/user_runtime"
ALL_USERS_FILE="${DEBUGFS_BASE}/all_users"
WEIGHTS_FILE="${DEBUGFS_BASE}/user_weights"          # optional
USER1="test_user1"
USER2="test_user2"
WORKLOAD_DURATION=30          # seconds
STRESS_CMD="stress"
LOG_FILE="per_user_test_$(date +%Y%m%d_%H%M%S).log"

# Color output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Helper functions
log() { echo -e "$*" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}ERROR: $*${NC}" | tee -a "$LOG_FILE"; exit 1; }
warn() { echo -e "${YELLOW}WARNING: $*${NC}" | tee -a "$LOG_FILE"; }

check_command() {
    if ! command -v "$1" &> /dev/null; then
        error "Required command '$1' not found. Please install it."
    fi
}

get_uid() { id -u "$1" 2>/dev/null || error "User $1 does not exist."; }

# Get runtime for a UID from all_users
get_runtime() {
    local uid=$1
    local line
    line=$(grep -E "^\s*${uid}\s+" "$ALL_USERS_FILE" 2>/dev/null || true)
    if [[ -n "$line" ]]; then
        echo "$line" | awk '{print $2}'
    else
        echo 0
    fi
}

# Get weight factor for a UID (from user_weights or compute manually)
get_weight_factor() {
    local uid=$1
    local runtime weight

    if [[ -f "$WEIGHTS_FILE" ]]; then
        local line
        line=$(grep -E "^\s*${uid}\s+" "$WEIGHTS_FILE" 2>/dev/null || true)
        if [[ -n "$line" ]]; then
            echo "$line" | awk '{print $3}'
            return
        fi
    fi
    # Fallback: manual calculation
    runtime=$(get_runtime "$uid")
    local denom=$(( 1 + (runtime / 1000000000) ))
    echo $(( (1 << 16) / denom ))
}

# Get per-task scheduler weight from /proc/<pid>/sched
# Returns the value of se.load.weight (or 0 if not found)
get_task_weight() {
    local pid=$1
    if [[ ! -f /proc/$pid/sched ]]; then
        echo 0
        return
    fi
    # Look for line like "se.load.weight                      :                1024"
    grep "se.load.weight" /proc/$pid/sched 2>/dev/null | awk '{print $3}' || echo 0
}

# Collect PIDs of all stress processes for a given user
get_stress_pids() {
    local user=$1
    pgrep -u "$user" -f "$STRESS_CMD" 2>/dev/null || true
}

# Display task weights for a user (with a short label)
show_task_weights() {
    local user=$1
    local label=$2
    local pids
    pids=$(get_stress_pids "$user")
    if [[ -z "$pids" ]]; then
        log "    $user $label: no stress processes"
        return
    fi
    local weights=()
    for pid in $pids; do
        weights+=($(get_task_weight "$pid"))
    done
    log "    $user $label task weights: ${weights[*]}"
}

cleanup() {
    log "Cleaning up: killing any leftover stress processes..."
    sudo pkill -f "$STRESS_CMD" 2>/dev/null || true
}
trap cleanup EXIT

# --- Initial checks ---
log "=== Per-User Fairness Test with Task-Weight Monitoring ==="
log "Log file: $LOG_FILE"

if [[ ! -d "$DEBUGFS_BASE" ]]; then
    error "Debugfs directory $DEBUGFS_BASE not found."
fi
if [[ ! -f "$ALL_USERS_FILE" ]]; then
    error "all_users file $ALL_USERS_FILE not found."
fi
log "Debugfs ready."

check_command "$STRESS_CMD"
sudo -v || error "Sudo required."

# Create test users if needed
for u in "$USER1" "$USER2"; do
    if ! id "$u" &>/dev/null; then
        log "Creating user $u..."
        sudo useradd -m "$u"
    fi
done

UID1=$(get_uid "$USER1")
UID2=$(get_uid "$USER2")
log "User $USER1 UID=$UID1, $USER2 UID=$UID2"

# --- Helper to run a workload under a given user ---
run_workload() {
    local user=$1
    local duration=$2
    local cpus=${3:-1}
    log "Starting $cpus CPU stressor(s) under $user for ${duration}s"
    sudo -u "$user" "$STRESS_CMD" -c "$cpus" -t "$duration" &
}

# --- Test phase ---
test_phase() {
    local phase_name=$1
    shift
    # Remaining args: user cpu [user cpu ...]

    log "\n${GREEN}--- Test Phase: $phase_name ---${NC}"

    # Capture pre-state
    for user in "$USER1" "$USER2"; do
        uid=$(get_uid "$user")
        runtime=$(get_runtime "$uid")
        factor=$(get_weight_factor "$uid")
        log "  $user (UID $uid) before: runtime=$runtime ns, factor=$factor"
    done

    # Launch workloads
    local pids=()
    while [[ $# -gt 0 ]]; do
        local user=$1
        local cpus=$2
        shift 2
        run_workload "$user" "$WORKLOAD_DURATION" "$cpus"
        pids+=($!)
    done

    # Give processes time to start, then capture their initial weights
    sleep 2
    log "  Task weights shortly after start:"
    show_task_weights "$USER1" "initial"
    show_task_weights "$USER2" "initial"

    # Wait for completion
    log "Waiting ${WORKLOAD_DURATION}s for workloads to complete..."
    wait "${pids[@]}"

    # Capture post-state
    for user in "$USER1" "$USER2"; do
        uid=$(get_uid "$user")
        runtime=$(get_runtime "$uid")
        factor=$(get_weight_factor "$uid")
        log "  $user (UID $uid) after:  runtime=$runtime ns, factor=$factor"
    done
    log "  Task weights after completion:"
    show_task_weights "$USER1" "final"
    show_task_weights "$USER2" "final"

    # Compute runtime deltas and shares
    local run1_before run2_before run1_after run2_after
    run1_before=$(get_runtime "$UID1")
    run2_before=$(get_runtime "$UID2")
    run1_after=$(get_runtime "$UID1")
    run2_after=$(get_runtime "$UID2")
    local delta1=$((run1_after - run1_before))
    local delta2=$((run2_after - run2_before))
    local total=$((delta1 + delta2))
    log "  Delta: $USER1 = $delta1 ns ($((delta1/1000000)) ms), $USER2 = $delta2 ns ($((delta2/1000000)) ms)"
    if [[ $total -gt 0 ]]; then
        share1=$(( (delta1 * 100) / total ))
        share2=$(( (delta2 * 100) / total ))
        log "  CPU time share: $USER1 = $share1%, $USER2 = $share2%"
    fi
}

# --- Main test sequence ---
test_phase "Single user ($USER1, 1 task)" "$USER1" 1
test_phase "Two users, equal tasks (1 each)" "$USER1" 1 "$USER2" 1
test_phase "Two users, unequal tasks ($USER1=2, $USER2=1)" "$USER1" 2 "$USER2" 1

# --- Preload test ---
log "\n${GREEN}--- Test Phase: Preload $USER1, then run $USER2 ---${NC}"
preload_duration=60
log "Preloading $USER1 with 1 CPU stressor for ${preload_duration}s"
sudo -u "$USER1" "$STRESS_CMD" -c 1 -t "$preload_duration" &
preload_pid=$!
sleep 5

# Capture state before second phase
before_runtime1=$(get_runtime "$UID1")
before_runtime2=$(get_runtime "$UID2")
before_factor1=$(get_weight_factor "$UID1")
before_factor2=$(get_weight_factor "$UID2")
log "  Before second phase:"
log "    $USER1: runtime=$before_runtime1 ns, factor=$before_factor1"
log "    $USER2: runtime=$before_runtime2 ns, factor=$before_factor2"
log "  Task weights before second phase:"
show_task_weights "$USER1" "pre"
show_task_weights "$USER2" "pre"

# Run user2 for standard duration
run_workload "$USER2" "$WORKLOAD_DURATION" 1
wait $!

# Capture after state
after_runtime1=$(get_runtime "$UID1")
after_runtime2=$(get_runtime "$UID2")
after_factor1=$(get_weight_factor "$UID1")
after_factor2=$(get_weight_factor "$UID2")
log "  After second phase:"
log "    $USER1: runtime=$after_runtime1 ns, factor=$after_factor1"
log "    $USER2: runtime=$after_runtime2 ns, factor=$after_factor2"
log "  Task weights after second phase:"
show_task_weights "$USER1" "post"
show_task_weights "$USER2" "post"

delta1=$((after_runtime1 - before_runtime1))
delta2=$((after_runtime2 - before_runtime2))
total=$((delta1 + delta2))
log "  Delta during second phase: $USER1 = $delta1 ns ($((delta1/1000000)) ms), $USER2 = $delta2 ns ($((delta2/1000000)) ms)"
if [[ $total -gt 0 ]]; then
    share1=$(( (delta1 * 100) / total ))
    share2=$(( (delta2 * 100) / total ))
    log "  CPU time share during second phase: $USER1 = $share1%, $USER2 = $share2%"
fi

wait "$preload_pid" || true

# --- Cleanup users (optional) ---
log "\n${GREEN}=== Tests completed. ===${NC}"
log "Log saved to $LOG_FILE"
read -p "Delete test users $USER1 and $USER2? (y/N) " -r answer
if [[ $answer =~ ^[Yy]$ ]]; then
    sudo userdel -r "$USER1" 2>/dev/null || warn "Could not delete $USER1"
    sudo userdel -r "$USER2" 2>/dev/null || warn "Could not delete $USER2"
    log "Test users removed."
fi

exit 0
