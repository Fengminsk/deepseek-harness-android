/* PRoot candidate modification, GPL-2.0-or-later. See upstream COPYING. */
#ifndef DSH_TRACE_EVENTS_H
#define DSH_TRACE_EVENTS_H

#include <sys/types.h>

/* Every operation fails the candidate process if the ordered pipe is lost. */
void dsh_events_init(void);
void dsh_events_close_in_child(void);
void dsh_events_root(pid_t pid);
void dsh_events_armed(pid_t pid, unsigned long ptrace_options);
void dsh_events_spawn(const char *kind, pid_t parent, pid_t child);
void dsh_events_reaped(pid_t pid, int wait_status);
void dsh_events_drained(int exit_status);

#endif
