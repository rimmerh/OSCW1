#!/bin/bash
# test_user_sched.sh

# Configuration
NUM_USERS=4
NUM_PROCESSES_PER_USER=2
TEST_DURATION=30  # seconds

sudo stress-ng --temp-path /tmp/stress-tmp/ -c 10 -t 10

echo "=== User Equitable Scheduling Test ==="

# Create test users (if they don't exist)
for i in $(seq 1 $NUM_USERS); do
    USER="testuser$i"
    if ! id "$USER" &>/dev/null; then
        useradd -m -s /bin/bash "$USER"
        echo "Created user: $USER"
    fi
done

# Function to run CPU stress as specific user
run_cpu_stress() {
    local user=$1
    local id=$2
    
    echo "Starting stress-ng for $user (process $id)"
    sudo -u "$user" taskset -c 0-3 stress-ng --cpu 1 --cpu-load 100 \
        --timeout ${TEST_DURATION}s --metrics-brief &
}

# Start monitoring in background
(
    echo "Starting CPU usage monitoring..."
    for i in $(seq 1 $TEST_DURATION); do
        echo "=== Time $i seconds ===" >> /tmp/cpu_usage.log
        ps -eo uid,pid,pcpu,comm | grep "stress-ng" >> /tmp/cpu_usage.log
        cat /proc/user_stats >> /tmp/user_stats.log 2>/dev/null
        sleep 1
    done
) &

# Start test processes
echo "Starting $((NUM_USERS * NUM_PROCESSES_PER_USER)) CPU-intensive processes..."

for i in $(seq 1 $NUM_USERS); do
    USER="testuser$i"
    for j in $(seq 1 $NUM_PROCESSES_PER_USER); do
        run_cpu_stress "$USER" "$j"
    done
done

echo "Test running for $TEST_DURATION seconds..."
echo "Monitor: watch -n 1 'cat /proc/user_stats'"
sleep $TEST_DURATION

# Cleanup
echo "Cleaning up..."
killall stress-ng

# Show results
echo ""
echo "=== Results ==="
echo "CPU Usage by UID:"
awk '{sum[$1] += $3} END {for (uid in sum) print "UID", uid, ":", sum[uid], "% CPU"}' /tmp/cpu_usage.log

echo ""
echo "Scheduler Statistics:"
cat /proc/user_stats 2>/dev/null || echo "No user stats available"

# Cleanup test users (optional)
# for i in $(seq 1 $NUM_USERS); do
#     userdel -r "testuser$i"
# done

echo "Test complete"
