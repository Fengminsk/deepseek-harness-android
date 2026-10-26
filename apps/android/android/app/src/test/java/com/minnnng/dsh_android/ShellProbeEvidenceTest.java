package com.minnnng.dsh_android;

/** Standalone JVM acceptance for the internal isolated-shell evidence gate. */
public final class ShellProbeEvidenceTest {
    public static void main(String[] args) {
        acceptsOnlyExactIndependentDeniedEvidence();
        rejectsTruncatedOrFabricatedShellOutput();
        System.out.println("Shell probe evidence: UID, private write and network rejection passed");
    }

    private static void acceptsOnlyExactIndependentDeniedEvidence() {
        check(ShellProbeEvidence.rejection(1000, 99001, 99001, true,
                false, false, false, false, true, expected(99001)) == null,
                "independent denied evidence was rejected");
        check(ShellProbeEvidence.rejection(1000, 1000, 1000, true,
                false, false, false, false, true, expected(1000)) != null,
                "App UID was accepted");
        check(ShellProbeEvidence.rejection(1000, 99001, 99002, true,
                false, false, false, false, true, expected(99002)) != null,
                "mismatched Binder and reported UIDs were accepted");
        check(ShellProbeEvidence.rejection(1000, 99001, 99001, false,
                false, false, false, false, true, expected(99001)) != null,
                "non-isolated worker was accepted");
        check(ShellProbeEvidence.rejection(1000, 99001, 99001, true,
                true, false, false, false, true, expected(99001)) != null,
                "readable App directory was accepted");
        check(ShellProbeEvidence.rejection(1000, 99001, 99001, true,
                false, true, false, false, true, expected(99001)) != null,
                "private write was accepted");
        check(ShellProbeEvidence.rejection(1000, 99001, 99001, true,
                false, false, true, false, true, expected(99001)) != null,
                "created private marker was accepted");
        check(ShellProbeEvidence.rejection(1000, 99001, 99001, true,
                false, false, false, true, true, expected(99001)) != null,
                "Internet socket was accepted");
    }

    private static void rejectsTruncatedOrFabricatedShellOutput() {
        check(rejection(false, expected(99001)) != null, "failed child was accepted");
        check(rejection(true, expected(99001) + "extra") != null, "extra output was accepted");
        check(rejection(true, "x".repeat(ShellProbeEvidence.MAX_OUTPUT_BYTES + 1)) != null,
                "oversize output was accepted");
        check(rejection(true, ShellProbeEvidence.MARKER + "1000\n" +
                ShellProbeEvidence.PRIVATE_DENIED + ShellProbeEvidence.PRIVATE_WRITE_DENIED) != null,
                "child reported App UID");
        check(rejection(true, ShellProbeEvidence.MARKER + "99001\nprivate-opened\n" +
                ShellProbeEvidence.PRIVATE_WRITE_DENIED) != null, "child read App directory");
        check(rejection(true, ShellProbeEvidence.MARKER + "99001\n" +
                ShellProbeEvidence.PRIVATE_DENIED) != null, "missing write proof was accepted");
        check(rejection(true, ShellProbeEvidence.MARKER + "99001\n" +
                ShellProbeEvidence.PRIVATE_DENIED + "private-write-opened\n") != null,
                "child write success was accepted");
    }

    private static String rejection(boolean completed, String output) {
        return ShellProbeEvidence.rejection(1000, 99001, 99001, true,
                false, false, false, false, completed, output);
    }

    private static String expected(int uid) {
        return ShellProbeEvidence.MARKER + uid + "\n" + ShellProbeEvidence.PRIVATE_DENIED +
                ShellProbeEvidence.PRIVATE_WRITE_DENIED;
    }

    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
}
