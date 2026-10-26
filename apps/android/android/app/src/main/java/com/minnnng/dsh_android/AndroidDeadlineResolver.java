package com.minnnng.dsh_android;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.DnsResolver;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.os.Build;
import android.os.CancellationSignal;
import android.os.Looper;
import java.io.IOException;
import java.net.InetAddress;
import java.net.UnknownHostException;
import java.util.List;
import java.util.Objects;
import java.util.concurrent.SynchronousQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import java.util.concurrent.atomic.AtomicBoolean;
import javax.net.SocketFactory;

/**
 * Android API 29+ implementation of the network broker's deadline-bounded DNS contract.
 * This does not enable the broker or give an isolated process network access. API 28 fails closed.
 */
public final class AndroidDeadlineResolver implements IsolatedNetworkBroker.DeadlineResolver {
    private static final ThreadPoolExecutor QUERY_STARTER = createQueryStarter();
    private final ConnectivityManager connectivity;

    public AndroidDeadlineResolver(Context context) {
        Context app = Objects.requireNonNull(context).getApplicationContext();
        connectivity = Objects.requireNonNull(
                (ConnectivityManager) app.getSystemService(Context.CONNECTIVITY_SERVICE));
    }

    private static ThreadPoolExecutor createQueryStarter() {
        ThreadPoolExecutor pool = new ThreadPoolExecutor(1, 1, 30, TimeUnit.SECONDS,
                new SynchronousQueue<>(), task -> {
                    Thread thread = new Thread(task, "isolated-network-dns-start");
                    thread.setDaemon(true);
                    return thread;
                }, new ThreadPoolExecutor.AbortPolicy());
        pool.allowCoreThreadTimeOut(true);
        return pool;
    }

    @Override public IsolatedNetworkBroker.Resolution resolve(String host, long deadlineNanos,
            AtomicBoolean cancelled)
            throws IOException {
        Objects.requireNonNull(cancelled);
        if (cancelled.get()) throw new IOException("Network capability revoked before DNS");
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q)
            throw new IOException("Bounded DNS unavailable before Android 10");
        if (Looper.myLooper() == Looper.getMainLooper())
            throw new IOException("DNS resolution must not block the main thread");
        try {
            if (!IsolatedNetworkBroker.validatedHost(host).equals(host))
                throw new IOException("DNS host is not normalized");
        } catch (IllegalArgumentException error) {
            throw new IOException("Invalid DNS host", error);
        }
        if (deadlineNanos - System.nanoTime() <= 0)
            throw new java.net.SocketTimeoutException("DNS deadline expired");

        CancellationSignal cancellation = new CancellationSignal();
        AtomicReference<IsolatedNetworkBroker.RouteSocketFactory> selectedRoute =
                new AtomicReference<>();
        // Network selection and both ConnectivityManager Binder reads are inside the bounded
        // submission. A stuck system call can occupy at most this one starter thread.
        InetAddress[] addresses = DeadlineDnsQuery.resolve(host, deadlineNanos, QUERY_STARTER,
                cancellation::cancel, (name, callback) -> {
                    Network network = connectivity.getActiveNetwork();
                    if (!eligible(network)) throw new UnknownHostException("No validated default network");
                    // The Android factory retains this specific Network even if the default
                    // changes after DNS. Never reconstruct a socket from the process default.
                    SocketFactory factory = network.getSocketFactory();
                    selectedRoute.set(factory::createSocket);
                    DnsResolver resolver = DnsResolver.getInstance();
                    DeadlineDnsQuery.requireLiveBeforeSubmit(
                            deadlineNanos, () -> cancellation.isCanceled() || cancelled.get());
                    // Android's resolver skips lookup as well as storage for NO_CACHE_STORE.
                    // AOSP's QueryFlag IntDef does not mark bitwise combinations as flags.
                    resolver.query(network, name, DnsResolver.TYPE_A,
                            DnsResolver.FLAG_NO_CACHE_STORE,
                            Runnable::run, cancellation, new DnsResolver.Callback<List<InetAddress>>() {
                                @Override public void onAnswer(List<InetAddress> addresses, int rcode) {
                                    try {
                                        // A replaced or disconnected default network invalidates the
                                        // answer. TCP must later bind this same Network before enablement.
                                        if (!eligible(network)) {
                                            callback.failed(new UnknownHostException(
                                                    "Default network changed during DNS"));
                                        } else if (rcode != 0 || addresses == null || addresses.isEmpty()
                                                || addresses.size() > 32) {
                                            callback.failed(new UnknownHostException(
                                                    "DNS returned no bounded A records"));
                                        } else {
                                            callback.answered(addresses.toArray(new InetAddress[0]));
                                        }
                                    } catch (RuntimeException error) {
                                        callback.failed(new IOException("DNS network check failed", error));
                                    }
                                }

                                @Override public void onError(DnsResolver.DnsException error) {
                                    callback.failed(new UnknownHostException("DNS query failed: "
                                            + error.code));
                                }
                            });
                }, cancelled::get);
        if (cancelled.get()) throw new IOException("Network capability revoked during DNS");
        IsolatedNetworkBroker.RouteSocketFactory route = selectedRoute.get();
        if (route == null) throw new IOException("DNS completed without a network route");
        return new IsolatedNetworkBroker.Resolution(addresses, route);
    }

    private boolean eligible(Network network) {
        if (network == null) return false;
        Network active = connectivity.getActiveNetwork();
        Network bound = connectivity.getBoundNetworkForProcess();
        NetworkCapabilities capabilities = connectivity.getNetworkCapabilities(network);
        return DeadlineNetworkGate.permits(network, active, bound,
                capabilities != null
                        && capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET),
                capabilities != null
                        && capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED));
    }
}
