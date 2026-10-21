package com.minnnng.dsh_android;

import java.io.IOException;
import java.util.*;

public final class RecoveryProcessesTest {
    private static final int UID = 10001;
    private static final String PACKAGE = "com.minnnng.dsh_android";
    private static final RecoveryProcesses.Identity MAIN = identity(10, UID, 100, 'S', PACKAGE);
    private static final RecoveryProcesses.Identity SERVICE = identity(20, UID, 200, 'S', PACKAGE + ":agent");
    private static int checks;
    private static RecoveryProcesses.Identity identity(int pid, int uid, long start, char state, String command) {
        return new RecoveryProcesses.Identity(pid, uid, start, state, command);
    }
    private static void check(boolean value, String message) {
        checks++; if (!value) throw new AssertionError(message);
    }
    private static final class Host implements RecoveryProcesses.Host {
        long time;
        int scans;
        boolean unreadable, unkillable, reused;
        final List<RecoveryProcesses.Identity> list = new ArrayList<>(Arrays.asList(MAIN, SERVICE));
        final List<Integer> killed = new ArrayList<>();
        public List<RecoveryProcesses.Identity> snapshot() throws IOException {
            scans++;
            if (unreadable) throw new IOException("Unreadable ownership");
            return new ArrayList<>(list);
        }
        public void terminate(RecoveryProcesses.Identity expected) throws IOException {
            if (reused) throw new IOException("Identity changed before kill");
            killed.add(expected.pid);
            if (!unkillable) list.remove(expected);
        }
        public long elapsedMillis() { return time; }
        public void pause(long delay) { time += delay; }
    }
    private static void rejects(Host host) throws Exception {
        try { RecoveryProcesses.quiesce(host, UID, MAIN, SERVICE, PACKAGE); throw new AssertionError("Expected refusal"); }
        catch (IOException expected) { check(true, "refused"); }
    }
    public static void main(String[] args) throws Exception {
        Host idle = new Host();
        RecoveryProcesses.quiesce(idle, UID, MAIN, SERVICE, PACKAGE);
        check(idle.scans == 2 && idle.time == 100, "needs two complete scans");
        Host children = new Host();
        children.list.add(identity(30, UID, 300, 'S', "/system/bin/sh"));
        children.list.add(identity(40, 20002, 400, 'R', "other.app"));
        children.list.add(identity(50, UID, 500, 'Z', ""));
        RecoveryProcesses.quiesce(children, UID, MAIN, SERVICE, PACKAGE);
        check(children.killed.equals(Arrays.asList(30)), "must kill only own live child");
        check(children.scans == 3, "must confirm two empty scans after termination");
        Host unreadable = new Host(); unreadable.unreadable = true; rejects(unreadable);
        check(unreadable.killed.isEmpty(), "unknown scan killed processes");
        Host neverStops = new Host(); neverStops.unkillable = true;
        neverStops.list.add(identity(30, UID, 300, 'R', "shell"));
        rejects(neverStops);
        check(neverStops.time == 3000, "cleanup not bounded");
        Host reused = new Host(); reused.reused = true;
        reused.list.add(identity(30, UID, 300, 'R', "shell"));
        rejects(reused);
        check(reused.killed.isEmpty(), "reused pid killed");
        Host spoof = new Host();
        spoof.list.add(identity(30, UID, 300, 'S', PACKAGE));
        rejects(spoof);
        check(spoof.killed.isEmpty(), "ambiguous main process killed");
        Host absent = new Host(); absent.list.remove(MAIN); rejects(absent);
        Host changed = new Host(); changed.list.set(0, identity(10, UID, 999, 'S', PACKAGE)); rejects(changed);
        Host deadMain = new Host(); deadMain.list.set(0, identity(10, UID, 100, 'Z', "")); rejects(deadMain);
        check(!MAIN.same(identity(10, UID, 999, 'S', PACKAGE)), "starttime identity ignored");
        check(!MAIN.same(identity(10, 20002, 100, 'S', PACKAGE)), "UID identity ignored");
        check(!identity(30, UID, 300, 'x', "").active(), "dead process considered live");
        System.out.println("RecoveryProcesses: " + checks + " checks passed (UID scope, stable identities, complete scans, zombies, bounded refusal)");
    }
}
