// Just a workload that does meaningless work for N secs
// Makes sequential access to a large array for its lifetime, then dies
// Run as ./work N

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
				array[i] = i;
		}

		// Get the start time
		clock_t start_time = clock();

		// Keep working until N seconds have passed
		while (1) {
				// Do some work by summing the elements of the array
				long long sum = 0;
				for (size_t i = 0; i < SIZE; i++) {
						sum += array[i];
				}

				// Check if N seconds have passed
				clock_t current_time = clock();
				double elapsed_time = (double)(current_time - start_time) / CLOCKS_PER_SEC;
				if (elapsed_time >= N) {
						break;
				}
		}

		free(array);
		return 0;
}