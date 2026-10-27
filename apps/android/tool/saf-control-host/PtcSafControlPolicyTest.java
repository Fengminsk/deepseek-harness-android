package com.minnnng.dsh_android;

/** Runs the real policy methods on JVM; no Android Binder or URI-grant behavior is simulated as acceptance. */
public final class PtcSafControlPolicyTest {
    private static final String CASE = "5fdfab16-cd56-4bd4-aad3-29f8706b0908";
    private static int passed;
    private static void denied(Runnable action) {
        try { action.run(); throw new AssertionError("Invalid control request was accepted"); }
        catch (IllegalArgumentException | SecurityException expected) { passed++; }
    }
    public static void main(String[] arguments) {
        for (String method : new String[] {"ptc.create", "ptc.arm", "ptc.state", "ptc.revoke", "ptc.remove"}) {
            PtcSafAcceptanceControlService.requireRequest(10042, 10042, CASE, CASE, method, true, 1, 1, 2);
            passed++;
        }
        denied(() -> PtcSafAcceptanceControlService.requireRequest(10043, 10042, CASE, CASE, "ptc.create", true, 1, 1, 2));
        denied(() -> PtcSafAcceptanceControlService.requireRequest(10042, 10042, CASE, CASE, "ptc.create", false, 1, 1, 2));
        denied(() -> PtcSafAcceptanceControlService.requireRequest(10042, 10042, CASE, "1fdfab16-cd56-4bd4-aad3-29f8706b0908", "ptc.create", true, 1, 1, 2));
        denied(() -> PtcSafAcceptanceControlService.requireRequest(10042, 10042, CASE, CASE, "ptc.create", true, 2, 1, 2));
        denied(() -> PtcSafAcceptanceControlService.requireRequest(10042, 10042, CASE, CASE, "ptc.create", true, 1, 0, 2));
        denied(() -> PtcSafAcceptanceControlService.requireRequest(10042, 10042, CASE, CASE, "ptc.create", true, 1, 1, 3));
        for (String method : new String[] {null, "", "read", "ptc.exec", "ptc.create/../remove"})
            denied(() -> PtcSafAcceptanceControlService.requireRequest(10042, 10042, CASE, CASE, method, true, 1, 1, 2));
        for (String id : new String[] {null, "../user", CASE.toUpperCase(), "5fdfab16-cd56-1bd4-aad3-29f8706b0908", "1-1-4-1-1"})
            denied(() -> PtcSafAcceptanceProvider.requireCase(id));
        System.out.println("SAF real control policy checks passed: " + passed);
    }
}
