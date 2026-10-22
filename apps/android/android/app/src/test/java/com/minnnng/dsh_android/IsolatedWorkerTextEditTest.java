package com.minnnng.dsh_android;

import java.io.IOException;

public final class IsolatedWorkerTextEditTest {
    public static void main(String[] args) throws Exception {
        var edit = new IsolatedWorkerTextEdit.Spec("世界", "worker", 2);
        check(IsolatedWorkerTextEdit.replace("你好世界；世界！", edit).equals("你好worker；worker！"),
            "worker did not apply exact literal replacements");
        check(IsolatedWorkerTextEdit.replace("untouched", edit).equals("untouched"), "no-match changed content");
        reject(() -> IsolatedWorkerTextEdit.replace("世界世界世界", edit), "replacement count");
        reject(() -> IsolatedWorkerTextEdit.replace("a".repeat(4097),
            new IsolatedWorkerTextEdit.Spec("a", "", 4096)), "excess occurrences");
        reject(() -> IsolatedWorkerTextEdit.replace("a" + "z".repeat(IsolatedWorkerInput.MAX_TEXT_BYTES - 1),
            new IsolatedWorkerTextEdit.Spec("a", "aa", 1)),
            "expanding output");
        var exact = new IsolatedWorkerTextEdit.Spec("x", "y", 1);
        check(IsolatedWorkerTextEdit.replace("x" + "z".repeat(IsolatedWorkerInput.MAX_TEXT_BYTES - 1), exact)
            .length() == IsolatedWorkerInput.MAX_TEXT_BYTES, "exact output limit");
        invalid(() -> new IsolatedWorkerTextEdit.Spec("", "x", 1), "empty needle");
        invalid(() -> new IsolatedWorkerTextEdit.Spec("x", "y", 0), "zero replacements");
        invalid(() -> new IsolatedWorkerTextEdit.Spec("x", "y", 4097), "unbounded replacements");
        invalid(() -> new IsolatedWorkerTextEdit.Spec("x".repeat(4097), "y", 1), "large needle");
        invalid(() -> new IsolatedWorkerTextEdit.Spec("x", "y".repeat(4097), 1), "large replacement");
        invalid(() -> new IsolatedWorkerTextEdit.Spec("x", "\ud800", 1), "malformed replacement");
        Thread.currentThread().interrupt();
        try { reject(() -> IsolatedWorkerTextEdit.replace("x", exact), "interrupted edit"); }
        finally { Thread.interrupted(); }
        System.out.println("IsolatedWorkerTextEdit: literal edit, UTF-8, bounds and interruption passed");
    }

    private interface Checked { void run() throws Exception; }

    private static void reject(Checked action, String label) throws Exception {
        try { action.run(); }
        catch (IOException expected) { return; }
        throw new AssertionError("Accepted " + label);
    }

    private static void invalid(Checked action, String label) throws Exception {
        try { action.run(); }
        catch (IllegalArgumentException expected) { return; }
        throw new AssertionError("Accepted " + label);
    }

    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
}
