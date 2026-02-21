#!/bin/bash

echo "=== CPU Monitor Test with Test Users ==="

# Clean up
pkill -f cpu_spam 2>/dev/null
pkill -f monitor.exe 2>/dev/null

# Compile
make clean
make
gcc -o cpu_spam cpu_spam.c

# Create test users if they don't exist
for user in testuser1 testuser2 testuser3; do
    if ! id "$user" &>/dev/null; then
        echo "Creating user $user"
        sudo useradd "$user"
    fi
done

echo -e "\n=== User Information ==="
for user in testuser1 testuser2 testuser3; do
    id $user
done

echo -e "\n=== Starting Test Processes ==="

# Start processes with explicit CPU work
for user in testuser1 testuser2 testuser3; do
    echo "Starting process for $user"
    # Run with nice -n 0 to ensure they get CPU time
    sudo -u $user nice -n 0 ./cpu_spam &
    pid=$!
    echo "  PID: $pid"
    
    # Verify the process is running as correct user
    sleep 1
    ps -p $pid -o pid,uid,user,cmd
    echo "  /proc/$pid owner: $(ls -ld /proc/$pid | awk '{print $3}')"
    echo "  /proc/$pid/status Uid: $(grep ^Uid: /proc/$pid/status)"
    echo ""
done

# Also run a process as current user
echo "Starting process for current user ($USER)"
./cpu_spam &
pid=$!
echo "  PID: $pid"
ps -p $pid -o pid,uid,user,cmd
echo "  /proc/$pid owner: $(ls -ld /proc/$pid | awk '{print $3}')"
echo "  /proc/$pid/status Uid: $(grep ^Uid: /proc/$pid/status)"
echo ""

echo -e "\n=== Running Monitor for 10 seconds ==="
./monitor.exe 10

# Clean up
echo -e "\n=== Cleaning Up ==="
pkill -f cpu_spam

echo "Test complete!"
