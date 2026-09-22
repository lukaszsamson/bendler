// Exercise EPERM on both sides with and without a verified worker group.
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <unistd.h>
static int raced_setpgid(pid_t pid, pid_t pgid) {
  int result = setpgid(pid, pgid);
  if (result == 0 || errno == EACCES) {
    errno = EPERM;
    return -1;
  }
  return result;
}
#ifdef REJECT_GROUP
static pid_t rejected_getpgid(pid_t pid) { (void)pid; return 0; }
#define getpgid rejected_getpgid
#endif
#define setpgid raced_setpgid
#include "../../priv/c/bendler_launcher.c"
