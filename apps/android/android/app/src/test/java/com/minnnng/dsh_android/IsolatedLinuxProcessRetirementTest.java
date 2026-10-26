package com.minnnng.dsh_android;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.concurrent.TimeUnit;

/** Standalone JVM test for the fixed-command retirement gate. */
public final class IsolatedLinuxProcessRetirementTest {
    private static final class Child extends Process {
        boolean destroyed;
        boolean exited;
        boolean interruptWait;
        @Override public OutputStream getOutputStream() { return new ByteArrayOutputStream(); }
        @Override public InputStream getInputStream() { return new ByteArrayInputStream(new byte[0]); }
        @Override public InputStream getErrorStream() { return new ByteArrayInputStream(new byte[0]); }
        @Override public int waitFor() { return 0; }
        @Override public boolean waitFor(long time, TimeUnit unit) throws InterruptedException {
            if (interruptWait) throw new InterruptedException("simulated");
            return exited;
        }
        @Override public int exitValue() { if (!exited) throw new IllegalThreadStateException(); return 0; }
        @Override public void destroy() { destroyed = true; }
        @Override public Process destroyForcibly() { destroyed = true; return this; }
        @Override public boolean isAlive() { return !exited; }
    }

    public static void main(String[] args) {
        Child reaped = new Child();
        reaped.exited = true;
        require(IsolatedLinuxProcessRetirement.stopAndReap(reaped, 250) && reaped.destroyed);
        Child surviving = new Child();
        require(!IsolatedLinuxProcessRetirement.stopAndReap(surviving, 250) && surviving.destroyed);
        Child interrupted = new Child();
        interrupted.interruptWait = true;
        require(!IsolatedLinuxProcessRetirement.stopAndReap(interrupted, 250));
        require(Thread.interrupted());
        require(!IsolatedLinuxProcessRetirement.stopAndReap(null, 250));
        require(!IsolatedLinuxProcessRetirement.stopAndReap(new Child(), 0));
        System.out.println("IsolatedLinuxProcessRetirementTest passed");
    }

    private static void require(boolean valid) {
        if (!valid) throw new AssertionError("Fixed command retirement invariant failed");
    }
}
