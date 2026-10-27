package com.minnnng.dsh_android;

import java.util.Objects;

public final class LinuxVmGuestObservationTest {
    private static final String EXPECTED = "com.minnnng.dsh_android:linux_vm:com.minnnng.dsh_android."
            + "IsolatedLinuxVmService:linux_vm_0123456789ab4def8123456789abcdef";
    private static final String APP = "app=ProcessRecord{feed 8142:" + EXPECTED + "/u0a496i262}";
    private static int passed;

    public static void main(String[] args) {
        String service = service("abc", APP);
        equal(8142, parse(service));
        equal(8142, parse("  User 0 active services:\n" + service
                + "  Pending services:\n" + service));
        equal(8142, parse(service + service("other", APP).replace(EXPECTED, "another-run")));
        equal(null, parse(service.replace(EXPECTED, "another-run")));
        equal(null, parse(service("abc", "app=null")));
        equal(null, parse(service("abc", "app=null") + service("abc", "app=null")));
        rejects(service + service("def", APP), "Ambiguous");
        rejects(service + service("abc", APP.replace("8142:", "8143:")), "Ambiguous");
        rejects(service + service("abc", APP.replace("feed ", "beef ")), "Ambiguous");
        rejects(service + service("abc", APP.replace("i262", "i263")), "Ambiguous");
        rejects(service + service("abc", "app=null"), "Ambiguous");
        rejects(service.replace(APP, APP + "\n    " + APP), "fields");
        rejects(service.replace("processName=" + EXPECTED,
                "processName=" + EXPECTED + "\n    processName=other"), "fields");
        rejects(service.replace(APP, ""), "fields");
        rejects(service.replace("8142:" + EXPECTED, "8142:" + EXPECTED + "extra"), "exact process");
        rejects(service.replace("8142:", "999999999999:"), "PID");
        // ConnectionRecord references are not top-level ServiceRecords or direct fields.
        String connection = "  * ConnectionRecord{abc ServiceRecord{nested u0 component}}\n"
                + "    * ServiceRecord{nested u0 component}\n"
                + "      processName=" + EXPECTED + "\n      " + APP + "\n";
        equal(null, parse(connection));
        equal(8142, parse(service + "  Connection bindings to services:\n" + connection));
        equal(null, parse("  * ServiceRecord{outer u0 unrelated}\n    processName=other\n"
                + "    Bindings:\n      processName=" + EXPECTED + "\n      " + APP + "\n"));
        try {
            parse(service + service("def", APP) + "    baseDir=/DO-NOT-LOG-PRIVATE-DATA\n");
            throw new AssertionError("Conflicting services accepted");
        } catch (LinuxVmGuestObservation.ObservationFailure failure) {
            if (!failure.diagnostic.contains("matchingRecords=2")
                    || !failure.diagnostic.contains("8142:")
                    || failure.diagnostic.contains("DO-NOT-LOG-PRIVATE-DATA"))
                throw new AssertionError("Diagnostic lacks identity or includes unrelated fields");
            passed++;
        }
        try {
            parse(service.repeat(100) + service("def", APP));
            throw new AssertionError("Conflicting services accepted");
        } catch (LinuxVmGuestObservation.ObservationFailure failure) {
            if (failure.diagnostic.length() > 5000 || failure.diagnostic.split("\nrecord=", -1).length != 5)
                throw new AssertionError("Diagnostic exceeds its record bound");
            passed++;
        }
        workerChecks();
        System.out.println("LinuxVmGuestObservation: " + passed + " parser checks passed; device cancellation unverified");
    }

    private static String service(String identity, String app) {
        return "  * ServiceRecord{" + identity + " u0 com.minnnng.dsh_android/.IsolatedLinuxVmService:"
                + "linux_vm_0123456789ab4def8123456789abcdef c:com.minnnng.dsh_android}\n"
                + "    processName=" + EXPECTED + "\n    " + app + "\n";
    }
    private static Integer parse(String value) { return LinuxVmGuestObservation.pid(value, EXPECTED); }
    private static void equal(Integer expected, Integer actual) {
        if (!Objects.equals(expected, actual)) throw new AssertionError("Expected " + expected + ", got " + actual);
        passed++;
    }
    private static void rejects(String value, String reason) {
        try { parse(value); throw new AssertionError("Invalid identity accepted"); }
        catch (LinuxVmGuestObservation.ObservationFailure expected) {
            if (!expected.getMessage().contains(reason)) throw new AssertionError(expected);
            passed++;
        }
    }

    private static void workerChecks() {
        // CMD values projected from r20's real TID,COMM,CMD,TIME capture; CMD-only header was captured separately.
        String header = "  TID CMD                 TIME\n";
        String row = "29757 isolated-linux- 00:00:02\n";
        var observed = LinuxVmGuestObservation.workerCpu(header + "29718 Signal Catcher 00:00:00\n"
                + "29720 Jit thread pool 00:00:00\n" + row);
        if (observed == null || observed.tid != 29757 || observed.seconds != 2
                || !observed.command.equals("isolated-linux-") || !observed.time.equals("00:00:02"))
            throw new AssertionError("Exact worker evidence was not retained");
        passed++;
        if (LinuxVmGuestObservation.workerCpu(header + row.replace("isolated-linux- ", "isolated-linux-vm ")) == null)
            throw new AssertionError("Full kernel thread name was not accepted");
        passed++;
        for (String absent : new String[] {header, header + row.replace("00:00:02", "00:00:00"),
                header + "29720 Jit thread pool 00:00:09\n", header + row.replace("isolated-linux-", "unrelated-worker"),
                header + row.replace("isolated-linux-", "[isolated-linux-]"),
                header + row.replace("isolated-linux-", EXPECTED)}) {
            if (LinuxVmGuestObservation.workerCpu(absent) != null) throw new AssertionError("Unrelated or zero CPU accepted");
            passed++;
        }
        for (String invalid : new String[] {header.replace("CMD", "NAME") + row,
                header.replace("CMD", "COMM") + row, "TID COMM CMD TIME\n" + row,
                header + row + row.replace("29757", "29758"),
                header + row.replace("00:00:02", "00:00:00") + row,
                header + row.replace("29757", "0"), header + row.replace("29757", "-1"),
                header + row.replace("29757", "+29757"), header + row.replace("29757", "999999999999"),
                header + row.replace("00:00:02", "00:60:02"), header + row.replace("00:00:02", "00:00:60"),
                header + row.replace("00:00:02", "0:0:2"), header + row.replace("00:00:02", "unknown"),
                header + row.replace("00:00:02", "99999999999999999999:00:02"),
                header + row.replace("00:00:02", "extra 00:00:02")}) {
            try { LinuxVmGuestObservation.workerCpu(invalid); throw new AssertionError("Invalid worker proof accepted"); }
            catch (IllegalArgumentException | IllegalStateException expected) { passed++; }
        }
    }
}
