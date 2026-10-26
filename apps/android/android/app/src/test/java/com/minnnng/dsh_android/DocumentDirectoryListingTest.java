package com.minnnng.dsh_android;

import java.io.IOException;
import java.util.Collections;

public final class DocumentDirectoryListingTest {
    public static void main(String[] args) throws Exception {
        DocumentDirectoryListing listing = new DocumentDirectoryListing("project");
        listing.add("provider:one", "photo.jpg", "image/jpeg", 12L);
        listing.add("provider:two", "notes.txt", "text/plain", -1L);
        assertTrue(listing.entries().size() == 2, "valid children are returned");
        assertTrue(listing.entries().get(0).name.equals("notes.txt"), "results have stable name order");
        assertTrue(listing.entries().get(0).size == null, "negative provider size means unknown");
        assertTrue(listing.entries().get(1).size == 12L, "known size is retained");
        expect(IOException.class, () -> listing.add("provider:three", "photo.jpg", "image/jpeg", 5L),
                "duplicate display names cannot be opened unambiguously");
        expect(IOException.class, () -> listing.add("provider:one", "other.jpg", "image/jpeg", 5L),
                "duplicate document IDs indicate an inconsistent provider listing");

        for (String name : new String[]{"", ".", "..", "folder/file", "folder\\file"}) {
            DocumentDirectoryListing invalid = new DocumentDirectoryListing("");
            expect(IOException.class, () -> invalid.add("id", name, "text/plain", null),
                    "a listed name must be addressable through the same path contract: " + name);
        }
        DocumentDirectoryListing incomplete = new DocumentDirectoryListing("");
        expect(IOException.class, () -> incomplete.add(null, "name", "text/plain", null),
                "provider document ID is required");
        expect(IOException.class, () -> incomplete.add("id", "name", null, null),
                "provider MIME type is required");

        String maxDepth = String.join("/", Collections.nCopies(DocumentTraversalBudget.MAX_DEPTH, "x"));
        DocumentDirectoryListing deep = new DocumentDirectoryListing(maxDepth);
        expect(IOException.class, () -> deep.add("id", "child", "text/plain", null),
                "an item beyond the traversal depth must not be advertised as openable");
        DocumentDirectoryListing longPath = new DocumentDirectoryListing("a".repeat(4094));
        expect(IOException.class, () -> longPath.add("id", "child", "text/plain", null),
                "an item beyond the path length must not be advertised as openable");

        DocumentDirectoryListing bounded = new DocumentDirectoryListing("");
        for (int index = 0; index < DocumentTraversalBudget.MAX_CHILDREN; index++) {
            bounded.add("id:" + index, "name-" + index, "text/plain", null);
        }
        expect(IOException.class, () -> bounded.add("extra", "extra", "text/plain", null),
                "provider enumeration must stop at the shared SAF row budget");
        assertTrue(bounded.entries().size() == DocumentTraversalBudget.MAX_CHILDREN,
                "a failed over-limit addition cannot be exposed");
        System.out.println("DocumentDirectoryListingTest passed");
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
