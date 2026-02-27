#!/bin/bash
#
# test_per_user_fairness.sh - Test per-user fairness with CPU pinning to create contention.
#   All stress tasks are forced onto CPU 0.
#
# This script requires:
#   - debugfs mounted at /sys/kernel/debug
#   - 'stress' and 'taskset' commands available
#   - sudo privileges to create/remove test users and run stress
#
# Output: prints test results (runtime + weight factor) to stdout and saves a log file.

set -euo pipefail

# Configuration
DEBUGFS_BASE="/sys/kernel/debug/user_runtime"
ALL_USERS_FILE="${DEBUGFS_BASE}/all_users"
WEIGHTS_FILE="${DEBUGFS_BASE}/user_weights"          # optional
USER1="test_user1"
USER2="test_user2"
WORKLOAD_DURATION=30          # seconds for each workload phase
STRESS_CMD="stress"
LOG_FILE="per_user_test_$(date +%Y%m%d_%H%M%S).log"
CPU_TO_USE=0                   # Pin all tasks to this CPU

# Color output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "$*" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}ERROR: $*${NC}" | tee -a "$LOG_FILE"; exit 1; }
warn() { echo -e "${YELLOW}WARNING: $*${NC}" | tee -a "$LOG_FILE"; }

check_command() {
    if ! command -v "$1" &> /dev/null; then
        error "Required command '$1' not found. Please install it."
    fi
}

get_uid() { id -u "$1" 2>/dev/null || error "User $user does not exist."; }

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

get_weight() {
    local uid=$1
    if [[ -f "$WEIGHTS_FILE" ]]; then
        local line
        line=$(grep -E "^\s*${uid}\s+" "$WEIGHTS_FILE" 2>/dev/null || true)
        if [[ -n "$line" ]]; then
            echo "$line" | awk '{print $3}'
            return
        fi
    fi
    # Manual calculation fallback
    local runtime=$(get_runtime "$uid")
    local denom=$(( 1 + (runtime / 1000000000) ))
    echo $(( (1 << 16) / denom ))
}

# Check if we can read scheduler weights
CAN_READ_TASK_WEIGHT=0
if grep -q "se.load.weight" /proc/self/sched 2>/dev/null; then
    CAN_READ_TASK_WEIGHT=1
else
    warn "Cannot read se.load.weight from /proc (CONFIG_SCHED_DEBUG may be disabled). Task weights will show as 0."
fi

get_task_weight() {
    local pid=$1
    if [[ ! -f /proc/$pid/sched ]] || [[ $CAN_READ_TASK_WEIGHT -eq 0 ]]; then
        echo "N/A"
        return
    fi
    grep "se.load.weight" /proc/$pid/sched 2>/dev/null | awk '{print $3}' || echo "N/A"
}

get_stress_pids() {
    local user=$1
    pgrep -u "$user" -f "$STRESS_CMD" 2>/dev/null || true
}

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
log "=== Per-User Fairness Test (pinned to CPU $CPU_TO_USE) ==="
log "Log file: $LOG_FILE"

if [[ ! -d "$DEBUGFS_BASE" ]]; then
    error "Debugfs directory $DEBUGFS_BASE not found."
fi
if [[ ! -f "$ALL_USERS_FILE" ]]; then
    error "all_users file $ALL_USERS_FILE not found."
fi
log "Debugfs ready."
if [[ -f "$WEIGHTS_FILE" ]]; then
    log "Using weights file: $WEIGHTS_FILE"
else
    warn "Weights file not found; will compute factor manually from runtime."
fi

check_command "$STRESS_CMD"
check_command "taskset"
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

# --- Helper to run a workload under a given user, pinned to CPU $CPU_TO_USE ---
run_workload() {
    local user=$1
    local duration=$2
    local cpus=${3:-1}
    log "Starting $cpus CPU stressor(s) under $user for ${duration}s (pinned to CPU $CPU_TO_USE)"
    # Use taskset to pin all stress processes to the designated CPU
    sudo -u "$user" taskset -c "$CPU_TO_USE" "$STRESS_CMD" -c "$cpus" -t "$duration" &
}

# --- Test phase ---
test_phase() {
    local phase_name=$1
    shift

    log "\n${GREEN}--- Test Phase: $phase_name ---${NC}"

    local runtime1_before=$(get_runtime "$UID1")
    local runtime2_before=$(get_runtime "$UID2")
    local weight1_before=$(get_weight "$UID1")
    local weight2_before=$(get_weight "$UID2")
    log "  $USER1 before: runtime=$runtime1_before ns, factor=$weight1_before"
    log "  $USER2 before: runtime=$runtime2_before ns, factor=$weight2_before"

    local pids=()
    while [[ $# -gt 0 ]]; do
        local user=$1
        local cpus=$2
        shift 2
        run_workload "$user" "$WORKLOAD_DURATION" "$cpus"
        pids+=($!)
    done

    sleep 2
    log "  Task weights shortly after start:"
    show_task_weights "$USER1" "initial"
    show_task_weights "$USER2" "initial"

    log "Waiting ${WORKLOAD_DURATION}s for workloads to complete..."
    wait "${pids[@]}"

    local runtime1_after=$(get_runtime "$UID1")
    local runtime2_after=$(get_runtime "$UID2")
    local weight1_after=$(get_weight "$UID1")
    local weight2_after=$(get_weight "$UID2")
    log "  $USER1 after: runtime=$runtime1_after ns, factor=$weight1_after"
    log "  $USER2 after: runtime=$runtime2_after ns, factor=$weight2_after"
    log "  Task weights after completion:"
    show_task_weights "$USER1" "final"
    show_task_weights "$USER2" "final"

    local delta1=$((runtime1_after - runtime1_before))
    local delta2=$((runtime2_after - runtime2_before))
    local total=$((delta1 + delta2))
    log "  Delta: $USER1 = $delta1 ns ($((delta1/1000000)) ms), $USER2 = $delta2 ns ($((delta2/1000000)) ms)"
    if [[ $total -gt 0 ]]; then
        local share1=$(( (delta1 * 100) / total ))
        local share2=$(( (delta2 * 100) / total ))
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
log "Preloading $USER1 with 1 CPU stressor for ${preload_duration}s (pinned to CPU $CPU_TO_USE)"
sudo -u "$USER1" taskset -c "$CPU_TO_USE" "$STRESS_CMD" -c 1 -t "$preload_duration" &
preload_pid=$!
sleep 5

before_runtime1=$(get_runtime "$UID1")
before_runtime2=$(get_runtime "$UID2")
before_weight1=$(get_weight "$UID1")
before_weight2=$(get_weight "$UID2")
log "  Before second phase:"
log "    $USER1: runtime=$before_runtime1 ns, factor=$before_weight1"
log "    $USER2: runtime=$before_runtime2 ns, factor=$before_weight2"
log "  Task weights before second phase:"
show_task_weights "$USER1" "pre"
show_task_weights "$USER2" "pre"

run_workload "$USER2" "$WORKLOAD_DURATION" 1
wait $!

after_runtime1=$(get_runtime "$UID1")
after_runtime2=$(get_runtime "$UID2")
after_weight1=$(get_weight "$UID1")
after_weight2=$(get_weight "$UID2")
log "  After second phase:"
log "    $USER1: runtime=$after_runtime1 ns, factor=$after_weight1"
log "    $USER2: runtime=$after_runtime2 ns, factor=$after_weight2"
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

# --- Cleanup ---
log "\n${GREEN}=== Tests completed. ===${NC}"
log "Log saved to $LOG_FILE"
read -p "Delete test users $USER1 and $USER2? (y/N) " -r answer
if [[ $answer =~ ^[Yy]$ ]]; then
    sudo userdel -r "$USER1" 2>/dev/null || warn "Could not delete $USER1"
    sudo userdel -r "$USER2" 2>/dev/null || warn "Could not delete $USER2"
    log "Test users removed."
fi

exit 0
