package com.minnnng.dsh_android;

/** Pure classification of observed network capabilities for recovery acceptance. */
public final class RecoveryNetworkEvidence {
    private RecoveryNetworkEvidence() {}

    public static final class Fact {
        public final boolean known;
        public final boolean internet;
        public final boolean validated;
        public final boolean vpn;

        public Fact(boolean known, boolean internet, boolean validated, boolean vpn) {
            this.known = known;
            this.internet = internet;
            this.validated = validated;
            this.vpn = vpn;
        }
    }

    public static final class Counts {
        public final int validatedNetworks;
        public final int validatedInternetNetworks;
        public final int validatedVpnInternetNetworks;
        public final int usableUnderlyingInternetNetworks;
        public final int unvalidatedUnderlyingInternetNetworks;
        public final int unknownCapabilityNetworks;

        private Counts(int validated, int internet, int vpn, int underlying, int unvalidated, int unknown) {
            validatedNetworks = validated;
            validatedInternetNetworks = internet;
            validatedVpnInternetNetworks = vpn;
            usableUnderlyingInternetNetworks = underlying;
            unvalidatedUnderlyingInternetNetworks = unvalidated;
            unknownCapabilityNetworks = unknown;
        }
    }

    /** Count all transports, including Ethernet or unknown future transports; never infer absence from missing capabilities. */
    public static Counts classify(Fact[] facts) {
        if (facts == null || facts.length > 64) throw new IllegalArgumentException("Invalid network inventory size");
        int validated = 0, internet = 0, vpn = 0, underlying = 0, unvalidated = 0, unknown = 0;
        for (Fact fact : facts) {
            if (fact == null) throw new IllegalArgumentException("Missing network fact");
            if (!fact.known) { unknown++; continue; }
            if (fact.validated) validated++;
            if (fact.internet && fact.validated) {
                internet++;
                if (fact.vpn) vpn++;
                else underlying++;
            }
            if (fact.internet && !fact.validated && !fact.vpn) unvalidated++;
        }
        return new Counts(validated, internet, vpn, underlying, unvalidated, unknown);
    }
}
