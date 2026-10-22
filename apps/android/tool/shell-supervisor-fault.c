#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

// Build for an isolated Android emulator. This executable is never packaged
// in the app; it supplies a real parent that a second adb shell can SIGKILL.
int main(int argc, char **argv) {
  if (argc != 3 || (strcmp(argv[2], "hold") != 0 && strcmp(argv[2], "ack-fail") != 0
      && strcmp(argv[2], "quick") != 0)) return 64;
  const char *pid_file = "/data/local/tmp/dsh-shell-fault-child.pid";
  const char *sentinel = "/data/local/tmp/dsh-shell-fault-unexpected.txt";
  unlink(pid_file);
  unlink(sentinel);
  char command[512];
  if (strcmp(argv[2], "hold") == 0) {
    snprintf(command, sizeof(command),
        "/system/bin/sh -c 'echo $$ > %s; exec /system/bin/sleep 60' "
        "</dev/null >/dev/null 2>&1 & exit 0", pid_file);
  } else if (strcmp(argv[2], "ack-fail") == 0) {
    snprintf(command, sizeof(command), "echo unexpected > %s", sentinel);
  } else {
    snprintf(command, sizeof(command), "printf quick");
  }
  int acknowledgement[2];
  if (pipe2(acknowledgement, O_CLOEXEC) != 0) return 70;
  const pid_t child = fork();
  if (child < 0) return 71;
  if (child == 0) {
    close(acknowledgement[0]);
    if (setsid() < 0 || dup2(acknowledgement[1], 3) != 3) _exit(72);
    close(acknowledgement[1]);
    char parent[24];
    snprintf(parent, sizeof(parent), "%ld", (long)getppid());
    char *const arguments[] = {argv[1], parent, "/system/bin/sh", "-c", command, NULL};
    execv(argv[1], arguments);
    _exit(73);
  }
  close(acknowledgement[1]);
  if (strcmp(argv[2], "ack-fail") == 0) {
    close(acknowledgement[0]);
    int status = 0;
    if (waitpid(child, &status, 0) != child) return 74;
    printf("ACK_FAIL parent=%ld helper=%ld sentinel=%d\n", (long)getpid(),
        (long)child, access(sentinel, F_OK) == 0);
    return access(sentinel, F_OK) == 0 ? 75 : 0;
  }
  char message[2];
  if (read(acknowledgement[0], message, sizeof(message)) != 2
      || message[0] != 'S' || message[1] != '\n') return 76;
  close(acknowledgement[0]);
  if (strcmp(argv[2], "quick") == 0) {
    int status = 0;
    if (waitpid(child, &status, 0) != child || !WIFEXITED(status) || WEXITSTATUS(status) != 0) return 78;
    puts("QUICK_EXIT=0");
    return 0;
  }
  FILE *file = NULL;
  for (int i = 0; i < 30; ++i) {
    file = fopen(pid_file, "r");
    if (file) break;
    usleep(100000);
  }
  long descendant = 0;
  if (!file || fscanf(file, "%ld", &descendant) != 1 || descendant < 2) return 77;
  fclose(file);
  printf("READY parent=%ld helper=%ld descendant=%ld\n", (long)getpid(),
      (long)child, descendant);
  fflush(stdout);
  for (;;) pause();
}
