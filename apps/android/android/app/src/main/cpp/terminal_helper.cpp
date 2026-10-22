#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pty.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

// This is an executable, not a JNI call. Forking before Node or the Android
// service starts threads keeps the fork-to-exec path independent of their locks.
namespace {
volatile sig_atomic_t stopping = 0;
void stop_handler(int) { stopping = 1; }

bool write_all(int fd, const char* data, size_t length) {
  while (length) {
    const ssize_t count = write(fd, data, length);
    if (count < 0 && errno == EINTR && !stopping) continue;
    if (count <= 0) return false;
    data += count;
    length -= static_cast<size_t>(count);
  }
  return true;
}

bool exact_number(const char* text, int minimum, int maximum, int* result) {
  if (!text || !*text) return false;
  char* end = nullptr;
  errno = 0;
  long value = strtol(text, &end, 10);
  if (errno || *end || value < minimum || value > maximum) return false;
  *result = static_cast<int>(value);
  return true;
}

void terminate_group(pid_t child, int* final_status = nullptr) {
  if (child <= 0) return;
  kill(-child, SIGTERM);
  int status = 0;
  // Keep the leader waitable while signalling the process group: reaping it
  // early frees its PID/PGID for reuse before the final descendant sweep.
  for (int attempt = 0; attempt < 10; ++attempt) {
    siginfo_t observed{};
    if (waitid(P_PID, static_cast<id_t>(child), &observed,
          WEXITED | WNOHANG | WNOWAIT) == 0 && observed.si_pid == child) break;
    usleep(100000);
  }
  // A shell may have left descendants in its process group after exiting.
  kill(-child, SIGKILL);
  while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
  if (final_status != nullptr) *final_status = status;
}
}

int main(int argc, char** argv) {
  // stdout carries raw PTY bytes; descriptor 3 carries framed input and resize
  // commands, descriptor 4 confirms each operation after the PTY accepts it.
  int cols = 0, rows = 0;
  if (argc != 5 || !exact_number(argv[2], 2, 500, &cols)
      || !exact_number(argv[3], 1, 200, &rows) || argv[1][0] != '/'
      || strcmp(argv[4], "/system/bin/sh") != 0) {
    fputs("Invalid terminal startup", stderr);
    return 64;
  }
  struct sigaction action{};
  action.sa_handler = stop_handler;
  sigemptyset(&action.sa_mask);
  sigaction(SIGTERM, &action, nullptr);
  sigaction(SIGINT, &action, nullptr);
  sigaction(SIGHUP, &action, nullptr);
  prctl(PR_SET_PDEATHSIG, SIGTERM);
  if (getppid() == 1) return 70;
  struct winsize size{};
  size.ws_col = static_cast<unsigned short>(cols);
  size.ws_row = static_cast<unsigned short>(rows);
  int startup_pipe[2];
  if (pipe2(startup_pipe, O_CLOEXEC) != 0) return 71;
  int master = -1;
  const pid_t child = forkpty(&master, nullptr, nullptr, &size);
  if (child < 0) { close(startup_pipe[0]); close(startup_pipe[1]); perror("forkpty"); return 71; }
  if (child == 0) {
    // forkpty made this process the controlling-terminal session leader.
    close(startup_pipe[0]);
    prctl(PR_SET_PDEATHSIG, SIGKILL);
    if (getppid() == 1) _exit(72);
    close(3); close(4);
    if (chdir(argv[1]) != 0) {
      const char failure = 73;
      write(startup_pipe[1], &failure, 1);
      _exit(73);
    }
    char* const args[] = { const_cast<char*>("/system/bin/sh"), const_cast<char*>("-i"), nullptr };
    execv(args[0], args);
    const char failure = 74;
    write(startup_pipe[1], &failure, 1);
    _exit(74);
  }
  close(startup_pipe[1]);
  struct pollfd readiness{ startup_pipe[0], POLLIN | POLLHUP, 0 };
  const int ready = poll(&readiness, 1, 3000);
  char startup_failure = 0;
  const ssize_t startup_bytes = ready > 0 ? read(startup_pipe[0], &startup_failure, 1) : -1;
  close(startup_pipe[0]);
  if (startup_bytes != 0) {
    terminate_group(child); close(master);
    return startup_bytes == 1 ? startup_failure : 75;
  }
  char startup[40];
  const int startup_length = snprintf(startup, sizeof(startup), "S%ld\n", static_cast<long>(child));
  if (startup_length <= 0 || !write_all(4, startup, static_cast<size_t>(startup_length))) {
    terminate_group(child); close(master); return 75;
  }
  bool control_open = true;
  unsigned char control[65541];
  size_t control_bytes = 0;
  char buffer[8192];
  int exit_status = 0;
  bool child_exited = false;
  while (!stopping) {
    struct pollfd descriptors[] = { { master, POLLIN, 0 },
                                    { 3, static_cast<short>(control_open ? POLLIN : 0), 0 } };
    const int polled = poll(descriptors, 2, 100);
    if (polled < 0 && errno == EINTR) continue;
    if (polled < 0) break;
    if (descriptors[0].revents & POLLIN) {
      const ssize_t count = read(master, buffer, sizeof(buffer));
      if (count > 0) {
        if (!write_all(1, buffer, static_cast<size_t>(count))) break;
      } else if (count == 0 || errno == EIO) break;
    }
    if (descriptors[0].revents & (POLLHUP | POLLERR)) break;
    if (descriptors[1].revents & POLLIN) {
      const ssize_t count = read(3, control + control_bytes, sizeof(control) - control_bytes);
      if (count > 0) control_bytes += static_cast<size_t>(count);
      else if (count == 0) control_open = false;
      while (control_bytes >= 5) {
        const unsigned char type = control[0];
        size_t frame_size = 5;
        if (type == 'W') {
          const uint32_t length = static_cast<uint32_t>(control[1]) << 24
              | static_cast<uint32_t>(control[2]) << 16
              | static_cast<uint32_t>(control[3]) << 8 | control[4];
          if (length > 65536) { stopping = 1; break; }
          frame_size += length;
        } else if (type != 'R') { stopping = 1; break; }
        if (control_bytes < frame_size) break;
        bool applied = false;
        if (type == 'W') {
          applied = write_all(master, reinterpret_cast<const char*>(control + 5), frame_size - 5);
        } else {
          struct winsize next{};
          next.ws_col = static_cast<unsigned short>(control[1] << 8 | control[2]);
          next.ws_row = static_cast<unsigned short>(control[3] << 8 | control[4]);
          applied = next.ws_col >= 2 && next.ws_col <= 500 && next.ws_row >= 1
              && next.ws_row <= 200 && ioctl(master, TIOCSWINSZ, &next) == 0;
          if (applied) kill(-child, SIGWINCH);
        }
        const char ack[] = { static_cast<char>(type), applied ? '0' : '1', '\n' };
        if (!write_all(4, ack, sizeof(ack))) { stopping = 1; break; }
        memmove(control, control + frame_size, control_bytes - frame_size);
        control_bytes -= frame_size;
        if (!applied) { stopping = 1; break; }
      }
    }
    if (descriptors[1].revents & (POLLHUP | POLLERR)) control_open = false;
    siginfo_t observed{};
    if (waitid(P_PID, static_cast<id_t>(child), &observed, WEXITED | WNOHANG | WNOWAIT) == 0
        && observed.si_pid == child) child_exited = true;
    if (child_exited && !(descriptors[0].revents & POLLIN)) break;
  }
  close(master);
  terminate_group(child, &exit_status);
  if (!child_exited) return stopping ? 143 : 76;
  if (WIFEXITED(exit_status)) return WEXITSTATUS(exit_status);
  return WIFSIGNALED(exit_status) ? 128 + WTERMSIG(exit_status) : 77;
}
