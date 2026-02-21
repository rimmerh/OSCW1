// cpu_spam.c
#include <stdio.h>
#include <unistd.h>

int main() {
    printf("PID: %d\n", getpid());
    printf("Spamming CPU... Press Ctrl+C to stop\n");
    
    while(1) {
        // Busy loop to consume CPU
        for(volatile long long i = 0; i < 1000000000; i++);
        sleep(1);  // Brief pause to make it manageable
    }
    return 0;
}
