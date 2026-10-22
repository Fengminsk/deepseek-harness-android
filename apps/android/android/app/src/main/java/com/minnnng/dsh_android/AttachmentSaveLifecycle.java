package com.minnnng.dsh_android;

import java.io.IOException;
import java.io.OutputStream;
import java.util.concurrent.Executor;

/** Cancellation requests never imply the provider worker has stopped using its verified source. */
public final class AttachmentSaveLifecycle {
    private boolean cancelled;
    private OutputStream output;

    public synchronized boolean isCancelled() { return cancelled; }

    /** Called on the copying worker; a provider opened late is closed before any bytes are written. */
    public void attach(OutputStream value) throws IOException {
        synchronized (this) {
            if (!cancelled) { output = value; return; }
        }
        value.close();
        throw new IOException("附件保存已取消");
    }

    public synchronized void detach(OutputStream value) {
        if (output == value) output = null;
    }

    /** A separate closer can unblock a provider write. Only the copying worker reports completion. */
    public void requestCancel(Executor closer) {
        OutputStream active;
        synchronized (this) {
            if (cancelled) return;
            cancelled = true;
            active = output;
        }
        if (active != null) closer.execute(() -> {
            try { active.close(); }
            catch (Exception closeFailure) { /* Worker finally still owns stream closure and completion. */ }
        });
    }
}
