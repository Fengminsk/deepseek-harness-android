package com.minnnng.dsh_android;

/** Host checks exercise real lease ownership without a device or external Agent task. */
public final class OverlayLeaseTest {
    private static int assertions;

    private static final class Window implements OverlayLease.WindowHost {
        int adds, removes;
        boolean rejectAdd, rejectRemove;
        boolean rejectRemoveOnce;
        OverlayLease.Attachment observer;
        @Override public void attach(OverlayLease.Attachment value) throws Exception {
            adds++;
            observer = value;
            if (rejectAdd) throw new Exception("Rejected");
        }
        @Override public void remove() throws Exception {
            removes++;
            if (rejectRemoveOnce) {
                rejectRemoveOnce = false;
                throw new Exception("Transient removal rejection");
            }
            if (rejectRemove) throw new Exception("Rejected removal");
            if (observer != null) observer.detached();
        }
    }

    public static void main(String[] args) {
        Window window = new Window();
        OverlayLease lease = new OverlayLease(window);
        lease.update(false, true, true);
        check(window.adds == 0 && lease.status().equals("disabled"), "opt-in ignored");
        lease.update(true, false, true);
        check(window.adds == 0 && lease.status().equals("permission-required"), "permission ignored");
        lease.update(true, true, false);
        check(window.adds == 0 && lease.status().equals("idle"), "idle created window");
        lease.update(true, true, true);
        check(window.adds == 1 && lease.status().equals("attaching") && !lease.attached(), "add request claimed attachment");
        window.observer.attached();
        check(lease.attached() && lease.status().equals("attached"), "actual attachment missing");
        lease.update(true, true, true);
        check(window.adds == 1, "heartbeat duplicated window");
        lease.retry();
        check(window.adds == 1 && window.removes == 0, "healthy retry replaced window");
        lease.update(true, false, true);
        check(window.removes == 1 && !lease.attached() && lease.status().equals("permission-required"), "revocation retained window");
        lease.update(true, true, true);
        window.observer.attached();
        check(window.adds == 2 && lease.attached(), "reauthorization did not recover");
        lease.update(true, true, false);
        check(window.removes == 2 && !lease.attached(), "task completion retained window");
        lease.update(true, true, true);
        OverlayLease.Attachment old = window.observer;
        lease.update(false, true, true);
        old.attached();
        check(!lease.attached() && lease.status().equals("disabled"), "late attachment revived disabled window");
        lease.update(true, true, true);
        OverlayLease.Attachment newer = window.observer;
        old.detached();
        old.attached();
        check(!lease.attached() && lease.status().equals("attaching"), "old observer changed new window state");
        newer.attached();
        check(lease.attached(), "current observer was fenced with old observer");

        // Revocation during an asynchronous add must not leave a transparent window.
        lease.update(true, false, true);
        newer.attached();
        check(!lease.attached() && lease.status().equals("permission-required"), "late add survived revocation");

        window = new Window();
        lease = new OverlayLease(window);
        window.rejectAdd = true;
        lease.update(true, true, true);
        check(window.adds == 1 && window.removes == 1 && lease.status().equals("failed"), "add rejection not cleaned");
        lease.update(true, true, true);
        lease.update(true, true, true);
        check(window.adds == 1, "add rejection caused automatic retry loop");
        window.rejectAdd = false;
        lease.retry();
        window.observer.attached();
        check(window.adds == 2 && lease.attached(), "explicit retry failed");
        window.observer.detached();
        check(!lease.attached() && lease.status().equals("failed"), "system removal retained active claim");
        lease.update(true, true, true);
        check(window.adds == 2, "system removal caused automatic retry");
        lease.retry();
        window.observer.attached();
        check(window.adds == 3 && lease.attached(), "detached window could not retry");
        window.rejectRemove = true;
        lease.update(false, true, false);
        check(lease.attached() && lease.status().equals("failed") && lease.failure().equals("remove-failed"), "unconfirmed removal reported success");
        window.rejectRemove = false;
        lease.update(false, true, false);
        check(!lease.attached() && lease.status().equals("disabled"), "removal did not settle");
        lease.update(true, true, true);
        window.observer.attached();
        old = window.observer;
        lease.close();
        check(!lease.attached() && lease.status().equals("stopped"), "close retained window");
        int adds = window.adds;
        lease.update(true, true, true);
        lease.retry();
        old.attached();
        check(window.adds == adds && !lease.attached(), "closed owner revived");

        // A failed add followed by an unconfirmed remove must not create duplicates.
        window = new Window();
        lease = new OverlayLease(window);
        window.rejectAdd = true;
        window.rejectRemove = true;
        lease.update(true, true, true);
        check(window.adds == 1 && window.removes == 1 &&
                "remove-failed".equals(lease.failure()), "uncertain cleanup lost ownership");
        lease.retry();
        check(window.adds == 1 && window.removes == 2, "retry added over uncertain owner");
        window.rejectRemove = false;
        window.rejectAdd = false;
        lease.retry();
        window.observer.attached();
        check(window.adds == 2 && lease.attached(), "cleanup recovery failed");

        window.rejectRemoveOnce = true;
        lease.close();
        check(window.removes == 5 && !lease.attached() && lease.status().equals("stopped"),
                "close did not retry a transient remove failure");

        // Only verified work qualifies, independently of the CPU preference.
        BackgroundTaskState work = new BackgroundTaskState(false);
        work.phase("ready");
        work.accept("test", 1, 0, 5, 3, 2, 0, 0);
        check(!work.hasActiveWork(), "queued/waiting/failed considered running");
        work.accept("test", 2, 1, 0, 0, 0, 0, 0);
        check(work.hasActiveWork() && !work.shouldHoldWakeLock(), "overlay coupled to CPU choice");
        work.stale();
        check(!work.hasActiveWork(), "stale work retained overlay eligibility");
        work.accept("test", 3, 0, 0, 0, 0, 1, 0);
        check(work.hasActiveWork(), "background job not protected");
        work.accept("test", 4, 0, 0, 0, 0, 0, 1);
        check(work.hasActiveWork(), "package operation not protected");
        work.phase("restarting");
        check(!work.hasActiveWork(), "restart inherited old work");
        System.out.println("Overlay lease: " + assertions + " lifecycle assertions passed");
    }

    private static void check(boolean condition, String message) {
        assertions++;
        if (!condition) throw new AssertionError(message);
    }
}
