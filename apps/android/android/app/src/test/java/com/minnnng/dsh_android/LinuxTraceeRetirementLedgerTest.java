package com.minnnng.dsh_android;

/** JVM protocol checks; actual PRoot event completeness requires a device test. */
public final class LinuxTraceeRetirementLedgerTest {
    public static void main(String[] args) {
        completesOnlyAfterEveryReap();
        rejectsIncompleteOrAmbiguousStreams();
        cancellationNeverPublishesSuccess();
        System.out.println("LinuxTraceeRetirementLedgerTest passed");
    }

    private static void completesOnlyAfterEveryReap() {
        LinuxTraceeRetirementLedger ledger = new LinuxTraceeRetirementLedger(100);
        require(ledger.arm(LinuxTraceeRetirementLedger.REQUIRED_OPTIONS));
        require(ledger.spawned(1, 100, 101));
        require(ledger.spawned(2, 101, 102));
        // The parent can exit before a detached descendant; direct-child wait is insufficient.
        require(ledger.reaped(3, 100));
        require(ledger.reaped(4, 101));
        require(!ledger.mayPublishSuccess());
        require(ledger.reaped(5, 102));
        require(ledger.close(6, true, true));
        require(ledger.mayPublishSuccess());
    }

    private static void rejectsIncompleteOrAmbiguousStreams() {
        LinuxTraceeRetirementLedger missingOptions = new LinuxTraceeRetirementLedger(1);
        require(!missingOptions.arm(LinuxTraceeRetirementLedger.TRACE_EXIT));
        require(!missingOptions.close(1, true, true));
        require(!missingOptions.mayPublishSuccess());

        LinuxTraceeRetirementLedger missingChild = new LinuxTraceeRetirementLedger(1);
        require(missingChild.arm(LinuxTraceeRetirementLedger.REQUIRED_OPTIONS));
        require(missingChild.spawned(1, 1, 2));
        require(missingChild.reaped(2, 1));
        require(!missingChild.close(3, true, true));
        require(!missingChild.retirementConfirmed());

        LinuxTraceeRetirementLedger gap = new LinuxTraceeRetirementLedger(1);
        require(gap.arm(LinuxTraceeRetirementLedger.REQUIRED_OPTIONS));
        require(!gap.spawned(2, 1, 2));
        require(!gap.reaped(1, 1));
        require(!gap.close(1, true, true));

        LinuxTraceeRetirementLedger reusedPid = new LinuxTraceeRetirementLedger(1);
        require(reusedPid.arm(LinuxTraceeRetirementLedger.REQUIRED_OPTIONS));
        require(reusedPid.spawned(1, 1, 2));
        require(reusedPid.reaped(2, 2));
        require(!reusedPid.spawned(3, 1, 2));
        require(!reusedPid.mayPublishSuccess());

        LinuxTraceeRetirementLedger earlyExit = new LinuxTraceeRetirementLedger(1);
        require(earlyExit.arm(LinuxTraceeRetirementLedger.REQUIRED_OPTIONS));
        require(earlyExit.reaped(1, 1));
        require(!earlyExit.close(2, false, true));
        require(!earlyExit.retirementConfirmed());

        LinuxTraceeRetirementLedger unreadEvents = new LinuxTraceeRetirementLedger(1);
        require(unreadEvents.arm(LinuxTraceeRetirementLedger.REQUIRED_OPTIONS));
        require(unreadEvents.reaped(1, 1));
        require(!unreadEvents.close(2, true, false));
        require(!unreadEvents.retirementConfirmed());

        LinuxTraceeRetirementLedger forkPressure = new LinuxTraceeRetirementLedger(1);
        require(forkPressure.arm(LinuxTraceeRetirementLedger.REQUIRED_OPTIONS));
        for (int child = 2; child <= LinuxTraceeRetirementLedger.MAX_LIFETIMES; child++) {
            require(forkPressure.spawned(child - 1, 1, child));
        }
        require(!forkPressure.spawned(LinuxTraceeRetirementLedger.MAX_LIFETIMES, 1,
            LinuxTraceeRetirementLedger.MAX_LIFETIMES + 1));
        require(!forkPressure.mayPublishSuccess());
    }

    private static void cancellationNeverPublishesSuccess() {
        LinuxTraceeRetirementLedger ledger = new LinuxTraceeRetirementLedger(1);
        require(ledger.arm(LinuxTraceeRetirementLedger.REQUIRED_OPTIONS));
        ledger.requestCancellation();
        require(ledger.reaped(1, 1));
        require(ledger.close(2, true, true));
        require(ledger.retirementConfirmed());
        require(!ledger.mayPublishSuccess());
    }

    private static void require(boolean value) {
        if (!value) throw new AssertionError("Tracee retirement evidence was accepted incorrectly");
    }
}
