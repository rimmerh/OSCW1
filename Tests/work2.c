// Simple CPU-bound workload for N seconds of CPU time
// Makes repeated access and updates to a large array, then exits
// Run as ./work2 N

#include <stdio.h>
#include <stdlib.h>
#include <time.h>

int main(int argc, char *argv[]) {
		if (argc != 2) {
				fprintf(stderr, "Usage: %s N\n", argv[0]);
				return 1;
		}

		int N = atoi(argv[1]);
		if (N <= 0) {
				fprintf(stderr, "N must be a positive integer\n");
				return 1;
		}

		// Allocate a large array to ensure we have enough work to do
		const size_t SIZE = 100000000; // 100 million integers
		int *array = malloc(SIZE * sizeof(int));
		if (!array) {
				fprintf(stderr, "Failed to allocate memory\n");
				return 1;
		}

		// Initialize the array with some values
		for (size_t i = 0; i < SIZE; i++) {
				array[i] = (int)i;
		}

		// Get the start time (CPU time, excludes unscheduled time)
		struct timespec start_time;
		if (clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &start_time) != 0) {
				fprintf(stderr, "Failed to get CPU time\n");
				free(array);
				return 1;
		}

		// Keep working until N seconds of CPU time have passed
		while (1) {
				// Touch and update each element to keep the CPU busy
				for (size_t i = 0; i < SIZE; i++) {
						array[i] = array[i] + 1;
				}

				// Check if N seconds of CPU time have passed
				struct timespec current_time;
				if (clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &current_time) != 0) {
						fprintf(stderr, "Failed to get CPU time\n");
						break;
				}
				double elapsed_time = (double)(current_time.tv_sec - start_time.tv_sec)
						+ (double)(current_time.tv_nsec - start_time.tv_nsec) / 1000000000.0;
				if (elapsed_time >= (double)N) {
						break;
				}
		}

		free(array);
		return 0;
}
