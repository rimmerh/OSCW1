#!/bin/bash

echo "=== Testing CPU Monitor ==="

# Clean up any old processes
pkill -f cpu_spam 2>/dev/null

# Compile everything
echo "Compiling..."
make clean
make
gcc -o cpu_spam cpu_spam.c

# Start some CPU-intensive processes
echo "Starting test processes..."
for i in {1..3}; do
    ./cpu_spam &
    echo "Started cpu_spam #$i with PID $!"
done

# Also start some lightweight processes
sleep 60 &
echo "Started sleep process with PID $!"

echo "Running monitor for 10 seconds..."
./monitor.exe 10

# Clean up
echo "Cleaning up..."
pkill -f cpu_spam
pkill -f sleep

echo "Test complete!"
