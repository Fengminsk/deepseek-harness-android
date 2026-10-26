package com.minnnng.dsh_android;

import android.content.Context;
import java.io.IOException;
import java.util.Objects;

/** Constructs the Linux guest HTTPS dispatcher with the Agent process's real Android providers. */
final class AndroidLinuxGuestHttpsDispatch {
    private AndroidLinuxGuestHttpsDispatch() { }

    static LinuxGuestHttpsDispatch open(Context context, LinuxGuestSandboxPolicy policy,
                                        LinuxGuestBrokerWire wire,
                                        IsolatedExecutionPolicyOwner.Lease lease)
            throws IOException {
        Context app = Objects.requireNonNull(context).getApplicationContext();
        return new LinuxGuestHttpsDispatch(policy, wire, lease,
                AndroidNetworkJournal.open(app), new AndroidDeadlineResolver(app),
                new IsolatedNetworkBroker.PinnedTlsTransport(1536));
    }
}
