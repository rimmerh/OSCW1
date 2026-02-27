#!/bin/bash

echo "=== CPU Monitor Debug Test ==="

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

echo -e "\n=== User UIDs ==="
id testuser1
id testuser2
id testuser3

# Start test processes
echo -e "\n=== Starting Test Processes ==="
sudo -u testuser1 ./cpu_spam &
PID1=$!
echo "testuser1 process: PID $PID1"

# (2B) Second testuser1 process
sudo -u testuser1 ./cpu_spam &
PID1=$!
echo "testuser1 second process: PID $PID1"

# (2B) Second testuser1 process
sudo -u testuser1 ./cpu_spam &
PID1=$!
echo "testuser1 second process: PID $PID1"

# (2B) Second testuser1 process
sudo -u testuser1 ./cpu_spam &
PID1=$!
echo "testuser1 second process: PID $PID1"

# (2B) Second testuser1 process
sudo -u testuser1 ./cpu_spam &
PID1=$!
echo "testuser1 second process: PID $PID1"

# (2B) Second testuser1 process
sudo -u testuser1 ./cpu_spam &
PID1=$!
echo "testuser1 second process: PID $PID1"


sudo -u testuser2 ./cpu_spam &
PID2=$!
echo "testuser2 process: PID $PID2"

sudo -u testuser3 ./cpu_spam &
PID3=$!
echo "testuser3 process: PID $PID3"

# Also run a process as current user
./cpu_spam &
PID4=$!
echo "current user process: PID $PID4"

# Give processes time to start
sleep 2

echo -e "\n=== Verifying Process UIDs ==="
echo "Method 1: ps output"
ps -p $PID1,$PID2,$PID3,$PID4 -o pid,uid,user,cmd

echo -e "\nMethod 2: /proc directory ownership"
for pid in $PID1 $PID2 $PID3 $PID4; do
    ls -ld /proc/$pid
done

echo -e "\nMethod 3: /proc/[pid]/status Uid: line"
for pid in $PID1 $PID2 $PID3 $PID4; do
    echo "PID $pid: $(grep ^Uid: /proc/$pid/status)"
done

echo -e "\n=== Running Monitor ==="
./monitor.exe 5

# Clean up
echo -e "\n=== Cleaning Up ==="
kill $PID1 $PID2 $PID3 $PID4 2>/dev/null
sleep 1
pkill -f cpu_spam

echo "Test complete!"
