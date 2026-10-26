package com.minnnng.dsh_android;

import java.util.Objects;

/** Pure-Java identity check shared by the Android DNS adapter and host acceptance tests. */
final class DeadlineNetworkGate {
    private DeadlineNetworkGate() {}

    static boolean permits(Object selected, Object currentDefault, Object processBound,
                           boolean internet, boolean validated) {
        return selected != null && Objects.equals(selected, currentDefault)
                && (processBound == null || Objects.equals(selected, processBound))
                && internet && validated;
    }
}
