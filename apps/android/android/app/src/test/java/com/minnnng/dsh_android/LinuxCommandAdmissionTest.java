package com.minnnng.dsh_android;

import java.util.UUID;

public final class LinuxCommandAdmissionTest {
    private static void check(boolean condition) {
        if (!condition) throw new AssertionError();
    }

    private static void fails(Runnable action) {
        try { action.run(); }
        catch (IllegalArgumentException | IllegalStateException expected) { return; }
        throw new AssertionError("expected rejection");
    }

    public static void main(String[] ignored) throws Exception {
        LinuxCommandAdmission owner = new LinuxCommandAdmission();
        String firstId = UUID.randomUUID().toString();
        String secondId = UUID.randomUUID().toString();
        LinuxCommandAdmission.Ticket first = owner.admit(firstId);
        LinuxCommandAdmission.Ticket second = owner.admit(secondId);
        fails(() -> owner.admit(firstId));
        fails(() -> owner.admit(UUID.randomUUID().toString()));
        fails(() -> owner.admit("../escape"));
        check(owner.cancel(firstId) && first.isCancelled());
        check(!second.isCancelled());
        check(!owner.cancel(UUID.randomUUID().toString()));
        first.close(true);
        first.close();
        check(owner.cancelAndWait(firstId, 1000).settled());
        LinuxCommandAdmission.Ticket third = owner.admit(UUID.randomUUID().toString());
        Thread settler = new Thread(() -> {
            try { Thread.sleep(20); second.close(true); }
            catch (InterruptedException failure) { throw new AssertionError(failure); }
        });
        settler.start();
        LinuxCommandAdmission.CancelOutcome cancellation = owner.cancelAndWait(secondId, 1000);
        check(cancellation.requested() && cancellation.settled());
        settler.join();
        LinuxCommandAdmission.CancelOutcome confirmed = owner.cancelAndWait(secondId, 1000);
        check(!confirmed.requested() && confirmed.settled());
        LinuxCommandAdmission uncertainOwner = new LinuxCommandAdmission();
        String unconfirmedId = UUID.randomUUID().toString();
        uncertainOwner.admit(unconfirmedId).close(false);
        LinuxCommandAdmission.CancelOutcome unconfirmed = uncertainOwner.cancelAndWait(unconfirmedId, 1000);
        check(!unconfirmed.requested() && !unconfirmed.settled());
        fails(() -> uncertainOwner.admit(UUID.randomUUID().toString()));
        String cancelledBeforeExecute = UUID.randomUUID().toString();
        LinuxCommandAdmission.CancelOutcome early = owner.cancelAndWait(cancelledBeforeExecute, 1000);
        check(early.requested() && early.settled());
        fails(() -> owner.admit(cancelledBeforeExecute));
        check(!owner.cancelAndWait(cancelledBeforeExecute, 1000).requested());
        fails(() -> {
            try { owner.cancelAndWait("../escape", 1000); }
            catch (InterruptedException failure) { throw new AssertionError(failure); }
        });
        owner.close();
        check(second.isCancelled() && third.isCancelled());
        fails(() -> owner.admit(UUID.randomUUID().toString()));
        second.close();
        third.close();
        LinuxCommandAdmission saturated = new LinuxCommandAdmission();
        for (int index = 0; index < 256; index++) {
            check(saturated.cancelAndWait(UUID.randomUUID().toString(), 1000).requested());
        }
        fails(() -> {
            try { saturated.cancelAndWait(UUID.randomUUID().toString(), 1000); }
            catch (InterruptedException failure) { throw new AssertionError(failure); }
        });
        fails(() -> saturated.admit(UUID.randomUUID().toString()));
        System.out.println("LinuxCommandAdmissionTest passed");
    }
}
