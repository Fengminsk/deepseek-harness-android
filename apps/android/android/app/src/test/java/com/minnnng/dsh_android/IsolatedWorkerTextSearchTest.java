package com.minnnng.dsh_android;

import java.io.IOException;

public final class IsolatedWorkerTextSearchTest {
    public static void main(String[] args) throws Exception {
        var spec = new IsolatedWorkerTextSearch.Spec("目标", 2);
        var result = IsolatedWorkerTextSearch.search("第一行\n目标一 目标二\n目标三", spec);
        check(result.hits().size() == 2 && result.truncated(), "match cap must report truncation");
        check(result.hits().get(0).line() == 2 && result.hits().get(0).column() == 1,
            "first match location");
        check(result.hits().get(1).line() == 2 && result.hits().get(1).column() == 5,
            "second match location");
        check(result.hits().get(0).preview().equals("目标一 目标二"), "line preview");
        check(!IsolatedWorkerTextSearch.search("目标", spec).truncated(),
            "a result at the cap is not necessarily truncated");
        var emoji = IsolatedWorkerTextSearch.search("😀目标", spec).hits().get(0);
        check(emoji.column() == 2, "column must count Unicode code points");
        check(IsolatedWorkerTextSearch.search("none", spec).hits().isEmpty(), "no match");
        var preview = IsolatedWorkerTextSearch.search("😀".repeat(170) + "目标", spec).hits().get(0).preview();
        check(preview.codePointCount(0, preview.length()) == IsolatedWorkerTextSearch.MAX_PREVIEW_CHARS,
            "preview must not split a surrogate pair");
        check(preview.contains("目标"), "late Unicode match must appear in preview");
        var late = IsolatedWorkerTextSearch.search("x".repeat(300) + "目标" + "y".repeat(100), spec).hits().get(0);
        check(late.column() == 301 && late.preview().contains("目标"),
            "late match must keep its one-based source column and appear in preview");
        check(late.preview().codePointCount(0, late.preview().length()) == IsolatedWorkerTextSearch.MAX_PREVIEW_CHARS,
            "late match preview remains bounded");
        var wideQuery = "词".repeat(IsolatedWorkerTextSearch.MAX_PREVIEW_CHARS);
        var wide = IsolatedWorkerTextSearch.search("x".repeat(200) + wideQuery + "z".repeat(10),
            new IsolatedWorkerTextSearch.Spec(wideQuery, 1)).hits().get(0);
        check(wide.column() == 201 && wide.preview().equals(wideQuery),
            "a preview-sized match must remain whole");
        reject(() -> new IsolatedWorkerTextSearch.Spec("", 1), "empty query");
        reject(() -> new IsolatedWorkerTextSearch.Spec("x", 0), "zero matches");
        reject(() -> new IsolatedWorkerTextSearch.Spec("x", IsolatedWorkerTextSearch.MAX_MATCHES + 1), "excess matches");
        reject(() -> new IsolatedWorkerTextSearch.Spec("x".repeat(IsolatedWorkerTextSearch.MAX_QUERY_BYTES + 1), 1), "large query");
        reject(() -> new IsolatedWorkerTextSearch.Spec("\ud800", 1), "malformed query");
        rejectIO(() -> IsolatedWorkerTextSearch.search("x".repeat(IsolatedWorkerInput.MAX_TEXT_BYTES + 1),
            new IsolatedWorkerTextSearch.Spec("x", 1)), "large input");
        var current = Thread.currentThread();
        current.interrupt();
        try { rejectIO(() -> IsolatedWorkerTextSearch.search("x", new IsolatedWorkerTextSearch.Spec("x", 1)), "interruption"); }
        finally { Thread.interrupted(); }
        System.out.println("IsolatedWorkerTextSearch: location, caps, Unicode, validation and interruption passed");
    }

    private interface Checked { void run() throws Exception; }

    private static void reject(Checked action, String label) throws Exception {
        try { action.run(); } catch (IllegalArgumentException expected) { return; }
        throw new AssertionError("Accepted " + label);
    }

    private static void rejectIO(Checked action, String label) throws Exception {
        try { action.run(); } catch (IOException expected) { return; }
        throw new AssertionError("Accepted " + label);
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
