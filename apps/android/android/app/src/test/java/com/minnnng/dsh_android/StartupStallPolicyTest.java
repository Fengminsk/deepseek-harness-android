package com.minnnng.dsh_android;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public final class StartupStallPolicyTest {
    @Test
    public void requiresConsecutiveStalledChecks() {
        StartupStallPolicy policy = new StartupStallPolicy(2);
        policy.recordProgress(1_000L);
        assertFalse(policy.stalled(1_000L + 299_000L, 300_000L));
        assertFalse("first stalled check is only a suspicion", policy.stalled(1_000L + 301_000L, 300_000L));
        assertTrue("the second consecutive check confirms", policy.stalled(1_000L + 306_000L, 300_000L));
    }

    @Test
    public void progressClearsAConfirmedRun() {
        StartupStallPolicy policy = new StartupStallPolicy(2);
        policy.recordProgress(1_000L);
        assertFalse(policy.stalled(301_000L, 300_000L));
        policy.recordProgress(302_000L);
        assertFalse("progress resets the confirmation count", policy.stalled(500_000L, 300_000L));
        assertTrue(policy.stalled(606_000L, 300_000L));
    }

    @Test
    public void budgetChangesApplyToTheSameProgressBaseline() {
        StartupStallPolicy policy = new StartupStallPolicy(2);
        policy.recordProgress(0L);
        assertFalse(policy.stalled(150_000L, 300_000L));
        assertFalse("a shorter budget still needs a second check", policy.stalled(150_000L, 120_000L));
        assertTrue(policy.stalled(150_000L, 120_000L));
    }

    @Test
    public void singleConfirmationModeConfirmsImmediately() {
        StartupStallPolicy policy = new StartupStallPolicy(1);
        policy.recordProgress(0L);
        assertTrue(policy.stalled(1L, 0L));
    }
}
