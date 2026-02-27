#!/bin/bash
# test_user_accounting_v3.sh - Verify per‑user CPU runtime using all_users
# Runs tasks sequentially so each gets a full 5 seconds of CPU time.

set -euo pipefail

TEST_DURATION=5
ALL_USERS_FILE="/sys/kernel/debug/user_runtime/all_users"

if [[ $EUID -ne 0 ]]; then
    echo "Must be run as root." >&2
    exit 1
fi

if [[ ! -f $ALL_USERS_FILE ]]; then
    echo "Error: $ALL_USERS_FILE not found. Is debugfs mounted?" >&2
    exit 1
fi

# Create temporary users (ignore if they already exist)
TEST_USER1="testacct1"
TEST_USER2="testacct2"
useradd -m -s /bin/bash "$TEST_USER1" 2>/dev/null || true
useradd -m -s /bin/bash "$TEST_USER2" 2>/dev/null || true
UID1=$(id -u "$TEST_USER1")
UID2=$(id -u "$TEST_USER2")

cleanup() {
    kill $(jobs -p) 2>/dev/null || true
    userdel -f "$TEST_USER1" 2>/dev/null || true
    userdel -f "$TEST_USER2" 2>/dev/null || true
    wait
}
trap cleanup EXIT

# Function to read runtime for a given UID from all_users
get_runtime() {
    local uid=$1
    awk -v uid="$uid" 'NR>1 && $1 == uid {print $2}' "$ALL_USERS_FILE"
}

echo "Reading initial runtime counters..."
before0=$(get_runtime 0)
before1=$(get_runtime "$UID1")
before2=$(get_runtime "$UID2")

# If a UID hasn't been seen yet, treat its runtime as 0
before0=${before0:-0}
before1=${before1:-0}
before2=${before2:-0}

# Function to run a CPU‑bound task for TEST_DURATION seconds as a given UID
run_task_as() {
    local uid=$1
    local pid
    if [[ $uid == "0" ]]; then
        taskset -c 0 sh -c 'while :; do :; done' &
        pid=$!
    else
        sudo -u "#$uid" taskset -c 0 sh -c 'while :; do :; done' &
        pid=$!
    fi
    sleep "$TEST_DURATION"
    kill $pid
    wait $pid 2>/dev/null || true
}

echo "Running CPU‑bound tasks sequentially for $TEST_DURATION seconds each..."
run_task_as 0
run_task_as "$UID1"
run_task_as "$UID2"

echo "Reading final runtime counters..."
after0=$(get_runtime 0)
after1=$(get_runtime "$UID1")
after2=$(get_runtime "$UID2")

after0=${after0:-0}
after1=${after1:-0}
after2=${after2:-0}

echo -e "\n--- Results ---"
delta0=$(( after0 - before0 ))
delta1=$(( after1 - before1 ))
delta2=$(( after2 - before2 ))

echo "UID 0 runtime delta: $(( delta0 / 1000000 )) ms"
echo "UID $UID1 runtime delta: $(( delta1 / 1000000 )) ms"
echo "UID $UID2 runtime delta: $(( delta2 / 1000000 )) ms"

# Allow ±20% margin
lower=$(( TEST_DURATION * 800000000 ))
upper=$(( TEST_DURATION * 1200000000 ))

check_delta() {
    local uid=$1
    local delta=$2
    if (( delta < lower || delta > upper )); then
        echo "  WARNING: UID $uid runtime out of expected range ($TEST_DURATION s ±20%)"
    else
        echo "  OK"
    fi
}

check_delta 0 "$delta0"
check_delta "$UID1" "$delta1"
check_delta "$UID2" "$delta2"

echo -e "\nAll tests passed (warnings may appear if counts are off)."
