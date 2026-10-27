package com.minnnng.dsh_android;

import android.app.Application;
import android.app.Instrumentation;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.os.Bundle;
import android.os.IBinder;
import android.os.Process;
import org.json.JSONObject;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;

/** Shell-started test-UID carrier only; it grants no documents and never reports SAF acceptance. */
public final class PtcSafBootstrapInstrumentation extends Instrumentation {
    private Bundle arguments;
    @Override public void onCreate(Bundle values) {
        super.onCreate(values);
        arguments = values == null ? new Bundle() : new Bundle(values);
        start();
    }
    @Override public void onStart() {
        Bundle report = new Bundle();
        Context context = getTargetContext().getApplicationContext();
        CompletableFuture<IBinder> connected = new CompletableFuture<>();
        CompletableFuture<Void> lost = new CompletableFuture<>();
        ComponentName component = new ComponentName(context, PtcSafAcceptanceControlService.class);
        ServiceConnection connection = new ServiceConnection() {
            private void failed(String reason) {
                IllegalStateException error = new IllegalStateException(reason);
                connected.completeExceptionally(error);
                lost.completeExceptionally(error);
            }
            @Override public void onServiceConnected(ComponentName name, IBinder binder) {
                if (!component.equals(name) || !binder.isBinderAlive()) failed("Unexpected or dead SAF control service");
                else connected.complete(binder);
            }
            @Override public void onServiceDisconnected(ComponentName name) { failed("SAF bootstrap service disconnected"); }
            @Override public void onBindingDied(ComponentName name) { failed("SAF bootstrap binding died"); }
            @Override public void onNullBinding(ComponentName name) { failed("SAF bootstrap binding rejected"); }
        };
        boolean bound = false;
        try {
            String token = arguments.getString("token");
            PtcSafAcceptanceProvider.requireCase(token);
            long duration = Long.parseLong(arguments.getString("leaseMillis", "300000"));
            if (duration < 60000 || duration > 600000) throw new IllegalArgumentException("Invalid bootstrap lease duration");
            String expectedPackage = PtcSafAcceptanceProvider.TARGET + ".test";
            int appUid = context.getPackageManager().getApplicationInfo(PtcSafAcceptanceProvider.TARGET, 0).uid;
            if (!expectedPackage.equals(context.getPackageName()) || !expectedPackage.equals(Application.getProcessName())
                    || Process.myUid() != context.getApplicationInfo().uid || Process.myUid() == appUid)
                throw new IllegalStateException("Bootstrap must run only in the independent test UID");
            bound = context.bindService(new Intent().setComponent(component)
                    .setAction(PtcSafAcceptanceControlService.ACTION_PREFIX + token).putExtra("caseId", token),
                    connection, Context.BIND_AUTO_CREATE);
            if (!bound) throw new IllegalStateException("Test-UID self-binding was refused");
            connected.get(20, TimeUnit.SECONDS);
            JSONObject ready = new JSONObject().put("schema", 1).put("token", token)
                    .put("packageName", expectedPackage).put("pid", Process.myPid()).put("uid", Process.myUid())
                    .put("appUid", appUid).put("serviceBound", true).put("leaseMillis", duration);
            Bundle status = new Bundle();
            status.putString("safBootstrapReady", ready.toString());
            sendStatus(1, status);
            // The host owns deliberate termination after its main test and must verify UID/PID disappearance.
            lost.get(duration, TimeUnit.MILLISECONDS);
            throw new IllegalStateException("Bootstrap ended without host retirement");
        } catch (Throwable failure) {
            String text = failure.getClass().getSimpleName() + ": " + failure.getMessage();
            report.putString("bootstrapFailure", text.substring(0, Math.min(text.length(), 1000)));
        } finally {
            if (bound) {
                try { context.unbindService(connection); }
                catch (RuntimeException failure) { report.putString("bootstrapUnbindFailure", failure.getClass().getSimpleName()); }
            }
        }
        // Ready is not a successful test result; expiry or a lost service must remain a failure.
        finish(0, report);
    }
}
