# Isolated guest rootfs staging

`LinuxGuestRootfsStager.stagePinned` is a data-only continuation of the existing
App-UID image lease. Its input is the read-only `SharedMemory` mapping received
by an isolated UID, plus a **trusted directory created and owned by that UID**.
It does not accept a model-supplied path and does not return a filesystem path
to the App process. The App still owns the pinned archive and only grants one
bounded, expiring immutable snapshot. The source lock remains Alpine 3.24.3,
`arm64-v8a`, 4,029,999 compressed bytes, SHA-256
`4d3f80afaebd447c5591a63a73bde380a149fe8b2d85488cafabb2ff97551f50`.

Before writing, the stager copies the read-only mapping, verifies the full
compressed digest, decompresses with a 32 MiB ceiling, and validates every tar
header and the complete member graph. It limits member count, path length and
file size. It rejects traversal, duplicate paths, symlink ancestors, hard links,
device nodes, FIFO, PAX/GNU overrides, bad checksums and trailing non-zero data.
The locked Alpine archive contains many guest-absolute symlinks (for example
`usr/bin/yes -> /bin/busybox`); these are rewritten to relative links inside
the staged tree (`../../bin/busybox`). Relative `..` is allowed only when its
normalized target remains inside the rootfs. Directories and regular files are
created before symlinks, and every file is created exclusively without following
links.

The per-run `.staging-<UUID>` directory is published as `<UUID>` by a same-parent
atomic rename only after complete materialization. Publication removes owner
write permission from ordinary files and directories; the isolated UID remains
the real security boundary. `Staged.close()` restores directory write permission
and deletes only that run's tree without following links. Failed or cancelled
staging removes only the stage created by the current call. A pre-existing stage
or published run is retained and fails closed.

This component is not yet wired into `IsolatedGuestService`. Device verification
is required to establish an isolated UID-owned writable staging directory and
the kernel's read-only `SharedMemory` behavior. There is no ELF/PRoot launch or
executable payload grant here. The extracted files are deliberately non-executable.

Host check: compile `LinuxGuestRootfsStager.java` with its existing image classes
and `LinuxGuestRootfsStagerTest.java`, then run the test main class with
`.cache/android/linux-rootfs-prototype/alpine-minirootfs-3.24.3-aarch64.tar.gz`
as its optional argument. The test verifies the official source digest and 515
members as well as malicious tar fixtures, cancellation and nested-tree cleanup.
