package com.minnnng.dsh_android;

import android.app.Application;
import android.content.Context;
import android.os.Build;
import android.system.Os;
import android.system.OsConstants;
import java.io.IOException;
import java.nio.file.Path;

/** Constructs the network audit only in the Agent process with Android directory fsync. */
public final class AndroidNetworkJournal {
    private AndroidNetworkJournal() {}

    public static IsolatedNetworkJournal open(Context context) throws IOException {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q)
            throw new IOException("Isolated network audit requires Android 10 or newer");
        Context app = context.getApplicationContext();
        if (!Application.getProcessName().equals(app.getPackageName() + ":agent"))
            throw new IOException("Network audit belongs to the Agent process");
        return new IsolatedNetworkJournal(app.getFilesDir().toPath(),
                AndroidNetworkJournal::syncDirectory);
    }

    private static void syncDirectory(Path directory) throws IOException {
        try {
            var descriptor = Os.open(directory.toString(), OsConstants.O_RDONLY, 0);
            try {
                if (!OsConstants.S_ISDIR(Os.fstat(descriptor).st_mode))
                    throw new IOException("Network audit directory was replaced");
                Os.fsync(descriptor);
            } finally { Os.close(descriptor); }
        } catch (android.system.ErrnoException failure) {
            throw new IOException("Could not sync network audit directory", failure);
        }
    }
}
