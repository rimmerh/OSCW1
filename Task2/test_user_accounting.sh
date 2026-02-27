#!/bin/bash
# test_user_accounting.sh - Verify per‑user CPU runtime accounting
# Must be run as root.

set -euo pipefail

# --- Configuration -------------------------------------------------
DEBUGFS_DIR="/sys/kernel/debug/user_runtime"
TEST_DURATION=5            # seconds each test task runs
# -------------------------------------------------------------------

# Check prerequisites
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root." >&2
    exit 1
fi

if ! mount | grep -q debugfs; then
    echo "debugfs not mounted. Mount it with: mount -t debugfs none /sys/kernel/debug" >&2
    exit 1
fi

if [[ ! -d "$DEBUGFS_DIR" ]]; then
    echo "Debugfs directory $DEBUGFS_DIR not found. Did you add the user_runtime debugfs interface?" >&2
    exit 1
fi

# Helper: read runtime for a UID (returns nanoseconds)
read_uid_runtime() {
    local uid="$1"
    local file="$DEBUGFS_DIR/$uid"
    if [[ -f "$file" ]]; then
        cat "$file"
    else
        echo "0"
    fi
}

# Helper: run a CPU‑bound task for a given UID for $TEST_DURATION seconds
# The task runs in a tight loop; we use a timeout to stop it.
run_task_as_uid() {
    local uid="$1"
    # Use 'timeout' to limit runtime; 'taskset' pins to CPU 0 to reduce variance
    taskset -c 0 timeout "${TEST_DURATION}s" sudo -u "#$uid" sh -c 'while :; do :; done' 2>/dev/null &
    local pid=$!
    # Record start time (monotonic, in nanoseconds)
    local start=$(date +%s%N)
    echo "$pid:$uid:$start"
}

# --- Prepare test UIDs --------------------------------------------
# We need two UIDs ≥ 1000 and two UIDs < 1000.
# For UIDs ≥ 1000, create temporary users (will be removed at exit).
# For UIDs < 1000, use existing system accounts (root=0, daemon=1).

# Temporary users
TEST_USER1="testacct1"
TEST_USER2="testacct2"

cleanup() {
    set +e
    userdel -f "$TEST_USER1" 2>/dev/null
    userdel -f "$TEST_USER2" 2>/dev/null
    kill $(jobs -p) 2>/dev/null
    wait
}
trap cleanup EXIT

echo "Creating temporary test users..."
useradd -m -s /bin/bash "$TEST_USER1"
useradd -m -s /bin/bash "$TEST_USER2"

UID1=$(id -u "$TEST_USER1")
UID2=$(id -u "$TEST_USER2")
echo "Test users: $TEST_USER1 (UID=$UID1), $TEST_USER2 (UID=$UID2)"

# Existing low UIDs
LOW_UID1=0          # root
LOW_UID2=1          # daemon (usually exists)
LOW_UID3=2          # bin (often exists; fallback to 1 if not)

# Ensure daemon and bin exist, else use root for both
if ! id -u daemon &>/dev/null; then
    LOW_UID2=0
fi
if ! id -u bin &>/dev/null; then
    LOW_UID3=0
fi

echo "Low UIDs to test: $LOW_UID1, $LOW_UID2, $LOW_UID3"

# --- Zero counters (optional: if you have a reset interface) ---
# If you have a way to reset the counters (e.g., writing to debugfs), do it here.
# Otherwise, record current values to subtract later.
declare -A before after

echo "Reading initial runtime counters..."
for uid in $UID1 $UID2 $LOW_UID1 $LOW_UID2 $LOW_UID3 0; do
    before[$uid]=$(read_uid_runtime "$uid")
done

# --- Launch tasks ------------------------------------------------
echo "Launching CPU‑bound tasks for $TEST_DURATION seconds..."
pids=()
uids=()

# Task for UID1
out=$(run_task_as_uid "$UID1")
pids+=(${out%%:*})
uids+=("$UID1")
# Task for UID2
out=$(run_task_as_uid "$UID2")
pids+=(${out%%:*})
uids+=("$UID2")
# Task for LOW_UID1 (root)
out=$(run_task_as_uid "$LOW_UID1")
pids+=(${out%%:*})
uids+=("$LOW_UID1")
# Task for LOW_UID2
out=$(run_task_as_uid "$LOW_UID2")
pids+=(${out%%:*})
uids+=("$LOW_UID2")
# Task for LOW_UID3
out=$(run_task_as_uid "$LOW_UID3")
pids+=(${out%%:*})
uids+=("$LOW_UID3")

echo "Waiting for tasks to finish..."
wait

# --- Read final counters -----------------------------------------
echo "Reading final runtime counters..."
for uid in $UID1 $UID2 $LOW_UID1 $LOW_UID2 $LOW_UID3 0; do
    after[$uid]=$(read_uid_runtime "$uid")
done

# --- Calculate and verify -----------------------------------------
echo -e "\n--- Results ---"
TOTAL_LOW=0
for uid in $UID1 $UID2; do
    delta=$(( after[$uid] - before[$uid] ))
    echo "UID $uid (≥1000) runtime: $(( delta / 1000000 )) ms"
    # Should be roughly TEST_DURATION seconds, allow ±20% margin
    lower=$(( TEST_DURATION * 800000000 ))   # 80% in ns
    upper=$(( TEST_DURATION * 1200000000 ))  # 120%
    if (( delta < lower || delta > upper )); then
        echo "  WARNING: runtime for UID $uid is out of expected range ($TEST_DURATION s ±20%)"
    else
        echo "  OK"
    fi
done

# Sum of low UIDs should be accounted under system_user (UID 0)
for uid in $LOW_UID1 $LOW_UID2 $LOW_UID3; do
    delta=$(( after[$uid] - before[$uid] ))
    echo "UID $uid (<1000) runtime: $(( delta / 1000000 )) ms"
    TOTAL_LOW=$(( TOTAL_LOW + delta ))
done

system_delta=$(( after[0] - before[0] ))
echo "System user (UID 0) total runtime: $(( system_delta / 1000000 )) ms"
echo "Sum of low UIDs: $(( TOTAL_LOW / 1000000 )) ms"

# Allow a small discrepancy (5% of total) due to process creation/exit overhead
margin=$(( TEST_DURATION * 50000000 ))   # 5% in ns
diff=$(( system_delta - TOTAL_LOW ))
if (( diff < -margin || diff > margin )); then
    echo "ERROR: System user runtime does not match sum of low UIDs (diff $diff ns)"
    exit 1
else
    echo "System user aggregation OK"
fi

echo -e "\nAll tests passed."
exit 0
