CC = gcc
CFLAGS = -Wall -Wextra -O2
TARGET = monitor.exe
SRCS = monitor.c

all: $(TARGET)

$(TARGET): $(SRCS)
	$(CC) $(CFLAGS) -o $(TARGET) $(SRCS)

clean:
	rm -f $(TARGET) *.o

.PHONY: all clean
