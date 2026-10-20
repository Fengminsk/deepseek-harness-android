package com.minnnng.dsh_android;

/** The desktop's exact focus-only protocol, never an authorization callback. */
public final class AccountReturnLink {
    private AccountReturnLink() {}

    /** Do not normalize or decode: alternate authorities, parameters and paths are not accepted. */
    public static boolean isReturnUri(String value) {
        return "dsh://open".equals(value) || "dsh://open/".equals(value);
    }

    public static boolean accepts(String action, String value) {
        return "android.intent.action.VIEW".equals(action) && isReturnUri(value);
    }
}
