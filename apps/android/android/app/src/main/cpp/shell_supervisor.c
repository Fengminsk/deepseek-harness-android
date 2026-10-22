#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

// Run as a separate session leader. The Node parent owns this helper; the
// helper owns the entire ordinary Shell process group until it is empty.
static volatile sig_atomic_t group_leader = 0;

static void parent_gone(int signal_number) {
  (void)signal_number;
  if (group_leader > 0) kill(-group_leader, SIGKILL);
  _exit(143);
}

static int status_code(int status) {
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
  return 77;
}

int main(int argc, char **argv) {
  if (argc != 5 || strcmp(argv[2], "/system/bin/sh") != 0
      || strcmp(argv[3], "-c") != 0 || !argv[4][0]) {
    fputs("Android Shell supervisor: invalid invocation\n", stderr);
    return 64;
  }
  char *end = NULL;
  errno = 0;
  const long expected_parent = strtol(argv[1], &end, 10);
  if (errno || !end || *end || expected_parent < 2 || expected_parent > 2147483647L
      || getpgrp() != getpid() || getsid(0) != getpid()) {
    fputs("Android Shell supervisor: invalid process ownership\n", stderr);
    return 65;
  }
  group_leader = (sig_atomic_t)getpid();
  struct sigaction parent_action = {0};
  parent_action.sa_handler = parent_gone;
  sigemptyset(&parent_action.sa_mask);
  struct sigaction pipe_action = {0};
  pipe_action.sa_handler = SIG_IGN;
  sigemptyset(&pipe_action.sa_mask);
  if (sigaction(SIGTERM, &parent_action, NULL) != 0
      || sigaction(SIGPIPE, &pipe_action, NULL) != 0
      || prctl(PR_SET_PDEATHSIG, SIGTERM) != 0
      || prctl(PR_SET_CHILD_SUBREAPER, 1) != 0) {
    fputs("Android Shell supervisor: parent watch unavailable\n", stderr);
    return 70;
  }
  if (getppid() != (pid_t)expected_parent) parent_gone(SIGTERM);
  int start_gate[2];
  if (pipe2(start_gate, O_CLOEXEC) != 0) {
    fputs("Android Shell supervisor: startup gate unavailable\n", stderr);
    return 71;
  }
  const pid_t shell = fork();
  if (shell < 0) {
    close(start_gate[0]); close(start_gate[1]);
    fputs("Android Shell supervisor: shell fork failed\n", stderr);
    return 71;
  }
  if (shell == 0) {
    // The shell joins this helper's detached group. If the helper itself is
    // killed, the direct shell also receives a parent-death signal.
    struct sigaction default_action = {0};
    default_action.sa_handler = SIG_DFL;
    sigaction(SIGTERM, &default_action, NULL);
    sigaction(SIGPIPE, &default_action, NULL);
    if (prctl(PR_SET_PDEATHSIG, SIGKILL) != 0 || getppid() != (pid_t)group_leader) _exit(72);
    close(start_gate[1]);
    close(3);
    char start = 0;
    if (read(start_gate[0], &start, 1) != 1 || start != 'G') _exit(72);
    close(start_gate[0]);
    char *const command[] = {argv[2], argv[3], argv[4], NULL};
    execv(command[0], command);
    _exit(127);
  }
  // fd 3 is a startup acknowledgment, not a control channel. It never reaches
  // a model-supplied command and cannot hold the parent alive accidentally.
  close(start_gate[0]);
  if (write(3, "S\n", 2) != 2) parent_gone(SIGTERM);
  close(3);
  if (write(start_gate[1], "G", 1) != 1) parent_gone(SIGTERM);
  close(start_gate[1]);
  int shell_status = 0;
  bool shell_reaped = false;
  for (;;) {
    if (getppid() != (pid_t)expected_parent) parent_gone(SIGTERM);
    if (!shell_reaped) {
      const pid_t result = waitpid(shell, &shell_status, WNOHANG);
      if (result == shell) shell_reaped = true;
      else if (result < 0 && errno != EINTR) parent_gone(SIGTERM);
    }
    if (shell_reaped) {
      // Subreaper adoption is the kernel's ownership record even when a
      // background child closed all output or /proc hides other app UIDs.
      // Reaping to ECHILD avoids racing a process-table enumeration against
      // a descendant that is forking while the old parent exits.
      for (;;) {
        int adopted_status = 0;
        const pid_t adopted = waitpid(-1, &adopted_status, WNOHANG);
        if (adopted > 0) continue;
        if (adopted == 0) break;
        if (errno == ECHILD) return status_code(shell_status);
        if (errno != EINTR) parent_gone(SIGTERM);
      }
    }
    usleep(100000);
  }
}
