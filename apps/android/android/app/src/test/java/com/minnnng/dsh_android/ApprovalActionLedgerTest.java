package com.minnnng.dsh_android;

import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

/** Standalone JVM behavior checks; no Android service, notification permission or credentials required. */
public final class ApprovalActionLedgerTest {
    public static void main(String[] args) throws Exception {
        AtomicLong now = new AtomicLong(100);
        AtomicInteger sequence = new AtomicInteger();
        ApprovalActionLedger ledger = new ApprovalActionLedger(now::get, () -> "token-" + sequence.incrementAndGet(), 1000);
        Set<String> actions = Set.of("allowed-once", "rejected");
        ApprovalActionLedger.Offer first = ledger.offer("request", 1, actions);
        check(ledger.canClaim("request", 1, first.token, "allowed-once"), "current token unavailable");
        check(!first.isClaimed(), "checking draft ownership consumed a token");
        check(!ledger.claim("request", 2, first.token, "allowed-once"), "wrong version accepted");
        check(!ledger.claim("request", 1, "incorrect", "allowed-once"), "wrong token accepted");
        check(!ledger.claim("request", 1, first.token, "always-allow"), "unadvertised action accepted");

        CountDownLatch start = new CountDownLatch(1);
        AtomicInteger accepted = new AtomicInteger();
        Thread one = new Thread(() -> claimAtBarrier(ledger, first, start, accepted, "allowed-once"));
        Thread two = new Thread(() -> claimAtBarrier(ledger, first, start, accepted, "rejected"));
        one.start();
        two.start();
        start.countDown();
        one.join();
        two.join();
        check(accepted.get() == 1, "concurrent actions were not one-shot");
        check(ledger.offer("request", 1, actions).isClaimed(), "same snapshot reset a consumed token");
        check(ledger.renew("request", 1) == null, "automatic renewal reopened a submitted action");
        check(!ledger.claim("request", 1, first.token, "allowed-once"), "duplicate action accepted");

        ApprovalActionLedger.Offer next = ledger.offer("request", 2, actions);
        check(!ledger.claim("request", 1, first.token, "rejected"), "superseded action accepted");
        now.set(next.tokenExpiresAt);
        check(!ledger.claim("request", 2, next.token, "allowed-once"), "expired transport token accepted");
        check(ledger.get("request") != null, "token expiry removed a DSH request");
        ApprovalActionLedger.Offer renewed = ledger.renew("request", 2);
        check(renewed != null && !renewed.token.equals(next.token), "renewal reused token");
        check(ledger.claim("request", 2, renewed.token, "rejected"), "renewed token rejected");

        ApprovalActionLedger.Offer retry = ledger.retryUnapplied("request", 2);
        check(retry != null && !retry.token.equals(renewed.token), "explicit failed-response retry reused token");
        check(!ledger.claim("request", 2, renewed.token, "allowed-once"), "old token accepted after retry");
        ledger.remove("request");
        check(!ledger.claim("request", 2, retry.token, "rejected"), "withdrawn request accepted");
        ledger.offer("other", 1, actions);
        ledger.clear();
        check(ledger.get("other") == null, "service disposal left an offer");
        System.out.println("ApprovalActionLedger: stale, duplicate, concurrent, expiry, renewal, retry and disposal checks passed");
    }

    private static void claimAtBarrier(ApprovalActionLedger ledger, ApprovalActionLedger.Offer offer,
            CountDownLatch start, AtomicInteger accepted, String action) {
        try {
            start.await();
            if (ledger.claim(offer.id, offer.version, offer.token, action)) accepted.incrementAndGet();
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            throw new AssertionError(error);
        }
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
