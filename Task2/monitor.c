#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#include <pwd.h>
#include <errno.h>

#define MAX_USERS 256
#define BUFFER_SIZE 4096

typedef struct {
    uid_t uid;
    char username[256];
    unsigned long long runtime_ns;      // runtime in nanoseconds
    unsigned long long delta_ms;        // computed delta in milliseconds
} user_runtime_t;

const char* get_username(uid_t uid) {
    struct passwd *pw = getpwuid(uid);
    return pw ? pw->pw_name : "unknown";
}

// Read all_users file and fill the users array, returning number of users found.
int read_all_users(user_runtime_t *users, int max_users) {
    FILE *fp = fopen("/sys/kernel/debug/user_runtime/all_users", "r");
    if (!fp) {
        perror("Failed to open /sys/kernel/debug/user_runtime/all_users");
        return -1;
    }

    char line[256];
    int count = 0;

    // Skip header line
    if (!fgets(line, sizeof(line), fp)) {
        fclose(fp);
        return 0;
    }

    while (fgets(line, sizeof(line), fp) && count < max_users) {
        unsigned long long runtime;
        uid_t uid;
        if (sscanf(line, "%u %llu", &uid, &runtime) == 2) {
            users[count].uid = uid;
            strncpy(users[count].username, get_username(uid), sizeof(users[count].username)-1);
            users[count].username[sizeof(users[count].username)-1] = '\0';
            users[count].runtime_ns = runtime;
            users[count].delta_ms = 0;
            count++;
        }
    }

    fclose(fp);
    return count;
}

int compare_user_delta(const void *a, const void *b) {
    const user_runtime_t *ua = (const user_runtime_t *)a;
    const user_runtime_t *ub = (const user_runtime_t *)b;
    if (ub->delta_ms > ua->delta_ms) return 1;
    if (ub->delta_ms < ua->delta_ms) return -1;
    return 0;
}

int main(int argc, char *argv[]) {
    if (argc != 2) {
        fprintf(stderr, "Usage: %s <seconds>\n", argv[0]);
        return 1;
    }

    int duration = atoi(argv[1]);
    if (duration <= 0) {
        fprintf(stderr, "Duration must be positive\n");
        return 1;
    }

    user_runtime_t users_start[MAX_USERS];
    user_runtime_t users_end[MAX_USERS];
    int num_start, num_end;

    // Read initial snapshot
    num_start = read_all_users(users_start, MAX_USERS);
    if (num_start < 0) return 1;

    printf("Monitoring for %d seconds...\n", duration);
    fflush(stdout);

    // Wait for the test duration
    sleep(duration);

    // Read final snapshot
    num_end = read_all_users(users_end, MAX_USERS);
    if (num_end < 0) return 1;

    // Compute deltas: for each user in final, find initial runtime (if any)
    user_runtime_t results[MAX_USERS];
    int num_results = 0;

    for (int i = 0; i < num_end; i++) {
        uid_t uid = users_end[i].uid;
        unsigned long long runtime_end = users_end[i].runtime_ns;
        unsigned long long runtime_start = 0;

        // Find if this uid existed at start
        for (int j = 0; j < num_start; j++) {
            if (users_start[j].uid == uid) {
                runtime_start = users_start[j].runtime_ns;
                break;
            }
        }

        unsigned long long delta_ns = runtime_end - runtime_start;
        unsigned long long delta_ms = delta_ns / 1000000;   // ns -> ms

        if (delta_ms > 0) {
            results[num_results].uid = uid;
            strncpy(results[num_results].username, users_end[i].username,
                    sizeof(results[num_results].username)-1);
            results[num_results].username[sizeof(results[num_results].username)-1] = '\0';
            results[num_results].delta_ms = delta_ms;
            num_results++;
        }
    }

    // Sort results by delta_ms descending
    if (num_results > 0) {
        qsort(results, num_results, sizeof(user_runtime_t), compare_user_delta);
    }

    // Print final results
    printf("\n%-6s  %-15s  %-21s\n", "Rank", "User", "CPU Time (milliseconds)");
    printf("%-6s  %-15s  %-21s\n", "------", "---------------", "---------------------");

    for (int i = 0; i < num_results; i++) {
        printf("%-6d  %-15s  %21llu\n",
               i+1, results[i].username, results[i].delta_ms);
    }

    return 0;
}
