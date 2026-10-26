#define _GNU_SOURCE
#include "linux_guest_children.h"
#include "linux_guest_sha256_core.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/*
 * Unshipped, fixed-command launch experiment for a future isolatedProcess.
 * This binary is excluded from ordinary Android builds. It neither packages
 * PRoot nor grants host files or network. stdout carries only validated
 * DSH_TRACE_V1 lines; child stdout/stderr are counted and discarded.
 * An App-side event parser, journal and device tests are still mandatory.
 */
#define MAX_TRACE_LINE 159
#define MAX_TRACE_BYTES (2 * 1024 * 1024)
#define MAX_GUEST_OUTPUT (64 * 1024)
#define MAX_LIVE_PIDS 4096
#define DEADLINE_MS 30000
#define CANCEL_GRACE_MS 2000
#define MAX_CHILDREN_SNAPSHOT 4096
#define CHILDREN_SNAPSHOT_BYTES 65536

static volatile sig_atomic_t stop_requested;

static void request_stop(int unused) {
  (void)unused;
  stop_requested = 1;
}

static int64_t now_ms(void) {
  struct timespec value;
  if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) return -1;
  return (int64_t)value.tv_sec * 1000 + value.tv_nsec / 1000000;
}

static bool run_id_ok(const char *id) {
  if (id == NULL || strlen(id) != 36) return false;
  for (int i = 0; i < 36; ++i) {
    if (i == 8 || i == 13 || i == 18 || i == 23) {
      if (id[i] != '-') return false;
    } else if (!((id[i] >= '0' && id[i] <= '9') ||
                 (id[i] >= 'a' && id[i] <= 'f'))) return false;
  }
  return true;
}

static bool decimal(const char *text, uint64_t *number) {
  if (text == NULL || *text < '0' || *text > '9' ||
      (text[0] == '0' && text[1] != 0)) return false;
  uint64_t value = 0;
  for (const char *part = text; *part; ++part) {
    if (*part < '0' || *part > '9' || value > (UINT64_MAX - (unsigned)(*part - '0')) / 10)
      return false;
    value = value * 10 + (unsigned)(*part - '0');
  }
  *number = value;
  return true;
}

static bool same_stat(const struct stat *before, const struct stat *after) {
  return before->st_dev == after->st_dev && before->st_ino == after->st_ino &&
      before->st_mode == after->st_mode && before->st_size == after->st_size &&
      before->st_mtim.tv_sec == after->st_mtim.tv_sec &&
      before->st_mtim.tv_nsec == after->st_mtim.tv_nsec &&
      before->st_ctim.tv_sec == after->st_ctim.tv_sec &&
      before->st_ctim.tv_nsec == after->st_ctim.tv_nsec;
}

static bool pinned_fd(int fd, const char *expected) {
  struct stat before, after;
  if (fstat(fd, &before) != 0 || !S_ISREG(before.st_mode) || before.st_size <= 0 ||
      before.st_size > 16 * 1024 * 1024) return false;
  size_t length = (size_t)before.st_size;
  uint8_t *bytes = malloc(length);
  if (bytes == NULL) return false;
  bool valid = true;
  size_t offset = 0;
  while (offset < length) {
    ssize_t count = pread(fd, bytes + offset, length - offset, (off_t)offset);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) { valid = false; break; }
    offset += (size_t)count;
  }
  uint8_t trailing;
  if (valid && (pread(fd, &trailing, 1, (off_t)length) != 0 ||
                fstat(fd, &after) != 0 || !same_stat(&before, &after))) valid = false;
  if (valid) {
    uint8_t digest[32];
    static const char digits[] = "0123456789abcdef";
    dsh_guest_sha256(bytes, length, digest);
    for (size_t i = 0; i < sizeof(digest); ++i) {
      if (expected[2 * i] != digits[digest[i] >> 4] ||
          expected[2 * i + 1] != digits[digest[i] & 15]) valid = false;
    }
  }
  free(bytes);
  return valid;
}

static bool installed_candidate(int *launcher_fd, int *loader_fd) {
  char self[PATH_MAX];
  ssize_t size = readlink("/proc/self/exe", self, sizeof(self) - 1);
  if (size <= 0 || size >= (ssize_t)sizeof(self) - 1) return false;
  self[size] = 0;
  char *separator = strrchr(self, '/');
  if (separator == NULL) return false;
  *separator = 0;
  if (access(self, W_OK) == 0) return false;
  char launcher[PATH_MAX], loader[PATH_MAX];
  if (snprintf(launcher, sizeof(launcher), "%s/libdsh_proot_candidate.so", self)
          >= (int)sizeof(launcher) ||
      snprintf(loader, sizeof(loader), "%s/libdsh_proot_loader_candidate.so", self)
          >= (int)sizeof(loader)) return false;
  int primary = open(launcher, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (primary < 0) return false;
  int secondary = open(loader, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  struct stat first, second;
  bool valid = secondary >= 0 && fstat(primary, &first) == 0 &&
      fstat(secondary, &second) == 0 && S_ISREG(first.st_mode) &&
      S_ISREG(second.st_mode) && first.st_size > 0 && second.st_size > 0 &&
      (first.st_mode & 0111) != 0 && (second.st_mode & 0111) != 0 &&
      access(launcher, W_OK) != 0 && access(loader, W_OK) != 0;
  if (valid) valid = pinned_fd(primary,
      "c22cdb13c5de4b6e0022f7ede7a5ca0bf88675d4b674aa339a885b96d8b26f7f") &&
      pinned_fd(secondary,
      "c5e85afb7599bd82f2419fb054d597514d5c9578954288bef0c5320cd8b63fbf");
  if (!valid) { close(primary); if (secondary >= 0) close(secondary); return false; }
  *launcher_fd = primary;
  *loader_fd = secondary;
  return true;
}

static bool rootfs_ok(const char *rootfs) {
  if (rootfs == NULL || rootfs[0] != '/' || strlen(rootfs) >= PATH_MAX) return false;
  char canonical[PATH_MAX];
  struct stat status;
  return realpath(rootfs, canonical) != NULL && strcmp(rootfs, canonical) == 0 &&
      lstat(rootfs, &status) == 0 && S_ISDIR(status.st_mode) &&
      status.st_uid == getuid() && (status.st_mode & 0222) == 0;
}

static bool nonblocking_reader(int fd) {
  int flags = fcntl(fd, F_GETFL, 0);
  return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0;
}

struct trace_state {
  char line[MAX_TRACE_LINE + 1];
  size_t line_length;
  size_t total_bytes;
  uint64_t next_sequence;
  pid_t live[MAX_LIVE_PIDS];
  size_t live_count;
  bool root_seen;
  bool arm_seen;
  bool drain_seen;
  bool invalid;
};

static bool live_contains(const struct trace_state *state, pid_t pid) {
  for (size_t i = 0; i < state->live_count; ++i)
    if (state->live[i] == pid) return true;
  return false;
}

static bool live_add(struct trace_state *state, pid_t pid) {
  if (pid <= 0 || state->live_count >= MAX_LIVE_PIDS || live_contains(state, pid)) return false;
  state->live[state->live_count++] = pid;
  return true;
}

static bool live_remove(struct trace_state *state, pid_t pid) {
  for (size_t i = 0; i < state->live_count; ++i) {
    if (state->live[i] == pid) {
      state->live[i] = state->live[--state->live_count];
      return true;
    }
  }
  return false;
}

static bool parse_event(struct trace_state *state, const char *run_id) {
  char copied[MAX_TRACE_LINE + 1];
  memcpy(copied, state->line, state->line_length);
  copied[state->line_length] = 0;
  char *fields[6];
  size_t field = 0;
  fields[field++] = copied;
  for (char *part = copied; *part; ++part) {
    if (*part == '\t') {
      if (field == 6) return false;
      *part = 0;
      fields[field++] = part + 1;
    } else if (*part < 0x20 || *part > 0x7e) return false;
  }
  if (field != 6 || strcmp(fields[0], "DSH_TRACE_V1") || strcmp(fields[1], run_id))
    return false;
  uint64_t sequence, first, second;
  if (!decimal(fields[2], &sequence) || sequence != state->next_sequence ||
      !decimal(fields[4], &first) || first > INT_MAX ||
      !decimal(fields[5], &second) || second > INT_MAX) return false;
  ++state->next_sequence;
  const char *event = fields[3];
  if (!strcmp(event, "ROOT")) {
    if (state->root_seen || first == 0 || second != 0 || sequence != 1 ||
        !live_add(state, (pid_t)first)) return false;
    state->root_seen = true;
  } else if (!strcmp(event, "ARM")) {
    if (!state->root_seen || state->arm_seen || first != (uint64_t)state->live[0] ||
        second == 0 || sequence != 2) return false;
    state->arm_seen = true;
  } else if (!strcmp(event, "FORK") || !strcmp(event, "VFORK") || !strcmp(event, "CLONE")) {
    if (!state->arm_seen || state->drain_seen || !live_contains(state, (pid_t)first) ||
        !live_add(state, (pid_t)second)) return false;
  } else if (!strcmp(event, "REAP")) {
    if (!state->arm_seen || state->drain_seen || first == 0 || second > 0xffff ||
        !live_remove(state, (pid_t)first)) return false;
  } else if (!strcmp(event, "DRAIN")) {
    if (!state->arm_seen || state->drain_seen || first != 0 || second != 0 ||
        state->live_count != 0) return false;
    state->drain_seen = true;
  } else return false;
  return true;
}

static bool forward_trace_line(struct trace_state *state) {
  state->line[state->line_length] = '\n';
  size_t count = state->line_length + 1;
  size_t written = 0;
  while (written < count) {
    ssize_t n = write(STDOUT_FILENO, state->line + written, count - written);
    if (n > 0) written += (size_t)n;
    else if (n < 0 && errno == EINTR) continue;
    else return false; // EAGAIN or lost caller fails closed; never block the event drain.
  }
  state->line_length = 0;
  return true;
}

static bool consume_events(struct trace_state *state, const char *run_id,
                           const unsigned char *bytes, size_t count) {
  if (count > MAX_TRACE_BYTES - state->total_bytes || state->drain_seen) return false;
  state->total_bytes += count;
  for (size_t i = 0; i < count; ++i) {
    if (bytes[i] == '\n') {
      if (state->line_length == 0 || !parse_event(state, run_id) ||
          !forward_trace_line(state)) return false;
    } else if (state->line_length >= MAX_TRACE_LINE - 1) return false;
    else state->line[state->line_length++] = (char)bytes[i];
  }
  return true;
}

static int direct_children(int32_t *children, size_t capacity) {
  char path[96];
  int path_length = snprintf(path, sizeof(path), "/proc/self/task/%ld/children",
                             (long)getpid());
  if (path_length < 0 || path_length >= (int)sizeof(path)) return -1;
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) return -1;
  char bytes[CHILDREN_SNAPSHOT_BYTES + 1];
  size_t length = 0;
  while (length < sizeof(bytes)) {
    ssize_t read_count = read(fd, bytes + length, sizeof(bytes) - length);
    if (read_count > 0) length += (size_t)read_count;
    else if (read_count == 0) break;
    else if (errno != EINTR) { close(fd); return -1; }
  }
  close(fd);
  if (length == sizeof(bytes)) return -1; // Never interpret a truncated PID list.
  return dsh_parse_direct_children(bytes, length, children, capacity);
}

static bool kill_direct_children(void) {
  // Listed children cannot have their numeric PIDs reused before we reap them.
  // As subreaper we repeatedly snapshot after intermediate parents exit, so
  // children that escaped the tracer's process group become visible here.
  int32_t children[MAX_CHILDREN_SNAPSHOT];
  int count = direct_children(children, MAX_CHILDREN_SNAPSHOT);
  if (count < 0) return false;
  for (int i = 0; i < count; ++i) {
    if (kill(children[i], SIGKILL) != 0 && errno != ESRCH) return false;
  }
  return true;
}

static bool kill_observed(pid_t tracer, bool tracer_reaped) {
  // A reaped tracer PID may be reused. Only its live group can be addressed;
  // trace event PIDs are historical evidence, never safe signal targets.
  if (tracer > 0 && !tracer_reaped) {
    (void)kill(-tracer, SIGKILL);
    (void)kill(tracer, SIGKILL); // Before the child calls setpgid.
  }
  return kill_direct_children();
}

static void child_exec(pid_t owner, int launch_fd, int loader_fd,
                       const char *rootfs, const char *run_id,
                       int trace_write, int output_write, int exec_write) {
  if (setpgid(0, 0) != 0 || prctl(PR_SET_PDEATHSIG, SIGKILL) != 0 || getppid() != owner)
    _exit(126);
  struct sigaction normal = {0};
  normal.sa_handler = SIG_DFL;
  sigemptyset(&normal.sa_mask);
  sigset_t no_blocks;
  sigemptyset(&no_blocks);
  if (sigaction(SIGTERM, &normal, NULL) != 0 ||
      sigaction(SIGINT, &normal, NULL) != 0 ||
      sigaction(SIGPIPE, &normal, NULL) != 0 ||
      sigprocmask(SIG_SETMASK, &no_blocks, NULL) != 0) _exit(126);
  int null_fd = open("/dev/null", O_RDONLY | O_CLOEXEC);
  // Reserve each source above the destination range. Direct dup2 can otherwise
  // overwrite fd 3 (the launcher is commonly opened there) before using it.
  int safe_null = null_fd < 0 ? -1 : fcntl(null_fd, F_DUPFD_CLOEXEC, 16);
  int safe_output = fcntl(output_write, F_DUPFD_CLOEXEC, 16);
  int safe_trace = fcntl(trace_write, F_DUPFD_CLOEXEC, 16);
  int safe_launch = fcntl(launch_fd, F_DUPFD_CLOEXEC, 16);
  int safe_exec = fcntl(exec_write, F_DUPFD_CLOEXEC, 16);
  int safe_loader = fcntl(loader_fd, F_DUPFD_CLOEXEC, 16);
  if (safe_null < 0 || safe_output < 0 || safe_trace < 0 || safe_launch < 0 ||
      safe_exec < 0 || safe_loader < 0 || dup2(safe_null, 0) < 0 || dup2(safe_output, 1) < 0 ||
      dup2(safe_output, 2) < 0 || dup2(safe_trace, 3) < 0 ||
      dup2(safe_launch, 4) < 0 || dup2(safe_exec, 5) < 0 || dup2(safe_loader, 6) < 0 ||
      fcntl(3, F_SETFD, 0) != 0 || fcntl(4, F_SETFD, FD_CLOEXEC) != 0 ||
      fcntl(5, F_SETFD, FD_CLOEXEC) != 0 || fcntl(6, F_SETFD, 0) != 0) _exit(126);
#ifdef __NR_close_range
  if (syscall(__NR_close_range, 7U, UINT_MAX, 0U) != 0) _exit(126);
#else
  _exit(126); // Never inherit unknown App descriptors on unsupported kernels.
#endif
  char *const args[] = {"proot", "-r", (char *)rootfs, "-w", "/", "/bin/true", NULL};
  char *env[] = {"PATH=/usr/bin:/bin", "HOME=/", "LANG=C", NULL,
                 NULL, NULL, NULL};
  char loader_env[] = "PROOT_LOADER=/proc/self/fd/6";
  char run_env[36 + 19];
  char event_env[] = "DSH_TRACEE_EVENT_FD=3";
  if (snprintf(run_env, sizeof(run_env), "DSH_TRACEE_RUN_ID=%s", run_id)
          >= (int)sizeof(run_env)) _exit(126);
  env[3] = loader_env;
  env[4] = run_env;
  env[5] = event_env;
  execve("/proc/self/fd/4", args, env);
  int code = errno;
  (void)write(5, &code, sizeof(code));
  _exit(127);
}

int main(int argc, char **argv) {
  if (argc != 4 || !run_id_ok(argv[2]) || !rootfs_ok(argv[3])) return 64;
  uint64_t expected_parent;
  if (!decimal(argv[1], &expected_parent) || expected_parent < 2 ||
      expected_parent > INT_MAX || getppid() != (pid_t)expected_parent) return 64;
  int launch_fd = -1, loader_fd = -1;
  if (!installed_candidate(&launch_fd, &loader_fd))
    return 65; // Ordinary APKs have no candidate and cannot start a guest.
  if (setsid() < 0 || prctl(PR_SET_PDEATHSIG, SIGTERM) != 0 ||
      prctl(PR_SET_CHILD_SUBREAPER, 1) != 0 || getppid() != (pid_t)expected_parent) {
    close(launch_fd); close(loader_fd);
    return 66;
  }
  struct sigaction action = {0};
  action.sa_handler = request_stop;
  sigemptyset(&action.sa_mask);
  struct sigaction ignore = {0};
  ignore.sa_handler = SIG_IGN;
  sigemptyset(&ignore.sa_mask);
  if (sigaction(SIGTERM, &action, NULL) || sigaction(SIGINT, &action, NULL) ||
      sigaction(SIGPIPE, &ignore, NULL)) { close(launch_fd); close(loader_fd); return 66; }
  int32_t startup_children[1];
  if (direct_children(startup_children, 1) != 0) {
    close(launch_fd); close(loader_fd); return 66;
  }
  int trace_pipe[2], output_pipe[2], exec_pipe[2];
  if (pipe2(trace_pipe, O_CLOEXEC) ||
      pipe2(output_pipe, O_CLOEXEC) ||
      pipe2(exec_pipe, O_CLOEXEC) ||
      !nonblocking_reader(trace_pipe[0]) ||
      !nonblocking_reader(output_pipe[0]) ||
      !nonblocking_reader(exec_pipe[0])) { close(launch_fd); close(loader_fd); return 67; }
  pid_t supervisor_pid = getpid();
  pid_t tracer = fork();
  if (tracer < 0) { close(launch_fd); close(loader_fd); return 67; }
  if (tracer == 0) {
    child_exec(supervisor_pid, launch_fd, loader_fd, argv[3], argv[2],
               trace_pipe[1], output_pipe[1], exec_pipe[1]);
  }
  close(launch_fd); close(loader_fd);
  close(trace_pipe[1]); close(output_pipe[1]); close(exec_pipe[1]);
  int flags = fcntl(STDOUT_FILENO, F_GETFL, 0);
  if (flags < 0 || fcntl(STDOUT_FILENO, F_SETFL, flags | O_NONBLOCK) != 0)
    stop_requested = 1;
  struct trace_state trace = {.next_sequence = 1};
  int64_t start = now_ms();
  int64_t cancel_at = -1;
  bool trace_eof = false, output_eof = false, exec_eof = false;
  bool tracer_reaped = false, bad = start < 0;
  int tracer_status = 0;
  size_t output_bytes = 0;
  while (true) {
    int64_t now = now_ms();
    if (now < 0) {
      bad = true;
      now = INT64_MAX / 2;
      if (cancel_at < 0) cancel_at = now - CANCEL_GRACE_MS;
    }
    if (getppid() != (pid_t)expected_parent || now - start >= DEADLINE_MS)
      stop_requested = 1;
    if (stop_requested || bad) {
      if (cancel_at < 0) cancel_at = now;
      if (!kill_observed(tracer, tracer_reaped)) bad = true;
    }
    if (!tracer_reaped) {
      pid_t reaped = waitpid(tracer, &tracer_status, WNOHANG);
      if (reaped == tracer) tracer_reaped = true;
      else if (reaped < 0 && errno != EINTR) bad = true;
    }
    struct pollfd channels[3] = {
        {trace_eof ? -1 : trace_pipe[0], POLLIN | POLLHUP, 0},
        {output_eof ? -1 : output_pipe[0], POLLIN | POLLHUP, 0},
        {exec_eof ? -1 : exec_pipe[0], POLLIN | POLLHUP, 0}};
    if (poll(channels, 3, 50) < 0 && errno != EINTR) bad = true;
    unsigned char buffer[4096];
    if (!trace_eof) {
      ssize_t n = read(trace_pipe[0], buffer, sizeof(buffer));
      if (n > 0 && !consume_events(&trace, argv[2], buffer, (size_t)n)) bad = true;
      else if (n == 0) trace_eof = true;
      else if (n < 0 && errno != EAGAIN && errno != EINTR) bad = true;
    }
    if (!output_eof) {
      ssize_t n = read(output_pipe[0], buffer, sizeof(buffer));
      if (n > 0) {
        if ((size_t)n > MAX_GUEST_OUTPUT - output_bytes) bad = true;
        else output_bytes += (size_t)n;
      } else if (n == 0) output_eof = true;
      else if (errno != EAGAIN && errno != EINTR) bad = true;
    }
    if (!exec_eof) {
      int exec_errno = 0;
      ssize_t n = read(exec_pipe[0], &exec_errno, sizeof(exec_errno));
      if (n > 0) bad = true; // execve failed; never synthesize a trace DRAIN.
      else if (n == 0) exec_eof = true;
      else if (errno != EAGAIN && errno != EINTR) bad = true;
    }
    if (trace_eof && output_eof && exec_eof && tracer_reaped) break;
    if (cancel_at >= 0 && now - cancel_at >= CANCEL_GRACE_MS) break;
  }
  close(trace_pipe[0]); close(output_pipe[0]); close(exec_pipe[0]);
  // EOF is insufficient: a tracee can close all pipes and keep running.
  // On both success and failure paths, retire every adopted child before
  // returning to the App-side broker. Unexpected adoption makes the run fail.
  bool all_reaped = false, unexpected_adopted = false;
  int64_t retirement_start = now_ms();
  if (retirement_start < 0) bad = true;
  for (int attempt = 0; attempt < CANCEL_GRACE_MS / 20 + 1; ++attempt) {
    if (!kill_direct_children()) bad = true;
    for (;;) {
      int adopted_status = 0;
      pid_t adopted = waitpid(-1, &adopted_status, WNOHANG);
      if (adopted > 0) {
        if (adopted == tracer) { tracer_reaped = true; tracer_status = adopted_status; }
        else unexpected_adopted = true;
        continue;
      }
      if (adopted < 0 && errno == EINTR) continue;
      if (adopted < 0 && errno == ECHILD) all_reaped = true;
      else if (adopted < 0) bad = true;
      break;
    }
    int64_t retirement_now = now_ms();
    if (retirement_now < 0) bad = true;
    if (all_reaped || (retirement_start >= 0 && retirement_now >= 0 &&
                       retirement_now - retirement_start >= CANCEL_GRACE_MS)) break;
    struct timespec pause = {.tv_sec = 0, .tv_nsec = 20000000};
    (void)nanosleep(&pause, NULL);
  }
  if (!all_reaped) bad = true;
  bool success = !bad && !stop_requested && tracer_reaped && WIFEXITED(tracer_status) &&
      WEXITSTATUS(tracer_status) == 0 && trace_eof && output_eof && exec_eof &&
      trace.root_seen && trace.arm_seen && trace.drain_seen && trace.line_length == 0 &&
      trace.live_count == 0 && all_reaped && !unexpected_adopted;
  if (!success && !all_reaped) (void)kill_observed(tracer, tracer_reaped);
  return success ? 0 : 70;
}
