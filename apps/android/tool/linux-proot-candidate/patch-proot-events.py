"""Apply the reviewed event-feed modification to one pinned PRoot extraction.

The upstream archive hash is checked by build.ps1 before extraction. These file
hashes and single-use anchors additionally reject unexpected source drift.
"""

from __future__ import annotations

import hashlib
import sys
from pathlib import Path


EXPECTED = {
    "cli/cli.c": "bba84fab122ae4734b4e6136af1e34055e1e9f9603db679c594bc748395dfd98",
    "tracee/event.c": "15e8c7800df724e004e731d468b28dffada2be78e2cef75f1f839817913ef807",
    "tracee/tracee.c": "71a5a59871922a0abbb57d57e4251f01b6eeeab7b2871ab6eb027b0c60136c53",
}


def replace_once(text: str, before: str, after: str, label: str) -> str:
    if text.count(before) != 1:
        raise ValueError(f"{label}: expected one unmodified upstream anchor")
    return text.replace(before, after)


def patch_cli(text: str) -> str:
    text = replace_once(text, '#include "build.h"',
                        '#include "build.h"\n#include "dsh-trace-events.h"', "cli include")
    text = replace_once(text,
        '\t/* Pre-create the first tracee (pid == 0).  */',
        '\tdsh_events_init();\n\n\t/* Pre-create the first tracee (pid == 0).  */',
        "cli initialization")
    return text


def patch_event(text: str) -> str:
    text = replace_once(text, '#include "tracee/event.h"',
                        '#include "tracee/event.h"\n#include "dsh-trace-events.h"',
                        "event include")
    text = replace_once(text, '\tcase 0: /* child */',
                        '\tcase 0: /* child */\n\t\tdsh_events_close_in_child();',
                        "tracee child pipe isolation")
    text = replace_once(text, '\t\ttracee->pid = pid;\n\t\treturn 0;',
                        '\t\ttracee->pid = pid;\n\t\tdsh_events_root(pid);\n\t\treturn 0;',
                        "root registration")
    text = replace_once(text,
        '\t\t\tif (errno != ECHILD) {\n\t\t\t\tnote(NULL, ERROR, SYSTEM, "waitpid()");\n\t\t\t\treturn EXIT_FAILURE;\n\t\t\t}\n\t\t\tbreak;',
        '\t\t\tif (errno != ECHILD) {\n\t\t\t\tnote(NULL, ERROR, SYSTEM, "waitpid()");\n\t\t\t\treturn EXIT_FAILURE;\n\t\t\t}\n\t\t\tdsh_events_drained(last_exit_status);\n\t\t\tbreak;',
        "complete waitpid drain")
    text = replace_once(text, '\t\ttracee->running = false;\n\n\t\tstatus = notify_extensions',
                        '\t\ttracee->running = false;\n\t\tif (WIFEXITED(tracee_status) || WIFSIGNALED(tracee_status))\n'
                        '\t\t\tdsh_events_reaped(pid, tracee_status);\n\n\t\tstatus = notify_extensions',
                        "final waitpid observation")
    text = replace_once(text,
        '\t\t\t\tseccomp_ptrace_event_supported =\n'
        '\t\t\t\t\tkernel_supports_ptrace_event_seccomp();\n\t\t\t}\n\t\t}',
        '\t\t\t\tseccomp_ptrace_event_supported =\n'
        '\t\t\t\t\tkernel_supports_ptrace_event_seccomp();\n\t\t\t}\n'
        '\t\t\tdsh_events_armed(tracee->pid, default_ptrace_options);\n\t\t}',
        "confirmed ptrace options")
    return text


def patch_tracee(text: str) -> str:
    text = replace_once(text, '#include "tracee/tracee.h"',
                        '#include "tracee/tracee.h"\n#include "dsh-trace-events.h"',
                        "tracee include")
    text = replace_once(text, '\tinherit_extensions(child, parent, clone_flags);',
        '\tinherit_extensions(child, parent, clone_flags);\n'
        '\t/* Emit after a child is fully registered, before it can restart. */\n'
        '\tdsh_events_spawn((clone_flags & CLONE_VFORK) != 0 ? "VFORK" :\n'
        '\t\tptrace_options == PTRACE_O_TRACECLONE ? "CLONE" : "FORK",\n'
        '\t\tparent->pid, child->pid);',
        "registered child")
    return text


PATCHERS = {"cli/cli.c": patch_cli, "tracee/event.c": patch_event,
            "tracee/tracee.c": patch_tracee}


def main(source: Path) -> None:
    source = source.resolve(strict=True)
    if source.name != "proot-5.1.107.96" or source.parent.name != "verified-extracted" or not (
        source.parent / ".dsh-proot-candidate-staging").is_file():
        raise ValueError("Refusing an unowned or unexpected PRoot source tree")
    outputs: dict[Path, bytes] = {}
    for relative, expected in EXPECTED.items():
        path = source / "src" / relative
        original = path.read_bytes()
        if hashlib.sha256(original).hexdigest() != expected:
            raise ValueError(f"{relative}: upstream source digest changed")
        rewritten = PATCHERS[relative](original.decode("utf-8").replace("\r\n", "\n"))
        outputs[path] = rewritten.encode("utf-8")
    for path, data in outputs.items():
        path.write_bytes(data)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch-proot-events.py VERIFIED_PROOT_SOURCE")
    main(Path(sys.argv[1]))
