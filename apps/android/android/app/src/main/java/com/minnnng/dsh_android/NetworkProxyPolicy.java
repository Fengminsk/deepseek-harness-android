package com.minnnng.dsh_android;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Arrays;
import java.util.Collections;

/** Validated App-owned routes installed before the profile creates HTTP clients. */
public final class NetworkProxyPolicy {
    public static final String NO_PROXY = "localhost,127.0.0.1,::1";
    private NetworkProxyPolicy() {}

    /** Supported launchable tools, including clients whose VPN service is private. */
    public static List<String> supportedTools() {
        return Collections.unmodifiableList(Arrays.asList(
            "com.follow.clash", "com.github.metacubex.clash.meta", "com.v2ray.ang"));
    }

    public static void validate(String mode, int port) {
        if (!"system".equals(mode) && !"local".equals(mode))
            throw new IllegalArgumentException("请选择手机网络或本机代理");
        if (port < 1 || port > 65535)
            throw new IllegalArgumentException("代理端口须为 1–65535");
    }

    public static String localUrl(int port) {
        validate("local", port);
        return "http://127.0.0.1:" + port;
    }

    public static Map<String, String> environment(String url) {
        var result = new LinkedHashMap<String, String>();
        for (String name : new String[] {"HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy"})
            result.put(name, url == null ? "" : url);
        result.put("ALL_PROXY", "");
        result.put("all_proxy", "");
        result.put("NO_PROXY", NO_PROXY);
        result.put("no_proxy", NO_PROXY);
        return result;
    }
}
