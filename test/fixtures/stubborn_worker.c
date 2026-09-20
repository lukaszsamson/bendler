#define _POSIX_C_SOURCE 200809L
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>

// First request answers the actual child PID, then computes forever and
// ignores TERM. It never cooperates by reading EOF or writing another reply.
int main(void) {
  signal(SIGTERM, SIG_IGN);
  unsigned char header[4];
  size_t done = 0;
  while (done < sizeof header) {
    ssize_t n = read(0, header + done, sizeof header - done);
    if (n <= 0) return 74;
    done += (size_t)n;
  }
  uint32_t pid = (uint32_t)getpid();
#ifdef DESCENDANT
  pid_t descendant = fork();
  if (descendant < 0) return 74;
  if (descendant == 0) {
    volatile uint32_t work = 1;
    for (;;) work = work * 1664525u + 1013904223u;
  }
  pid = (uint32_t)descendant;
#endif
  unsigned char reply[] = {0, 0, 0, 4, pid >> 24, pid >> 16, pid >> 8, pid};
  if (write(1, reply, sizeof reply) != sizeof reply) return 74;
#ifdef DESCENDANT
  return 0;
#else
  volatile uint32_t work = 1;
  for (;;) work = work * 1664525u + 1013904223u;
#endif
}
