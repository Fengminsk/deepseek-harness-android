package com.minnnng.dsh_android;

import java.io.IOException;
import java.util.List;

/** Bounded, fail-closed quiescence before a Node-free maintenance generation can write. */
public final class RecoveryProcesses {
    public static final class Identity {
        public final int pid, uid;
        public final long start;
        public final char state;
        public final String executable;
        public Identity(int pid, int uid, long start, char state, String executable) {
            this.pid = pid; this.uid = uid; this.start = start;
            this.state = state; this.executable = executable;
        }
        public boolean same(Identity other) {
            return other != null && pid == other.pid && uid == other.uid && start == other.start
                && executable.equals(other.executable);
        }
        public boolean active() { return state != 'Z' && state != 'X' && state != 'x'; }
    }
    public interface Host {
        /** Must enumerate every visible numeric /proc entry; unknown ownership fails the scan. */
        List<Identity> snapshot() throws IOException;
        /** Rechecks identity immediately before kill; PID reuse or unknown ownership must fail. */
        void terminate(Identity expected) throws IOException;
        long elapsedMillis();
        void pause(long millis) throws IOException;
    }
    public static void quiesce(Host host, int uid, Identity main, Identity service, String packageName)
            throws IOException {
        if (main == null || service == null || main.pid == service.pid || main.uid != uid || service.uid != uid
                || !main.active() || !service.active() || !main.executable.equals(packageName)
                || !service.executable.equals(packageName + ":agent"))
            throw new IOException("Cannot verify protected app processes");
        long deadline = host.elapsedMillis() + 3000;
        int emptyScans = 0;
        while (host.elapsedMillis() < deadline) {
            boolean sawMain = false, sawService = false, remaining = false;
            List<Identity> processes = host.snapshot();
            for (Identity process : processes) {
                if (process.pid == main.pid) {
                    if (!main.same(process) || !process.active()) throw new IOException("Main process identity changed");
                    sawMain = true;
                } else if (process.pid == service.pid) {
                    if (!service.same(process) || !process.active()) throw new IOException("Maintenance process identity changed");
                    sawService = true;
                } else if (process.uid == uid && process.active()) {
                    // A new Android main/service process must never be mistaken for a shell.
                    if (process.executable.equals(packageName) || process.executable.equals(packageName + ":agent"))
                        throw new IOException("Unexpected app process identity");
                    remaining = true;
                    host.terminate(process);
                }
            }
            if (!sawMain || !sawService) throw new IOException("Protected app processes absent from scan");
            emptyScans = remaining ? 0 : emptyScans + 1;
            if (emptyScans == 2) return;
            host.pause(100);
        }
        throw new IOException("App processes did not become quiescent");
    }
    private RecoveryProcesses() {}
}
