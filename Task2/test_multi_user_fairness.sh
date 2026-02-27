#!/bin/bash
#
# test_per_user_fairness_multi.sh
# Test per-user fairness with up to 4 users, each running a specified number of tasks.
# All tasks are pinned to the same CPU to force contention.
#
# Usage: sudo ./test_per_user_fairness_multi.sh [duration] [cpu]
#   duration: test duration in seconds (default: 60)
#   cpu: CPU to pin tasks to (default: 0)
#
# Configuration: Edit the USER_TASKS array below to set task counts per user.
# Example: USER_TASKS=(1 2 1 0) means user1=1 task, user2=2 tasks, user3=1 task, user4=0 tasks.

set -euo pipefail

# --- Configuration ---
# Task counts for up to 4 users (order: user1, user2, user3, user4)
USER_TASKS=(1 2 1 0)   # modify as needed
USER_NAMES=("test_user1" "test_user2" "test_user3" "test_user4")
DEBUGFS_BASE="/sys/kernel/debug/user_runtime"
ALL_USERS_FILE="${DEBUGFS_BASE}/all_users"
STRESS_CMD="stress"
LOG_FILE="per_user_test_$(date +%Y%m%d_%H%M%S).log"

# --- Colors for output ---
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'

# Helper functions
log() { echo -e "$*" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}ERROR: $*${NC}" | tee -a "$LOG_FILE"; exit 1; }
warn() { echo -e "${YELLOW}WARNING: $*${NC}" | tee -a "$LOG_FILE"; }

check_command() { command -v "$1" &>/dev/null || error "Missing $1"; }
get_uid() { id -u "$1" 2>/dev/null || error "User $1 not found"; }

get_runtime() {
    local uid=$1
    grep -E "^\s*${uid}\s+" "$ALL_USERS_FILE" 2>/dev/null | awk '{print $2}' || echo 0
}

reset_user() {
    local uid=$1
    local reset_file="${DEBUGFS_BASE}/${uid}/reset"
    if [[ -f "$reset_file" ]]; then
        echo 1 > "$reset_file" 2>/dev/null && log "Reset user $uid"
    else
        warn "Reset file for UID $uid not found; runtime may not be zero."
    fi
}

cleanup() { sudo pkill -f "$STRESS_CMD" 2>/dev/null || true; }
trap cleanup EXIT

# --- Build associative array mapping username -> task count ---
declare -A TASK_MAP
for i in "${!USER_NAMES[@]}"; do
    TASK_MAP["${USER_NAMES[$i]}"]=${USER_TASKS[$i]}
done

# --- Parse command line arguments ---
DURATION=60
CPU=0
if [[ $# -ge 1 ]]; then
    DURATION=$1
fi
if [[ $# -ge 2 ]]; then
    CPU=$2
fi

# --- Validate configuration ---
if [[ ${#USER_TASKS[@]} -ne 4 ]]; then
    error "USER_TASKS must have exactly 4 entries."
fi

# --- Initial checks ---
log "=== Per-User Fairness Multi-User Test ==="
log "Test duration: ${DURATION}s, pinned to CPU $CPU"
log "Task counts per user: ${USER_TASKS[0]} ${USER_TASKS[1]} ${USER_TASKS[2]} ${USER_TASKS[3]}"
log "Log file: $LOG_FILE"

[[ -d "$DEBUGFS_BASE" ]] || error "Debugfs $DEBUGFS_BASE not found"
[[ -f "$ALL_USERS_FILE" ]] || error "all_users file missing"
check_command "$STRESS_CMD"; check_command "taskset"
sudo -v || error "Sudo required"

# --- Create test users if needed ---
for user in "${USER_NAMES[@]}"; do
    tasks=${TASK_MAP[$user]}
    if [[ $tasks -gt 0 ]] && ! id "$user" &>/dev/null; then
        log "Creating user $user..."
        sudo useradd -m "$user"
    fi
done

# --- Get UIDs ---
declare -A UID_MAP
for user in "${USER_NAMES[@]}"; do
    tasks=${TASK_MAP[$user]}
    if [[ $tasks -gt 0 ]]; then
        UID_MAP[$user]=$(get_uid "$user")
        log "User $user UID=${UID_MAP[$user]} tasks=$tasks"
    fi
done

# --- Reset all active users ---
log "Resetting user runtimes (if reset files exist)..."
for user in "${!UID_MAP[@]}"; do
    reset_user "${UID_MAP[$user]}"
done
sleep 1  # allow any pending writes

# --- Record initial runtimes ---
declare -A RUNTIME_BEFORE
for user in "${!UID_MAP[@]}"; do
    RUNTIME_BEFORE[$user]=$(get_runtime "${UID_MAP[$user]}")
done
log "Initial runtimes:"
for user in "${!UID_MAP[@]}"; do
    log "  $user: ${RUNTIME_BEFORE[$user]} ns"
done

# --- Launch tasks ---
log "Launching tasks..."
for user in "${!UID_MAP[@]}"; do
    tasks=${TASK_MAP[$user]}
    if [[ $tasks -gt 0 ]]; then
        log "  Starting $tasks stressor(s) under $user"
        sudo -u "$user" taskset -c "$CPU" "$STRESS_CMD" -c "$tasks" -t "$DURATION" &
    fi
done

# Wait for all background jobs to finish
log "Waiting ${DURATION}s for workloads to complete..."
wait

# --- Record final runtimes ---
declare -A RUNTIME_AFTER
for user in "${!UID_MAP[@]}"; do
    RUNTIME_AFTER[$user]=$(get_runtime "${UID_MAP[$user]}")
done
log "Final runtimes:"
for user in "${!UID_MAP[@]}"; do
    log "  $user: ${RUNTIME_AFTER[$user]} ns"
done

# --- Compute deltas and shares ---
declare -A DELTA
total_delta=0
for user in "${!UID_MAP[@]}"; do
    DELTA[$user]=$((RUNTIME_AFTER[$user] - RUNTIME_BEFORE[$user]))
    total_delta=$((total_delta + DELTA[$user]))
    log "Delta $user: ${DELTA[$user]} ns ($((DELTA[$user]/1000000)) ms)"
done

if [[ $total_delta -gt 0 ]]; then
    log "\n${GREEN}CPU time shares (based on total delta):${NC}"
    for user in "${!UID_MAP[@]}"; do
        share=$(( (DELTA[$user] * 100) / total_delta ))
        log "  $user = $share%"
    done

    # Optionally compute expected shares based on task counts (equal weight assumption)
    if [[ -f "${DEBUGFS_BASE}/user_weights" ]]; then
        log "\nExpected shares (if all users had equal weight):"
        total_tasks=0
        for user in "${!UID_MAP[@]}"; do
            total_tasks=$((total_tasks + TASK_MAP[$user]))
        done
        for user in "${!UID_MAP[@]}"; do
            tasks=${TASK_MAP[$user]}
            expected=$(( (tasks * 100) / total_tasks ))
            log "  $user (tasks=$tasks) = $expected%"
        done
    fi
else
    warn "No CPU time accumulated (total_delta=0)."
fi

log "\nTest completed. Log saved to $LOG_FILE"

# --- Optional: delete test users ---
read -p "Delete test users? (y/N) " -r answer
if [[ $answer =~ ^[Yy]$ ]]; then
    for user in "${!UID_MAP[@]}"; do
        sudo userdel -r "$user" 2>/dev/null || warn "Could not delete $user"
    done
    log "Test users removed."
fi

exit 0
