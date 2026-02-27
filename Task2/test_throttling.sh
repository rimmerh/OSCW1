#!/bin/bash
# test_throttling.sh

echo "=== Testing User Throttling ==="

# Create test users
for i in {1..4}; do
    if ! id "testuser$i" &>/dev/null; then
        useradd -m -s /bin/bash "testuser$i"
    fi
done

# Start monitor
(
    while true; do
        clear
        echo "=== User CPU Stats ==="
        cat /proc/user_sched_stats 2>/dev/null || echo "No stats"
        echo ""
        echo "=== Top CPU Consumers ==="
        ps -eo uid,pid,pcpu,comm | grep -E "stress|cpu_spam" | sort -k3 -rn | head -10
        sleep 2
    done
) &
MONITOR=$!

# Test 1: Create imbalance - one user with many processes
echo "Creating imbalance - testuser1 with 8 processes, others with 1 each"
for i in {1..8}; do
    sudo -u testuser1 taskset -c 0-3 ./cpu_spam &
done

sudo -u testuser2 taskset -c 0-3 ./cpu_spam &
sudo -u testuser3 taskset -c 0-3 ./cpu_spam &
sudo -u testuser4 taskset -c 0-3 ./cpu_spam &

echo "Running for 10 seconds..."
sleep 10

# Cleanup
killall cpu_spam 2>/dev/null
kill $MONITOR 2>/dev/null

echo ""
echo "Final Stats:"
cat /proc/user_sched_stats

echo "Test complete"
