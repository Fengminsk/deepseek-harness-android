# Read-only Linux image descriptor boundary

This is an **internal data transport**, not an executable Linux container. The
model, Node runtime, Flutter UI and isolated Linux command service cannot call
it. `LinuxImageLeaseOwner` recognizes only the reviewed Alpine 3.24.3 ARM64
archive identity from `linux-userland-source-lock.mjs`, under the App-owned
`noBackupFilesDir/linux-userland/versions/<sha256>/image.tar.gz` tree. Neither
the guest nor a Binder request can select a path, URL, release, digest or file
name. The App must first install and independently verify the candidate release;
there is no in-App installer yet.

The trusted App may issue one `runId`/opaque-token offer, lasting at most 60
seconds. The archive is checked at issue and again at claim. Claim consumes the
token before trying to open the file, including when verification fails. The
Android adapter opens with `O_RDONLY | O_NOFOLLOW | O_CLOEXEC` and copies the
opened descriptor into an anonymous `SharedMemory` snapshot (at most 8 MiB,
two live snapshots). It checks source identity, size and SHA-256 while copying,
unmaps its only writable mapping, calls `setProtect(PROT_READ)`, then hashes the
protected snapshot. Any failure closes the snapshot. Source mutation after
claim cannot change the detached bytes. The recipient must be bound to the
exact admitted isolated UID before the owner parcels this snapshot; Binder
binding and a guest receiver do not yet exist.

**Revocation limit:** once a `SharedMemory` FD is transferred, closing the App's
copy or revoking its token does not revoke the receiver's copy. The sender must
close its copy after transfer and retire the guest on cancellation. The archive
is data only. It cannot be `execve()`'d from App-writable
storage, and PRoot does not add a security boundary. The actual guest process
is still subject to the isolated UID, file/network broker, deadline, child
cleanup and Android device acceptance. Until those are integrated and tested,
the generalized Linux/PRoot entry point remains closed.

Host verification: compile `LinuxImageLeaseOwner.java` and
`LinuxImageLeaseOwnerTest.java` with `javac`, then run the test main class. The
test covers forged run IDs/tokens, expiry, revocation, replay and same-size
archive replacement. `linux-image-descriptor-broker.test.mjs` checks that the
Android pin still matches the separately reviewed source lock. Device-only
`LinuxImageSnapshotInstrumentation` changes the source after claim, verifies
the snapshot is unchanged, and checks that a new writable mapping is rejected.
Compilation alone cannot prove OS protection or guest transfer. Guest
integration stays closed until device acceptance.

References: [Android isolated service permission boundary](https://developer.android.com/guide/topics/manifest/service-element#isolatedProcess),
[SharedMemory mapping and protection](https://developer.android.com/reference/android/os/SharedMemory),
[Android app-home executable restriction](https://developer.android.com/about/versions/10/behavior-changes-10#execute-permission).
