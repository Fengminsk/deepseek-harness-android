/* PRoot candidate modification, GPL-2.0-or-later. See upstream COPYING. */
#include "dsh-trace-events.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* The app must create the pipe and never interpret candidate stdout as evidence. */
static int event_fd = -1;
static char run_id[37];
static unsigned long long next_sequence = 1;

static void fail(void)
{
	/* PRoot's event loop registers kill_all_tracees with atexit. There is no
	 * success marker on this path, including if that handler cannot run. */
	exit(EXIT_FAILURE);
}

static int valid_run_id(const char *value)
{
	size_t i;
	if (value == NULL || strlen(value) != 36)
		return 0;
	for (i = 0; i < 36; i++) {
		if (i == 8 || i == 13 || i == 18 || i == 23) {
			if (value[i] != '-') return 0;
		} else if (!((value[i] >= '0' && value[i] <= '9') ||
			     (value[i] >= 'a' && value[i] <= 'f'))) return 0;
	}
	return 1;
}

void dsh_events_init(void)
{
	const char *fd_text = getenv("DSH_TRACEE_EVENT_FD");
	const char *id_text = getenv("DSH_TRACEE_RUN_ID");
	char *end = NULL;
	long fd;
	int flags;
	struct stat metadata;
	if (fd_text == NULL || !valid_run_id(id_text)) fail();
	errno = 0;
	fd = strtol(fd_text, &end, 10);
	if (errno != 0 || end == fd_text || *end != '\0' || fd < 3 || fd > INT_MAX)
		fail();
	flags = fcntl((int) fd, F_GETFL);
	if (flags < 0 || (flags & O_ACCMODE) == O_RDONLY ||
	    fstat((int) fd, &metadata) != 0 || !S_ISFIFO(metadata.st_mode)) fail();
	if (fcntl((int) fd, F_SETFD, FD_CLOEXEC) != 0) fail();
	event_fd = (int) fd;
	memcpy(run_id, id_text, sizeof(run_id));
	/* These are host wire values, not guest environment variables. */
	if (unsetenv("DSH_TRACEE_EVENT_FD") != 0 ||
	    unsetenv("DSH_TRACEE_RUN_ID") != 0) fail();
}

void dsh_events_close_in_child(void)
{
	if (event_fd >= 0) close(event_fd);
}

static void emit(const char *kind, long first, long second)
{
	char frame[160];
	int size;
	ssize_t written;
	if (event_fd < 0 || next_sequence == ULLONG_MAX) fail();
	size = snprintf(frame, sizeof(frame),
		"DSH_TRACE_V1\t%s\t%llu\t%s\t%ld\t%ld\n",
		run_id, next_sequence, kind, first, second);
	if (size <= 0 || (size_t) size >= sizeof(frame)) fail();
	do { written = write(event_fd, frame, (size_t) size); }
	while (written < 0 && errno == EINTR);
	/* One bounded pipe write is atomic. A short write or broken reader must
	 * never produce a success-looking stream. */
	if (written != size) fail();
	next_sequence++;
}

void dsh_events_root(pid_t pid) { emit("ROOT", pid, 0); }
void dsh_events_armed(pid_t pid, unsigned long options)
{
	emit("ARM", pid, (long) options);
}
void dsh_events_spawn(const char *kind, pid_t parent, pid_t child)
{
	if (strcmp(kind, "FORK") != 0 && strcmp(kind, "VFORK") != 0 &&
	    strcmp(kind, "CLONE") != 0) fail();
	emit(kind, parent, child);
}
void dsh_events_reaped(pid_t pid, int wait_status)
{
	emit("REAP", pid, wait_status);
}
void dsh_events_drained(int exit_status)
{
	emit("DRAIN", exit_status, 0);
}
