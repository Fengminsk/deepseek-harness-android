package com.minnnng.dsh_android;

import java.util.Objects;

/**
 * App-UID side of a future isolated Linux guest Binder channel. Android supplies the sender UID;
 * this class never trusts a UID, path, URL, digest, or audit result carried inside a guest frame.
 * It contains no launcher, native library loading, or model-facing Shell registration.
 */
final class LinuxGuestBinderBridge implements AutoCloseable {
    interface Dispatch { byte[] dispatch(LinuxGuestBrokerWire.Request request); }

    private final String runId;
    private final LinuxGuestLaunchSession session;
    private final LinuxGuestBrokerWire wire;
    private final Dispatch files;
    private final Dispatch https;
    private final AutoCloseable httpsCloser;
    private final String imageDigest;
    private final String launcherDigest;
    private final String loaderDigest;
    private int guestUid = -1;
    private boolean closed;

    LinuxGuestBinderBridge(String runId, LinuxGuestLaunchSession session,
                           LinuxGuestBrokerWire wire, LinuxGuestFileBrokerDispatch files,
                           LinuxGuestHttpsDispatch https, String imageDigest,
                           String launcherDigest, String loaderDigest) {
        this(runId, session, wire, files::dispatch, https::dispatch, https,
                imageDigest, launcherDigest, loaderDigest);
    }

    /** Injectable dispatchers are package-private only for host protocol tests. */
    LinuxGuestBinderBridge(String runId, LinuxGuestLaunchSession session,
                           LinuxGuestBrokerWire wire, Dispatch files, Dispatch https,
                           AutoCloseable httpsCloser, String imageDigest,
                           String launcherDigest, String loaderDigest) {
        this.runId = Objects.requireNonNull(runId);
        this.session = Objects.requireNonNull(session);
        this.wire = Objects.requireNonNull(wire);
        this.files = Objects.requireNonNull(files);
        this.https = Objects.requireNonNull(https);
        this.httpsCloser = Objects.requireNonNull(httpsCloser);
        this.imageDigest = Objects.requireNonNull(imageDigest);
        this.launcherDigest = Objects.requireNonNull(launcherDigest);
        this.loaderDigest = Objects.requireNonNull(loaderDigest);
        if (!session.matchesRunId(runId))
            throw new IllegalArgumentException("Linux guest Binder run is not live");
    }

    /** A HELLO must originate from the separately bound isolated Service. */
    synchronized boolean hello(String reportedRunId, int sendingUid, int reportedUid,
                               int appUid, boolean reportedIsolated) {
        if (closed || guestUid != -1 || !reportedIsolated || !runId.equals(reportedRunId)
                || !session.guestConnected(runId, sendingUid, reportedUid, appUid,
                        imageDigest, launcherDigest, loaderDigest)) {
            close();
            return false;
        }
        guestUid = sendingUid;
        return true;
    }

    /** Frame bytes and UID come from a single observed Binder message, not a guest claim. */
    byte[] frame(String reportedRunId, int sendingUid, byte[] frame) {
        synchronized (this) {
            if (closed || guestUid < 0 || guestUid != sendingUid
                    || !runId.equals(reportedRunId) || frame == null
                    || frame.length > LinuxGuestBrokerWire.MAX_REQUEST_BYTES) {
                close();
                return null;
            }
        }
        LinuxGuestBrokerWire.Request request = wire.admitRequest(frame.clone(), sendingUid);
        if (request == null) { close(); return null; }
        byte[] result;
        try {
            result = (request.operation() == LinuxGuestBrokerWire.Operation.HTTPS_HOST
                    ? https : files).dispatch(request);
        } catch (RuntimeException failure) {
            close();
            return null;
        }
        synchronized (this) {
            if (closed || !session.matchesRunId(runId) || result == null || result.length >
                    LinuxGuestBrokerWire.HEADER_BYTES + LinuxGuestBrokerWire.MAX_REPLY_BYTES) {
                close();
                return null;
            }
            return result.clone();
        }
    }

    synchronized boolean active() { return !closed && guestUid >= 0 && session.matchesRunId(runId); }

    @Override public synchronized void close() {
        if (closed) return;
        closed = true;
        wire.close();
        session.close();
        try { httpsCloser.close(); } catch (Exception ignored) { /* Already cancelled. */ }
    }
}
