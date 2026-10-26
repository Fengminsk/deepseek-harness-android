package com.minnnng.dsh_android;

/** Pure admission check for the fixed isolated-shell diagnostic. This grants no shell capability. */
final class ShellProbeEvidence {
    static final String MARKER = "pocket-harness-isolated-shell-probe\n";
    static final String PRIVATE_DENIED = "private-denied\n";
    static final String PRIVATE_WRITE_DENIED = "private-write-denied\n";
    static final int MAX_OUTPUT_BYTES = 256;

    private ShellProbeEvidence() { }

    static String rejection(int appUid, int senderUid, int reportedUid, boolean guestIsolated,
                            boolean privateDirectoryReadable, boolean privateFileWritable,
                            boolean privateMarkerExists, boolean inetSocketOpened,
                            boolean shellCompleted, String output) {
        if (senderUid < 0 || senderUid == appUid || senderUid != reportedUid || !guestIsolated) {
            return "Isolated worker UID was not verified";
        }
        if (privateDirectoryReadable) return "Isolated worker could read the App private directory";
        if (privateFileWritable || privateMarkerExists) return "Isolated shell could write the App private directory";
        if (inetSocketOpened) return "Isolated worker could create an Internet socket";
        String expected = MARKER + reportedUid + "\n" + PRIVATE_DENIED + PRIVATE_WRITE_DENIED;
        if (!shellCompleted || output == null || output.length() > MAX_OUTPUT_BYTES || !expected.equals(output)) {
            return "Fixed shell probe did not prove its UID and private-file denial";
        }
        return null;
    }
}
