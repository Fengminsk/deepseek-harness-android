package com.minnnng.dsh_android;

/** Main-thread ownership of an optional window; preference never proves attachment. */
public final class OverlayLease {
    public interface Attachment {
        void attached();
        void detached();
    }

    public interface WindowHost {
        void attach(Attachment observer) throws Exception;
        void remove() throws Exception;
    }

    private final WindowHost host;
    private boolean enabled, granted, working, closed, owned, attached, removing;
    private long generation;
    private String failure;

    public OverlayLease(WindowHost host) { this.host = host; }

    public void update(boolean enabled, boolean granted, boolean working) {
        if (closed) return;
        boolean newOpportunity = (!this.enabled && enabled) || (!this.granted && granted)
                || (!this.working && working);
        this.enabled = enabled;
        this.granted = granted;
        this.working = working;
        if (newOpportunity && !owned) failure = null;
        reconcile();
    }

    /** Explicit retry only; repeated snapshots do not retry a rejected add. */
    public void retry() {
        if (closed) return;
        if (failure != null && owned) remove();
        if (!owned) failure = null;
        reconcile();
    }

    private boolean wanted() { return !closed && enabled && granted && working; }

    private void reconcile() {
        if (!wanted()) {
            if (owned) remove();
            return;
        }
        if (owned || failure != null) return;
        owned = true;
        long ticket = ++generation;
        try {
            host.attach(new Attachment() {
                @Override public void attached() {
                    if (ticket != generation || !owned || removing) return;
                    attached = true;
                    if (!wanted()) remove();
                }
                @Override public void detached() {
                    if (ticket != generation || !owned) return;
                    attached = false;
                    if (!removing && wanted()) failure = "detached";
                }
            });
        } catch (Exception error) {
            failure = "attach-failed";
            remove();
        }
    }

    private void remove() {
        removing = true;
        try {
            host.remove();
            owned = false;
            attached = false;
            generation++;
            if ("remove-failed".equals(failure)) failure = null;
        } catch (Exception error) {
            // Retain ownership and the actual attachment fact so another removal can run.
            failure = "remove-failed";
        } finally {
            removing = false;
        }
    }

    public void close() {
        closed = true;
        if (owned) {
            remove();
            // A transient WindowManager failure must not leave a Service-owned
            // overlay after the Service exits. Keep the second attempt bounded.
            if (owned) remove();
        }
    }

    public boolean attached() { return attached; }
    public String failure() { return failure; }
    public String status() {
        if (failure != null && (wanted() || owned)) return "failed";
        if (closed) return "stopped";
        if (!enabled) return "disabled";
        if (!granted) return "permission-required";
        if (!working) return "idle";
        if (attached) return "attached";
        return owned ? "attaching" : "unavailable";
    }
}
