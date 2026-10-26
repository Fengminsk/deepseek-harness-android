package com.minnnng.dsh_android;

/** Native launch route checks: both network stacks and subprocesses receive one route. */
public final class NetworkProxyPolicyTest {
    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
    public static void main(String[] args) {
        check(java.util.Set.of(args).equals(java.util.Set.copyOf(NetworkProxyPolicy.supportedTools())),
            "supported proxy launchers and Android package visibility differ");
        for (int port : new int[] {0, -1, 65536}) {
            try { NetworkProxyPolicy.validate("local", port); throw new AssertionError("invalid port accepted"); }
            catch (IllegalArgumentException expected) { }
        }
        try { NetworkProxyPolicy.validate("socks", 7890); throw new AssertionError("unsupported proxy accepted"); }
        catch (IllegalArgumentException expected) { }
        String url = NetworkProxyPolicy.localUrl(7890);
        check(url.equals("http://127.0.0.1:7890"), "local route escaped the device");
        var manual = NetworkProxyPolicy.environment(url);
        for (String key : new String[] {"HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy"})
            check(manual.get(key).equals(url), "HTTP and HTTPS did not share the selected proxy");
        check(manual.get("ALL_PROXY").isEmpty() && manual.get("all_proxy").isEmpty(), "inherited catch-all route was retained");
        check(manual.get("NO_PROXY").equals("localhost,127.0.0.1,::1"), "App loopback IPC was sent to the proxy");
        var system = NetworkProxyPolicy.environment(null);
        for (String key : new String[] {"HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy"})
            check(system.get(key).isEmpty(), "phone network mode retained an App HTTP proxy");
        System.out.println("Network proxy launch policy: package visibility, local HTTP/HTTPS, loopback bypass, phone network, invalid inputs passed");
    }
}
