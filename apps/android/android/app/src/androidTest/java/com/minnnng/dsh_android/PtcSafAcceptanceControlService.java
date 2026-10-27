package com.minnnng.dsh_android;

import android.app.Service;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.IBinder;
import android.os.Message;
import android.os.Messenger;
import android.os.Process;
import android.os.RemoteException;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

/** Signature-protected bound control in the test UID; no foreground service or display is started. */
public final class PtcSafAcceptanceControlService extends Service {
    public static final String ACTION_PREFIX = PtcSafAcceptanceProvider.TARGET + ".acceptance.saf.control.";
    private final Set<String> boundCases = ConcurrentHashMap.newKeySet();
    private HandlerThread worker;
    private int targetUid;

    @Override public void onCreate() {
        super.onCreate();
        try { targetUid = getPackageManager().getApplicationInfo(PtcSafAcceptanceProvider.TARGET, 0).uid; }
        catch (android.content.pm.PackageManager.NameNotFoundException failure) { throw new IllegalStateException(failure); }
        if (targetUid == Process.myUid()) throw new IllegalStateException("SAF fixture requires an independent test UID");
        worker = new HandlerThread("ptc-saf-control");
        worker.start();
    }
    @Override public IBinder onBind(Intent intent) {
        String caseId = intent.getStringExtra("caseId");
        PtcSafAcceptanceProvider.requireCase(caseId);
        if (!(ACTION_PREFIX + caseId).equals(intent.getAction()) || boundCases.size() >= 4 || !boundCases.add(caseId)) return null;
        return new Messenger(new Handler(worker.getLooper(), message -> { handle(message, caseId); return true; })).getBinder();
    }
    private void handle(Message message, String boundCase) {
        if (message.sendingUid != targetUid || message.replyTo == null) return;
        Bundle response = new Bundle();
        response.putInt("schema", 1);
        response.putString("caseId", boundCase);
        response.putInt("controlUid", Process.myUid());
        response.putInt("controlPid", Process.myPid());
        boolean passed = false;
        try {
            Bundle data = message.getData();
            String method = data.getString("method");
            response.putString("method", method);
            requireRequest(message.sendingUid, targetUid, boundCase, data.getString("caseId"), method,
                    boundCases.contains(boundCase), message.what, message.arg1, data.size());
            Bundle result = getContentResolver().call(Uri.parse(PtcSafAcceptanceProvider.CONTROL_URI), method, boundCase, null);
            if (result == null) throw new IllegalStateException("Provider returned no control result");
            response.putBundle("result", result);
            passed = true;
        } catch (RuntimeException failure) {
            String text = failure.getClass().getSimpleName() + ": " + failure.getMessage();
            response.putString("failure", text.substring(0, Math.min(text.length(), 512)));
        }
        Message reply = Message.obtain();
        reply.what = passed ? 1 : 0;
        reply.arg1 = message.arg1;
        reply.setData(response);
        try { message.replyTo.send(reply); } catch (RemoteException ignored) { /* The caller cannot accept this result. */ }
    }
    static void requireRequest(int callerUid, int targetUid, String boundCase, String requestedCase,
            String method, boolean active, int kind, int requestId, int fieldCount) {
        if (callerUid != targetUid || targetUid < 0) throw new SecurityException("Control caller is not the target App UID");
        PtcSafAcceptanceProvider.requireCase(boundCase);
        if (!active || kind != 1 || requestId <= 0 || fieldCount != 2 || !boundCase.equals(requestedCase))
            throw new IllegalArgumentException("Invalid or released control request");
        PtcSafAcceptanceProvider.requireMethod(method);
    }
    @Override public boolean onUnbind(Intent intent) {
        boundCases.remove(intent.getStringExtra("caseId"));
        return false;
    }
    @Override public void onDestroy() {
        boundCases.clear();
        worker.quitSafely();
        try { worker.join(5000); }
        catch (InterruptedException failure) { Thread.currentThread().interrupt(); throw new IllegalStateException(failure); }
        if (worker.isAlive()) throw new IllegalStateException("SAF control worker did not retire");
        super.onDestroy();
    }
}
