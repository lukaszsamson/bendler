// Make the real poll/write race deterministic, without changing poll results.
#define _POSIX_C_SOURCE 200809L
#include <time.h>
#include <unistd.h>
static ssize_t delayed_write(int fd, const void* bytes, size_t size) {
  if (fd > STDERR_FILENO) {
    struct timespec delay = {0, 200000000};
    nanosleep(&delay, NULL);
  }
  return write(fd, bytes, size);
}
#define write delayed_write
#ifndef BENDLER_LAUNCHER_SOURCE
#define BENDLER_LAUNCHER_SOURCE "../../priv/c/bendler_launcher.c"
#endif
#include BENDLER_LAUNCHER_SOURCE
