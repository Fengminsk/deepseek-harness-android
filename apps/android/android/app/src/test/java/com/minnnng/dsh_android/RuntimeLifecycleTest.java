package com.minnnng.dsh_android;

import java.util.ArrayDeque;
import java.util.Queue;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicInteger;

/** Deterministic Node-exit/IPC dispatch schedules for the production transport latch. */
public final class RuntimeLifecycleTest {
    private static int checks;
    private static void check(boolean value, String message) {
        checks++;
        if (!value) throw new AssertionError(message);
    }
    private static final class Service {
        final RuntimeLifecycle lifecycle = new RuntimeLifecycle();
        final Queue<Runnable> main = new ArrayDeque<>();
        String phase = "starting";
        int readyEvents, failureEvents, nativeWork;
        void ready() {
            main.add(() -> {
                if (!lifecycle.acceptsFrames()) return;
                phase = "ready";
                readyEvents++;
            });
        }
        void fail() {
            if (!lifecycle.fail()) return;
            main.add(() -> {
                if (!lifecycle.failed()) return;
                phase = "failed";
                failureEvents++;
            });
        }
        void drain() { while (!main.isEmpty()) main.remove().run(); }
        void stop() { lifecycle.close(); phase = "restarting"; }
    }
    public static void main(String[] args) throws Exception {
        Service exitBeforeBufferedReady = new Service();
        exitBeforeBufferedReady.fail();
        exitBeforeBufferedReady.ready();
        exitBeforeBufferedReady.drain();
        check(exitBeforeBufferedReady.phase.equals("failed"), "late ready revived an exited Node runtime");
        check(exitBeforeBufferedReady.readyEvents == 0, "terminal runtime restarted summary polling");

        Service alreadyQueuedReady = new Service();
        alreadyQueuedReady.ready();
        alreadyQueuedReady.fail();
        alreadyQueuedReady.drain();
        check(alreadyQueuedReady.readyEvents == 0, "already queued ready was admitted after worker exit");
        check(alreadyQueuedReady.failureEvents == 1, "worker exit did not produce one failure notification");
        alreadyQueuedReady.fail();
        alreadyQueuedReady.drain();
        check(alreadyQueuedReady.failureEvents == 1, "IPC EOF repeated Node's terminal notification");

        Service queuedNativeWork = new Service();
        Runnable nativeRequest = () -> {
            if (queuedNativeWork.lifecycle.acceptsFrames()) queuedNativeWork.nativeWork++;
        };
        queuedNativeWork.fail();
        nativeRequest.run();
        check(queuedNativeWork.nativeWork == 0, "a queued native mutation started after transport failure");

        Service transition = new Service();
        transition.fail();
        transition.stop();
        transition.ready();
        transition.drain();
        check(transition.phase.equals("restarting") && transition.failureEvents == 0,
                "a stale failure callback replaced deliberate service teardown");
        check(!transition.lifecycle.fail(), "closed service accepted a new failure callback");
        Service replacement = new Service();
        replacement.ready();
        replacement.drain();
        check(replacement.phase.equals("ready") && replacement.readyEvents == 1,
                "the previous generation's latch prevented replacement startup");

        RuntimeLifecycle disconnected = new RuntimeLifecycle();
        check(disconnected.fail(), "transport failure did not latch");
        StringBuilder shutdown = new StringBuilder();
        check(disconnected.stopFailedProcess(
                () -> shutdown.append('R'), () -> shutdown.append('F'),
                () -> shutdown.append('S'), () -> shutdown.append('K')),
                "unobserved runtime was not stopped");
        check(shutdown.toString().equals("RFSK"), "failure report did not precede service and process stop");
        check(!disconnected.acceptsFrames() && !disconnected.stopFailedProcess(
                () -> shutdown.append('R'), () -> shutdown.append('F'),
                () -> shutdown.append('S'), () -> shutdown.append('K')),
                "repeated failure could stop a replacement process");
        check(shutdown.toString().equals("RFSK"), "failed process was stopped twice");

        RuntimeLifecycle reportFailure = new RuntimeLifecycle();
        reportFailure.fail();
        StringBuilder finalizers = new StringBuilder();
        try {
            reportFailure.stopFailedProcess(() -> { finalizers.append('R'); throw new IllegalStateException("report"); },
                    () -> { finalizers.append('F'); throw new IllegalStateException("foreground"); },
                    () -> { finalizers.append('S'); throw new IllegalStateException("service"); },
                    () -> finalizers.append('K'));
            throw new AssertionError("Expected report failure");
        } catch (IllegalStateException expected) {
            check(finalizers.toString().equals("RFSK"), "a failed cleanup step left Node running");
            check(!reportFailure.acceptsFrames(), "cleanup error reopened a failed transport");
        }
        RuntimeLifecycle alreadyStopped = new RuntimeLifecycle();
        alreadyStopped.fail();
        alreadyStopped.close();
        check(!alreadyStopped.stopFailedProcess(
                () -> shutdown.append('R'), () -> shutdown.append('F'),
                () -> shutdown.append('S'), () -> shutdown.append('K')),
                "deliberate teardown was mistaken for an unobserved runtime");

        RuntimeLifecycle simultaneous = new RuntimeLifecycle();
        AtomicInteger failures = new AtomicInteger();
        CountDownLatch start = new CountDownLatch(1);
        Thread[] workers = new Thread[2];
        for (int i = 0; i < workers.length; i++) {
            workers[i] = new Thread(() -> {
                try { start.await(); }
                catch (InterruptedException error) { Thread.currentThread().interrupt(); return; }
                if (simultaneous.fail()) failures.incrementAndGet();
            });
            workers[i].start();
        }
        start.countDown();
        for (Thread worker : workers) {
            worker.join(5000);
            check(!worker.isAlive(), "failure reporter did not settle");
        }
        check(failures.get() == 1 && simultaneous.failed(), "concurrent Node exit and IPC EOF both won termination");
        System.out.println("RuntimeLifecycle: " + checks + " checks passed (late ready, queued work, fail-closed stop, replacement, concurrent failure)");
    }
}
