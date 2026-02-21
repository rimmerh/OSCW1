#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <pwd.h>
#include <time.h>
#include <errno.h>

#define MAX_PIDS 2048
#define MAX_USERS 256
#define BUFFER_SIZE 4096
#define LOG_INTERVAL 1

typedef struct {
    pid_t pid;
    uid_t uid;
    char username[256];
    unsigned long long utime;
    unsigned long long stime;
    unsigned long long total_time;        // Current total CPU time
    unsigned long long initial_cpu_time;   // CPU time when first seen (ABSOLUTE value)
    unsigned long long first_seen_tick;    // Virtual tick when first seen (for logging)
    int active;
} process_info_t;

typedef struct {
    uid_t uid;
    char username[256];
    unsigned long long total_cpu_time;
} user_cpu_t;

const char* get_username(uid_t uid) {
    struct passwd *pw = getpwuid(uid);
    return pw ? pw->pw_name : "unknown";
}

int read_process_stat(pid_t pid, unsigned long long *utime, unsigned long long *stime) {
    char path[256];
    char buffer[BUFFER_SIZE];
    FILE *fp;
    
    snprintf(path, sizeof(path), "/proc/%d/stat", pid);
    fp = fopen(path, "r");
    if (!fp) return -1;
    
    if (!fgets(buffer, sizeof(buffer), fp)) {
        fclose(fp);
        return -1;
    }
    fclose(fp);
    
    int field = 1;
    char *token = strtok(buffer, " ");
    
    while (token && field < 15) {
        if (field == 14) *utime = strtoull(token, NULL, 10);
        if (field == 15) *stime = strtoull(token, NULL, 10);
        token = strtok(NULL, " ");
        field++;
    }
    
    return 0;
}

uid_t get_process_uid(pid_t pid) {
    char path[256];
    char line[256];
    FILE *fp;
    
    snprintf(path, sizeof(path), "/proc/%d/status", pid);
    fp = fopen(path, "r");
    if (fp) {
        while (fgets(line, sizeof(line), fp)) {
            if (strncmp(line, "Uid:", 4) == 0) {
                unsigned int ruid, euid, suid, fsuid;
                sscanf(line, "Uid: %u %u %u %u", &ruid, &euid, &suid, &fsuid);
                fclose(fp);
                return (uid_t)ruid;
            }
        }
        fclose(fp);
    }
    
    struct stat st;
    snprintf(path, sizeof(path), "/proc/%d", pid);
    if (stat(path, &st) == 0) {
        return st.st_uid;
    }
    
    return (uid_t)-1;
}

int compare_user_cpu(const void *a, const void *b) {
    user_cpu_t *ua = (user_cpu_t *)a;
    user_cpu_t *ub = (user_cpu_t *)b;
    
    if (ub->total_cpu_time > ua->total_cpu_time) return 1;
    if (ub->total_cpu_time < ua->total_cpu_time) return -1;
    return 0;
}

int take_initial_snapshot(process_info_t *processes, int max_processes) {
    DIR *proc_dir;
    struct dirent *entry;
    int count = 0;
    
    proc_dir = opendir("/proc");
    if (!proc_dir) {
        perror("Failed to open /proc");
        return -1;
    }
    
    while ((entry = readdir(proc_dir)) != NULL && count < max_processes) {
        char *endptr;
        pid_t pid = strtol(entry->d_name, &endptr, 10);
        if (*endptr != '\0') continue;
        
        unsigned long long utime = 0, stime = 0;
        if (read_process_stat(pid, &utime, &stime) == 0) {
            uid_t uid = get_process_uid(pid);
            if (uid != (uid_t)-1) {
                processes[count].pid = pid;
                processes[count].uid = uid;
                strncpy(processes[count].username, get_username(uid), 
                        sizeof(processes[count].username) - 1);
                processes[count].username[sizeof(processes[count].username) - 1] = '\0';
                processes[count].utime = utime;
                processes[count].stime = stime;
                processes[count].total_time = utime + stime;
                // For initial snapshot, first_seen CPU time is the current CPU time
                processes[count].initial_cpu_time = utime + stime;
                processes[count].first_seen_tick = 0;
                processes[count].active = 1;
                count++;
            }
        }
    }
    closedir(proc_dir);
    
    return count;
}

void update_snapshot(process_info_t *processes, int *num_processes, unsigned long long current_tick) {
    DIR *proc_dir;
    struct dirent *entry;
    int max_processes = *num_processes;
    
    for (int i = 0; i < max_processes; i++) {
        processes[i].active = 0;
    }
    
    proc_dir = opendir("/proc");
    if (!proc_dir) {
        perror("Failed to open /proc");
        return;
    }
    
    while ((entry = readdir(proc_dir)) != NULL) {
        char *endptr;
        pid_t pid = strtol(entry->d_name, &endptr, 10);
        if (*endptr != '\0') continue;
        
        unsigned long long utime = 0, stime = 0;
        if (read_process_stat(pid, &utime, &stime) != 0) continue;
        
        uid_t uid = get_process_uid(pid);
        if (uid == (uid_t)-1) continue;
        
        unsigned long long total = utime + stime;
        
        int found = -1;
        for (int i = 0; i < max_processes; i++) {
            if (processes[i].pid == pid) {
                found = i;
                break;
            }
        }
        
        if (found != -1) {
            // Update existing process
            processes[found].utime = utime;
            processes[found].stime = stime;
            processes[found].total_time = total;
            processes[found].active = 1;
        } else if (*num_processes < MAX_PIDS) {
            // New process detected - store its current CPU time as initial
            processes[*num_processes].pid = pid;
            processes[*num_processes].uid = uid;
            strncpy(processes[*num_processes].username, get_username(uid), 
                    sizeof(processes[*num_processes].username) - 1);
            processes[*num_processes].username[sizeof(processes[*num_processes].username) - 1] = '\0';
            processes[*num_processes].utime = utime;
            processes[*num_processes].stime = stime;
            processes[*num_processes].total_time = total;
            // CRITICAL FIX: Store the CPU time at first sight as initial_cpu_time
            processes[*num_processes].initial_cpu_time = total;
            processes[*num_processes].first_seen_tick = current_tick;
            processes[*num_processes].active = 1;
            (*num_processes)++;
        }
    }
    closedir(proc_dir);
    
    // Remove inactive processes
    int write_idx = 0;
    for (int read_idx = 0; read_idx < *num_processes; read_idx++) {
        if (processes[read_idx].active) {
            if (write_idx != read_idx) {
                memcpy(&processes[write_idx], &processes[read_idx], sizeof(process_info_t));
            }
            write_idx++;
        } else {
            printf(">>> Process terminated: PID %d (%s)\n", 
                   processes[read_idx].pid, processes[read_idx].username);
        }
    }
    *num_processes = write_idx;
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
    
    process_info_t all_procs[MAX_PIDS];
    int num_procs = 0;
    long clk_tck;
    unsigned long long current_tick = 0;
    
    clk_tck = sysconf(_SC_CLK_TCK);
    printf("Clock speed: %ld hz", clk_tck);
    if (clk_tck <= 0) {
        clk_tck = 100;
    }
    
    // Take initial snapshot
    num_procs = take_initial_snapshot(all_procs, MAX_PIDS);
    
    // Monitor loop
    for (int second = 1; second <= duration; second++) {
        sleep(LOG_INTERVAL);
        current_tick += clk_tck;  // Advance by 1 second worth of ticks
        
        update_snapshot(all_procs, &num_procs, current_tick);
    }
    
    // Calculate final results
    user_cpu_t users[MAX_USERS];
    int num_users = 0;
    
    for (int i = 0; i < num_procs; i++) {
        // CRITICAL FIX: Calculate CPU time since first_seen using initial_cpu_time
        unsigned long long delta_ticks = all_procs[i].total_time - all_procs[i].initial_cpu_time;
        
        if (delta_ticks > 0) {
            unsigned long long cpu_ms = delta_ticks * 1000 / clk_tck;
            
            // Find or create user entry
            int user_idx = -1;
            for (int k = 0; k < num_users; k++) {
                if (users[k].uid == all_procs[i].uid) {
                    user_idx = k;
                    break;
                }
            }
            
            if (user_idx == -1 && num_users < MAX_USERS) {
                user_idx = num_users;
                users[user_idx].uid = all_procs[i].uid;
                strncpy(users[user_idx].username, all_procs[i].username, 
                        sizeof(users[user_idx].username) - 1);
                users[user_idx].username[sizeof(users[user_idx].username) - 1] = '\0';
                users[user_idx].total_cpu_time = 0;
                num_users++;
            }
            
            if (user_idx != -1) {
                users[user_idx].total_cpu_time += cpu_ms;
            }
        }
    }
    
    // Sort users by CPU time
    if (num_users > 0) {
        qsort(users, num_users, sizeof(user_cpu_t), compare_user_cpu);
    }
    
    // Print final results
    printf("\n%-6s  %-15s  %-21s\n", "Rank", "User", "CPU Time (milliseconds)");
    printf("%-6s  %-15s  %-21s\n", "------", "---------------", "---------------------");
    
    for (int i = 0; i < num_users; i++) {
        printf("%-6d  %-15s  %21llu\n", 
               i + 1, users[i].username, users[i].total_cpu_time);
    }
    
    return 0;
}
