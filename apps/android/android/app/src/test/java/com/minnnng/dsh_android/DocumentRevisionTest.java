package com.minnnng.dsh_android;

/** Provider identity and metadata must participate in every continuation revision. */
public final class DocumentRevisionTest {
    public static void main(String[] args) {
        String first = DocumentRevision.token("content://provider/document/1", "note.txt", "text/plain", 123L, 456L);
        check(first.equals(DocumentRevision.token("content://provider/document/1", "note.txt", "text/plain", 123L, 456L)),
            "same document metadata changed revision");
        for (String changed : new String[] {
            DocumentRevision.token("content://provider/document/2", "note.txt", "text/plain", 123L, 456L),
            DocumentRevision.token("content://provider/document/1", "renamed.txt", "text/plain", 123L, 456L),
            DocumentRevision.token("content://provider/document/1", "note.txt", "text/markdown", 123L, 456L),
            DocumentRevision.token("content://provider/document/1", "note.txt", "text/plain", 124L, 456L),
            DocumentRevision.token("content://provider/document/1", "note.txt", "text/plain", 123L, 457L),
            DocumentRevision.token("content://provider/document/1", "note.txt", "text/plain", null, 456L),
            DocumentRevision.token("content://provider/document/1", "note.txt", "text/plain", 123L, null),
        }) check(!first.equals(changed), "changed provider metadata reused revision");
        check(!DocumentRevision.token("ab", "c", null, null, null).equals(
            DocumentRevision.token("a", "bc", null, null, null)), "field boundaries collided");
        System.out.println("DocumentRevision: stable token, document replacement, metadata changes and field boundaries passed");
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
