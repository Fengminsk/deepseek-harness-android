package com.minnnng.dsh_android;

import java.io.IOException;
import java.io.InputStream;
import java.util.concurrent.Executor;

/** Owns cancellation of one selected-file import; the copying worker owns final cleanup. */
public final class AttachmentImportLifecycle {
    private boolean cancelled;
    private InputStream input;

    public synchronized boolean isCancelled() { return cancelled; }

    /** A stream opened after cancellation is closed by its worker without copying any bytes. */
    public void attach(InputStream value) throws IOException {
        synchronized (this) {
            if (!cancelled) {
                input = value;
                return;
            }
        }
        value.close();
        throw new IOException("附件导入已取消");
    }

    public synchronized void detach(InputStream value) {
        if (input == value) input = null;
    }

    /** Requests cancellation without closing a provider on the caller's thread or claiming it stopped. */
    public void requestCancel(Executor cleanup) {
        InputStream active;
        synchronized (this) {
            if (cancelled) return;
            cancelled = true;
            active = input;
        }
        if (active == null) return;
        cleanup.execute(() -> {
            try { active.close(); }
            catch (Exception closeFailure) {
                // The copying worker still closes its stream and removes unpublished files.
            }
        });
    }
}
