#!/bin/bash

# TEST 1
# Simple entanglement test with 2 users and 2 static entangled CPUs

# set simple entangled CPUs (1, 3)
X=1
Y=3
echo $X > /proc/sys/kernel/entangled_cpus_1
echo $Y > /proc/sys/kernel/entangled_cpus_2

sleep 1

# compile the test program
gcc -o work work.c

# set up ftrace
echo 0 > /sys/kernel/debug/tracing/tracing_on
echo nop > /sys/kernel/debug/tracing/current_tracer
echo 1 > /sys/kernel/debug/tracing/events/sched/sched_switch/enable
printf "%x\n" "$(( (1 << X) | (1 << Y) ))" > /sys/kernel/debug/tracing/tracing_cpumask

echo 1 > /sys/kernel/debug/tracing/tracing_on

# simple entanglement test
/bin/su -s /bin/bash -c "taskset -c $X ./work 10" testuser1 &
/bin/su -s /bin/bash -c "taskset -c $Y ./work 10" testuser2 &

sleep 10

# disable tracing
echo 0 > /sys/kernel/debug/tracing/tracing_on
cp /sys/kernel/debug/tracing/trace ./trace.txt
