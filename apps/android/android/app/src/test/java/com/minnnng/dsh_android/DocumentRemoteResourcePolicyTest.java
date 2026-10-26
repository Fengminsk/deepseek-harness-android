package com.minnnng.dsh_android;

import java.net.URI;

/** Host-only preflight checks; this test makes no network request. */
public final class DocumentRemoteResourcePolicyTest {
    private static int assertions;
    private static void check(boolean value, String name) {
        assertions++;
        if (!value) throw new AssertionError(name);
    }

    public static void main(String[] args) {
        for (String invalid : new String[]{
                "http://public.example/a", "https://localhost/a", "https://127.0.0.1/a",
                "https://[::1]/a", "https://user@public.example/a",
                "https://appassets.androidplatform.net/document/index.html",
                "https://public.example/a#fragment", "file:///data/private", "https://single/a",
                "https://public.example:0/a", "https://public.example./a"}) {
            check(DocumentRemoteResourcePolicy.candidate(invalid, "GET", false) == null, "reject URL " + invalid);
        }
        URI start = DocumentRemoteResourcePolicy.candidate("https://public.example/start?q=1", "GET", false);
        check(start != null, "HTTPS syntax candidate");
        check(DocumentRemoteResourcePolicy.candidate("https://public.example/a", "POST", false) == null, "reject POST");
        check(DocumentRemoteResourcePolicy.candidate("https://public.example/a", "GET", true) == null, "reject main frame");
        check(DocumentRemoteResourcePolicy.redirect(start, "/image.png", 0).toString()
                .equals("https://public.example/image.png"), "same-host redirect candidate");
        check(DocumentRemoteResourcePolicy.redirect(start, "https://other.example/image.png", 3) != null,
                "last redirect candidate");
        check(DocumentRemoteResourcePolicy.redirect(start, "https://other.example/image.png", 4) == null,
                "redirect budget");
        for (String invalid : new String[]{"http://public.example/a", "https://127.0.0.1/a",
                "https://appassets.androidplatform.net/document/index.html", "file:///private", "//localhost/a"}) {
            check(DocumentRemoteResourcePolicy.redirect(start, invalid, 0) == null,
                    "reject redirected URL " + invalid);
        }
        check(DocumentRemoteResourcePolicy.MAX_RESOURCE_BYTES == 4 * 1024 * 1024, "resource cap documented");
        System.out.println("Document remote preflight: " + assertions + " assertions passed; transport remains disabled");
    }
}
