package com.minnnng.dsh_android;

import java.io.IOException;
import java.io.Writer;

/** Serializes IPC frames without keeping requests for a later runtime generation. */
public final class RuntimeTransport implements AutoCloseable {
    private final RuntimeLifecycle lifecycle;
    private final Writer output;
    private boolean closed;

    public RuntimeTransport(RuntimeLifecycle lifecycle, Writer output) {
        this.lifecycle = lifecycle;
        this.output = output;
    }

    /** A frame that has begun writing has an unknown outcome if the runtime fails. */
    public synchronized void write(String frame) throws IOException {
        // Check after acquiring the writer: a request may have queued while active.
        if (closed || !lifecycle.acceptsFrames()) throw new IOException("运行时连接已停止，请重新读取操作状态");
        output.write(frame);
        output.write('\n');
        output.flush();
    }

    @Override public synchronized void close() throws IOException {
        if (closed) return;
        closed = true;
        output.close();
    }
}
