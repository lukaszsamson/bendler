// POSIX worker guardian. The BEAM owns this relay's stdin; EOF or a signal
// terminates the worker process group, escalates after 200 ms, and reaps it.
// No shell, PID files or application-provided kill commands are involved.
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t stopping;
static void stop_signal(int sig) { (void)sig; stopping = 1; }
static int transport_error(const char* operation) {
  int code = errno;
  fprintf(stderr, "bendler launcher: %s: errno=%d (%s)\n", operation, code, strerror(code));
  return 74;
}
static void poll_error(const char* endpoint, short events) {
  fprintf(stderr, "bendler launcher: %s: poll revents=0x%x\n", endpoint, (unsigned short)events);
}
static int64_t milliseconds(void) {
  struct timespec t;
  if (clock_gettime(CLOCK_MONOTONIC, &t)) return 0;
  return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
static int nonblocking(int fd) {
  int flags = fcntl(fd, F_GETFL);
  return flags == -1 ? -1 : fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}
static int worker_group(pid_t child) {
  if (setpgid(child, child) == 0) return 0;
  int code = errno;
  // Either side may establish the group first. Darwin can report EPERM
  // on the redundant operation; accept only the verified intended group.
  pid_t expected = child == 0 ? getpid() : child;
  if (code == EPERM && getpgid(child) == expected) return 0;
  errno = code;
  return -1;
}
typedef struct { unsigned char bytes[65536]; size_t n; } Buffer;
static int receive(int fd, Buffer* b) {
  ssize_t n = read(fd, b->bytes + b->n, sizeof b->bytes - b->n);
  if (n > 0) { b->n += (size_t)n; return 1; }
  if (n == 0) return 0;
  return errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK ? 1 : -1;
}
static int transmit(int fd, Buffer* b) {
  ssize_t n = write(fd, b->bytes, b->n);
  if (n > 0) {
    b->n -= (size_t)n;
    memmove(b->bytes, b->bytes + n, b->n);
    return 0;
  }
  return n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) ? 0 : -1;
}
static void terminate_worker(pid_t child, bool reaped) {
  // Keep the child's PID reserved until KILL has been sent to its group:
  // do not reap early and then risk signalling a recycled process-group id.
  if (!reaped) {
    (void)kill(-child, SIGTERM);
    int64_t deadline = milliseconds() + 200;
    while (milliseconds() < deadline) (void)poll(NULL, 0, 10);
    (void)kill(-child, SIGKILL);
    while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
  }
}

int main(int argc, char** argv) {
  if (argc < 2) { fprintf(stderr, "bendler launcher: worker path required\n"); return 64; }
  struct sigaction action;
  memset(&action, 0, sizeof action);
  sigemptyset(&action.sa_mask);
  action.sa_handler = stop_signal;
  if (sigaction(SIGTERM, &action, NULL) || sigaction(SIGINT, &action, NULL)) return transport_error("sigaction stop");
  action.sa_handler = SIG_IGN;
  if (sigaction(SIGPIPE, &action, NULL)) return transport_error("sigaction SIGPIPE");
  int input[2], output[2];
  if (pipe(input)) return transport_error("pipe worker stdin");
  if (pipe(output)) { int result = transport_error("pipe worker stdout"); close(input[0]); close(input[1]); return result; }
  pid_t child = fork();
  if (child < 0) return transport_error("fork");
  if (child == 0) {
    if (worker_group(0) || dup2(input[0], STDIN_FILENO) < 0 || dup2(output[1], STDOUT_FILENO) < 0)
      _exit(transport_error("worker setpgid/dup2"));
    close(input[0]); close(input[1]); close(output[0]); close(output[1]);
    action.sa_handler = SIG_DFL;
    (void)sigaction(SIGTERM, &action, NULL);
    (void)sigaction(SIGINT, &action, NULL);
    (void)sigaction(SIGPIPE, &action, NULL);
    execv(argv[1], argv + 1);
    perror("bendler launcher: execv");
    _exit(74);
  }
  close(input[0]); close(output[1]);
  // Either side can win the race to setpgid; EACCES means exec already ran.
  if (worker_group(child) && errno != EACCES && errno != ESRCH) {
    transport_error("parent setpgid");
    (void)kill(child, SIGKILL);
    while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
    return 74;
  }
  bool reaped = false, eof = false;
  int worker_result = 74, result = 74;
  Buffer in = {{0}, 0}, out = {{0}, 0};
  if (nonblocking(0) || nonblocking(1) || nonblocking(input[1]) || nonblocking(output[0])) {
    transport_error("fcntl nonblocking"); stopping = 1;
  }
  while (!stopping) {
    struct pollfd fds[] = {
      {0, input[1] >= 0 && in.n < sizeof in.bytes ? POLLIN : 0, 0},
      {input[1], in.n ? POLLOUT : 0, 0},
      {output[0], !eof && out.n < sizeof out.bytes ? POLLIN : 0, 0},
      {1, out.n ? POLLOUT : 0, 0}
    };
    if (poll(fds, 4, 25) < 0) { if (errno == EINTR) continue; transport_error("poll"); break; }
    if (fds[0].revents & (POLLERR | POLLNVAL)) { poll_error("owner stdin", fds[0].revents); break; }
    if (fds[0].revents & POLLHUP) break;
    if (fds[0].revents & POLLIN) {
      int r = receive(0, &in);
      if (r < 0) { transport_error("read owner stdin"); break; }
      if (r == 0) break;
    }
    if (fds[1].revents & POLLNVAL) { poll_error("worker stdin", fds[1].revents); break; }
    bool input_closed = (fds[1].revents & (POLLHUP | POLLERR)) != 0;
    if (!input_closed && (fds[1].revents & POLLOUT) && transmit(input[1], &in)) {
      if (errno != EPIPE) { transport_error("write worker stdin"); break; }
      input_closed = true;
    }
    if (input_closed) {
      // A rejecting/exiting worker may close stdin with request bytes queued.
      // Drain its output and collect its status instead of replacing it by 74.
      close(input[1]); input[1] = -1; in.n = 0;
    }
    if ((fds[2].revents & (POLLIN | POLLHUP)) && out.n < sizeof out.bytes) {
      int r = receive(output[0], &out);
      if (r < 0) { transport_error("read worker stdout"); break; }
      eof = r == 0;
    }
    if (fds[2].revents & (POLLERR | POLLNVAL)) { poll_error("worker stdout", fds[2].revents); break; }
    if (fds[3].revents & (POLLERR | POLLHUP | POLLNVAL)) { poll_error("owner stdout", fds[3].revents); break; }
    if ((fds[3].revents & POLLOUT) && transmit(1, &out)) { transport_error("write owner stdout"); break; }
    if (!reaped) {
      // Observe exit without releasing the group leader's PID. Kill any
      // descendants before reaping, so the group id cannot be recycled.
      siginfo_t info;
      memset(&info, 0, sizeof info);
      int r = waitid(P_PID, (id_t)child, &info, WEXITED | WNOHANG | WNOWAIT);
      if (r == 0 && info.si_pid == child) {
        worker_result = info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status;
        if (worker_result) fprintf(stderr, "bendler launcher: worker exit status=%d (si_code=%d)\n", worker_result, info.si_code);
        terminate_worker(child, false);
        reaped = true;
      } else if (r < 0 && errno != EINTR) { transport_error("waitid"); break; }
    }
    if (reaped && eof && out.n == 0) { result = worker_result; break; }
  }
  terminate_worker(child, reaped);
  if (input[1] >= 0) close(input[1]);
  close(output[0]);
  return result;
}
