#define _POSIX_C_SOURCE 200809L
#include <time.h>
#include <unistd.h>

// A worker can reject input while the relay still has request bytes queued.
int main(void) {
  const unsigned char ready[] = {0, 0, 0, 1, 1};
  if (write(1, ready, sizeof ready) != sizeof ready) return 74;
  struct timespec delay = {0, 50000000};
  nanosleep(&delay, NULL);
  close(0);
  delay.tv_nsec = 400000000;
  nanosleep(&delay, NULL);
  const unsigned char final[] = {0, 0, 0, 1, 2};
  if (write(1, final, sizeof final) != sizeof final) return 74;
  return 65;
}
