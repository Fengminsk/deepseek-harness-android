package com.minnnng.dsh_android;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;
import java.util.function.LongSupplier;
import java.util.function.Supplier;

/**
 * One-use notification delivery tokens. This class never decides or expires a
 * DSH approval: the service replaces/removes offers when its core snapshot changes.
 */
public final class ApprovalActionLedger {
    public static final class Offer {
        public final String id;
        public final long version;
        public final Set<String> actions;
        public final String token;
        public final long tokenExpiresAt;
        private boolean claimed;

        private Offer(String id, long version, Set<String> actions, String token, long tokenExpiresAt) {
            this.id = id;
            this.version = version;
            this.actions = java.util.Collections.unmodifiableSet(new HashSet<>(actions));
            this.token = token;
            this.tokenExpiresAt = tokenExpiresAt;
        }

        public boolean isClaimed() { return claimed; }
    }

    private final LongSupplier elapsedTime;
    private final Supplier<String> tokens;
    private final long tokenLifetimeMillis;
    private final Map<String, Offer> offers = new HashMap<>();

    public ApprovalActionLedger(LongSupplier elapsedTime, Supplier<String> tokens, long tokenLifetimeMillis) {
        if (tokenLifetimeMillis <= 0) throw new IllegalArgumentException("Token lifetime must be positive");
        this.elapsedTime = elapsedTime;
        this.tokens = tokens;
        this.tokenLifetimeMillis = tokenLifetimeMillis;
    }

    /** Repeated snapshots retain claimed tokens; only a new request version replaces an offer. */
    public synchronized Offer offer(String id, long version, Set<String> actions) {
        if (id.isEmpty() || version < 0) throw new IllegalArgumentException("Invalid request identity");
        Offer previous = offers.get(id);
        if (previous != null) {
            if (version < previous.version) throw new IllegalArgumentException("Older request version");
            if (version == previous.version) {
                if (!previous.actions.equals(actions)) throw new IllegalArgumentException("Changed actions require a new version");
                return previous;
            }
        }
        Offer next = create(id, version, actions);
        offers.put(id, next);
        return next;
    }

    public synchronized Offer get(String id) { return offers.get(id); }

    /** Renew a still-unclaimed delivery token without settling its underlying DSH request. */
    public synchronized Offer renew(String id, long version) {
        Offer previous = offers.get(id);
        if (previous == null || previous.version != version || previous.claimed) return null;
        Offer next = create(id, version, previous.actions);
        offers.put(id, next);
        return next;
    }

    /** True exactly once for a matching, current, unexpired token and an advertised action. */
    public synchronized boolean claim(String id, long version, String token, String action) {
        if (!canClaim(id, version, token, action)) return false;
        offers.get(id).claimed = true;
        return true;
    }

    /** Validate input ownership before preserving a draft; this check does not consume the token. */
    public synchronized boolean canClaim(String id, long version, String token, String action) {
        Offer offer = offers.get(id);
        if (offer == null || offer.version != version || offer.claimed
                || elapsedTime.getAsLong() >= offer.tokenExpiresAt || !offer.actions.contains(action)
                || !MessageDigest.isEqual(offer.token.getBytes(StandardCharsets.UTF_8),
                        token.getBytes(StandardCharsets.UTF_8))) return false;
        return true;
    }

    /** Call only after the core explicitly reports that the submitted response was not applied. */
    public synchronized Offer retryUnapplied(String id, long version) {
        Offer previous = offers.get(id);
        if (previous == null || previous.version != version) return null;
        Offer next = create(id, version, previous.actions);
        offers.put(id, next);
        return next;
    }

    public synchronized void remove(String id) { offers.remove(id); }
    public synchronized void clear() { offers.clear(); }

    private Offer create(String id, long version, Set<String> actions) {
        return new Offer(id, version, actions, tokens.get(), elapsedTime.getAsLong() + tokenLifetimeMillis);
    }
}
