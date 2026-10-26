package com.minnnng.dsh_android;

import java.io.IOException;
import java.util.List;

public final class DocumentTraversalBudgetTest {
    public static void main(String[] args) throws Exception {
        assertTrue(DocumentTraversalBudget.segments("").isEmpty(), "grant root remains a valid path");
        assertTrue(DocumentTraversalBudget.segments("one/two").equals(List.of("one", "two")),
                "ordinary nested names remain addressable");
        String deepest = String.join("/", java.util.Collections.nCopies(DocumentTraversalBudget.MAX_DEPTH, "x"));
        assertTrue(DocumentTraversalBudget.segments(deepest).size() == DocumentTraversalBudget.MAX_DEPTH,
                "the maximum depth is admitted");
        expect(IllegalArgumentException.class, () -> DocumentTraversalBudget.segments(deepest + "/x"),
                "a deeper path must be rejected before provider traversal");
        expect(IllegalArgumentException.class, () -> DocumentTraversalBudget.segments("a".repeat(4097)),
                "an oversized path must be rejected before provider traversal");
        for (String path : List.of("/a", "a/", "a//b", "a/./b", "a/../b", "a\\b")) {
            expect(IllegalArgumentException.class, () -> DocumentTraversalBudget.segments(path),
                    "ambiguous relative path " + path);
        }

        DocumentTraversalBudget first = new DocumentTraversalBudget();
        for (int index = 0; index < DocumentTraversalBudget.MAX_CHILDREN; index++) first.nextChild();
        expect(IOException.class, first::nextChild, "the 10,001st provider row must be rejected");
        DocumentTraversalBudget second = new DocumentTraversalBudget();
        second.nextChild();
        assertTrue(DocumentTraversalBudget.segments("parent/child").size() == 2,
                "a new directory scan has its own row budget");
        System.out.println("DocumentTraversalBudgetTest passed");
    }

    private interface Throwing { void run() throws Exception; }

    private static void expect(Class<? extends Throwable> type, Throwing operation, String label) throws Exception {
        try { operation.run(); }
        catch (Throwable failure) {
            if (type.isInstance(failure)) return;
            throw new AssertionError(label, failure);
        }
        throw new AssertionError(label);
    }

    private static void assertTrue(boolean accepted, String label) {
        if (!accepted) throw new AssertionError(label);
    }
}
