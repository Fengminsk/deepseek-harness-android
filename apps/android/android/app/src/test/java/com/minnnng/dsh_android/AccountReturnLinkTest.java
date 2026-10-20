package com.minnnng.dsh_android;

/** Exact-match regression for the exported focus-only entry point. No Android runtime required. */
public final class AccountReturnLinkTest {
    public static void main(String[] args) {
        String view = "android.intent.action.VIEW";
        for (String accepted : new String[] {"dsh://open", "dsh://open/"}) {
            check(AccountReturnLink.isReturnUri(accepted), "Expected exact return URI");
            check(AccountReturnLink.accepts(view, accepted), "Expected VIEW return action");
            check(!AccountReturnLink.accepts(null, accepted), "Missing action must be rejected");
            check(!AccountReturnLink.accepts("android.intent.action.MAIN", accepted), "MAIN is not a return");
            check(!AccountReturnLink.accepts("android.intent.action.SEND", accepted), "SEND is not a return");
        }
        String[] rejected = {
            null, "", " dsh://open", "dsh://open ", "dsh://open\n", "dsh://open\u0000",
            "DSH://open", "dsh://OPEN", "https://open", "dsh:open", "dsh:/open",
            "dsh:///open", "dsh://open//", "dsh://open/account", "dsh://open/.",
            "dsh://open?", "dsh://open?token=fixture", "dsh://open/?code=fixture",
            "dsh://open#", "dsh://open#fixture", "dsh://open/#fixture",
            "dsh://user@open", "dsh://user:password@open", "dsh://open@other",
            "dsh://open:80", "dsh://open:", "dsh://open:0/", "dsh://open.example",
            "dsh://open./", "dsh://%6fpen", "dsh://open%2f", "dsh://open/%2e",
            "dsh://open\\", "dsh://оpen", "intent://open/#Intent;scheme=dsh;end",
        };
        for (String value : rejected) {
            check(!AccountReturnLink.isReturnUri(value), "Unexpected return URI accepted");
            check(!AccountReturnLink.accepts(view, value), "Unexpected return intent accepted");
        }
        System.out.println("AccountReturnLink: exact two URI forms accepted; "
                + rejected.length + " malformed, credential-bearing or alternate forms rejected");
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
