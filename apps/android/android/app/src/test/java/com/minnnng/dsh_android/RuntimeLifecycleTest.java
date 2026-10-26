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
        check(disconnected.processExitRequired(),
                "failed Service teardown could release the runtime lease before process exit");
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

        RuntimeLifecycle timedOut = new RuntimeLifecycle();
        StringBuilder timeoutSteps = new StringBuilder();
        check(timedOut.stopTimedOutProcess(() -> timeoutSteps.append('F'),
                () -> timeoutSteps.append('S'), () -> timeoutSteps.append('R'),
                () -> timeoutSteps.append('K')), "platform timeout was not claimed");
        check(timeoutSteps.toString().equals("FSRK"),
                "timeout performed disk or IPC reporting before stopping the service");
        check(timedOut.processExitRequired(),
                "timed-out Service teardown could release the runtime lease before process exit");
        check(!timedOut.acceptsFrames() && !timedOut.stopTimedOutProcess(
                () -> timeoutSteps.append('F'), () -> timeoutSteps.append('S'),
                () -> timeoutSteps.append('R'), () -> timeoutSteps.append('K')),
                "duplicate timeout stopped or reported the same process twice");
        check(timeoutSteps.toString().equals("FSRK"), "duplicate timeout ran cleanup callbacks");
        check(!timedOut.closeUnexpected(),
                "onDestroy after timeout replaced the specific timeout receipt with runtime-lost");
        RuntimeLifecycle timedOutDuringFailure = new RuntimeLifecycle();
        check(timedOutDuringFailure.fail(), "failure was not queued before timeout");
        check(timedOutDuringFailure.stopTimedOutProcess(() -> {}, () -> {}, () -> {}, () -> {}),
                "timeout did not supersede a queued failure callback");
        check(!timedOutDuringFailure.stopFailedProcess(() -> {}, () -> {}, () -> {}, () -> {}),
                "queued failure stopped a timed-out service a second time");
        RuntimeLifecycle plannedTimeout = new RuntimeLifecycle();
        plannedTimeout.close();
        check(!plannedTimeout.stopTimedOutProcess(() -> {}, () -> {}, () -> {}, () -> {}),
                "planned restart was mistaken for a platform timeout");
        RuntimeLifecycle failedTimeoutCleanup = new RuntimeLifecycle();
        StringBuilder timeoutFinalizers = new StringBuilder();
        try {
            failedTimeoutCleanup.stopTimedOutProcess(
                    () -> { timeoutFinalizers.append('F'); throw new IllegalStateException("foreground"); },
                    () -> { timeoutFinalizers.append('S'); throw new IllegalStateException("service"); },
                    () -> { timeoutFinalizers.append('R'); throw new IllegalStateException("receipt"); },
                    () -> timeoutFinalizers.append('K'));
            throw new AssertionError("Expected timeout cleanup failure");
        } catch (IllegalStateException expected) {
            check(timeoutFinalizers.toString().equals("FSRK"),
                    "timeout cleanup error skipped service stop, receipt attempt, or process stop");
            check(!failedTimeoutCleanup.acceptsFrames(), "timeout cleanup error reopened runtime transport");
        }

        RuntimeLifecycle systemDestroy = new RuntimeLifecycle();
        check(systemDestroy.closeUnexpected(), "unplanned service destroy was not claimed");
        check(!systemDestroy.acceptsFrames() && !systemDestroy.closeUnexpected(),
                "service destroy could claim the same runtime twice");
        check(!systemDestroy.fail(), "destroyed service accepted a late Node exit");
        RuntimeLifecycle queuedFailure = new RuntimeLifecycle();
        check(queuedFailure.fail(), "Node failure did not latch before service destroy");
        check(queuedFailure.closeUnexpected(), "service destroy lost a queued failure callback");
        check(!queuedFailure.stopFailedProcess(
                () -> shutdown.append('R'), () -> shutdown.append('F'),
                () -> shutdown.append('S'), () -> shutdown.append('K')),
                "late failure callback stopped an already destroyed service again");
        RuntimeLifecycle plannedDestroy = new RuntimeLifecycle();
        plannedDestroy.close();
        check(!plannedDestroy.closeUnexpected(), "planned restart was recorded as an interruption");

        RuntimeLifecycle plannedProcessExit = new RuntimeLifecycle();
        check(plannedProcessExit.closeForProcessExit(), "active runtime could not claim a planned process exit");
        check(plannedProcessExit.processExitRequired() && !plannedProcessExit.closeUnexpected(),
                "planned process exit was mistaken for ordinary Service teardown");
        plannedProcessExit.close();
        check(plannedProcessExit.processExitRequired(),
                "Service cleanup discarded the process-exit lease obligation");

        RuntimeLifecycle failedBeforeTransition = new RuntimeLifecycle();
        check(failedBeforeTransition.fail(), "transport failure was not latched before transition");
        check(!failedBeforeTransition.closeForProcessExit(),
                "transition erased a latched runtime failure and could clear its process marker");
        check(failedBeforeTransition.stopFailedProcess(() -> {}, () -> {}, () -> {}, () -> {}),
                "failed runtime lost its interruption report owner after transition callback");
        check(!failedBeforeTransition.closeForProcessExit(),
                "transition replaced a required failed-process exit");
        RuntimeLifecycle destroyedBeforeTransition = new RuntimeLifecycle();
        check(destroyedBeforeTransition.closeUnexpected(), "unexpected teardown was not claimed");
        check(!destroyedBeforeTransition.closeForProcessExit(),
                "transition claimed a service generation that was already destroyed");

        for (int i = 0; i < 32; i++) {
            RuntimeLifecycle competingTransition = new RuntimeLifecycle();
            CountDownLatch raceStart = new CountDownLatch(1);
            AtomicInteger claims = new AtomicInteger();
            Thread failure = new Thread(() -> {
                try { raceStart.await(); }
                catch (InterruptedException error) { Thread.currentThread().interrupt(); return; }
                if (competingTransition.fail()) claims.incrementAndGet();
            });
            Thread planned = new Thread(() -> {
                try { raceStart.await(); }
                catch (InterruptedException error) { Thread.currentThread().interrupt(); return; }
                if (competingTransition.closeForProcessExit()) claims.incrementAndGet();
            });
            failure.start();
            planned.start();
            raceStart.countDown();
            failure.join(5000);
            planned.join(5000);
            check(!failure.isAlive() && !planned.isAlive() && claims.get() == 1,
                    "failure and planned exit both claimed the runtime generation");
        }

        for (int i = 0; i < 32; i++) {
            RuntimeLifecycle competingDestroy = new RuntimeLifecycle();
            check(competingDestroy.fail(), "failure did not enter terminal race");
            CountDownLatch raceStart = new CountDownLatch(1);
            AtomicInteger processStops = new AtomicInteger();
            Thread failureCallback = new Thread(() -> {
                try { raceStart.await(); }
                catch (InterruptedException error) { Thread.currentThread().interrupt(); return; }
                competingDestroy.stopFailedProcess(() -> {}, () -> {}, () -> {}, processStops::incrementAndGet);
            });
            Thread destroyCallback = new Thread(() -> {
                try { raceStart.await(); }
                catch (InterruptedException error) { Thread.currentThread().interrupt(); return; }
                if (competingDestroy.closeUnexpected()) processStops.incrementAndGet();
            });
            failureCallback.start();
            destroyCallback.start();
            raceStart.countDown();
            failureCallback.join(5000);
            destroyCallback.join(5000);
            check(!failureCallback.isAlive() && !destroyCallback.isAlive() && processStops.get() == 1,
                    "service destroy and queued failure did not choose one process-stop owner");
        }

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
