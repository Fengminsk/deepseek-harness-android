package com.minnnng.dsh_android;

import java.io.IOException;

/** One admitted run's bounded HTTPS exchange; an IPC implementation owns its own cancellation. */
interface LinuxVmHttpsExchange extends AutoCloseable {
    /** Runs off the main thread. Return only a terminal, durably audited reply for this request. */
    byte[] request(int sequence, String runId, String callId, String url) throws IOException;
    boolean active();
    /** Stops new calls and closes any in-flight transport without waiting for its caller. */
    @Override void close();
}
