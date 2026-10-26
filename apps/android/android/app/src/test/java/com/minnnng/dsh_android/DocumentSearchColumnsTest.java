package com.minnnng.dsh_android;

import java.io.IOException;

/** Provider metadata contract without a device or an Android Cursor stub. */
public final class DocumentSearchColumnsTest {
    private static final int VIRTUAL = 1 << 9;

    public static void main(String[] args) throws Exception {
        Object[] root = {"text/plain", 17L, "notes.txt", 200L};
        DocumentSearchColumns rootColumns = new DocumentSearchColumns(
            new String[]{"mime_type", "_size", "_display_name", "last_modified"}, false, VIRTUAL);
        DocumentSearchColumns.Row rootRow = rootColumns.read(new Cells(root));
        equal(rootRow.documentId, null);
        equal(rootRow.name, "notes.txt");
        equal(rootRow.mime, "text/plain");
        equal(rootRow.size, 17L);
        equal(rootRow.modified, 200L);
        equal(rootRow.virtual, false);

        Object[] child = {VIRTUAL, "primary:work/notes.txt", "text/plain", "notes.txt", null};
        DocumentSearchColumns childColumns = new DocumentSearchColumns(
            new String[]{"flags", "document_id", "mime_type", "_display_name", "_size"}, true, VIRTUAL);
        DocumentSearchColumns.Row childRow = childColumns.read(new Cells(child));
        equal(childRow.documentId, "primary:work/notes.txt");
        equal(childRow.name, "notes.txt");
        equal(childRow.size, null);
        equal(childRow.modified, null);
        equal(childRow.virtual, true);

        child[1] = null;
        rejects(() -> childColumns.read(new Cells(child)), "文档标识");
        rejects(() -> new DocumentSearchColumns(new String[]{"document_id", "_display_name"}, true, VIRTUAL),
            "mime_type");
        Object[] noMime = {"primary:work/notes.txt", "notes.txt", null};
        DocumentSearchColumns required = new DocumentSearchColumns(
            new String[]{"document_id", "_display_name", "mime_type"}, true, VIRTUAL);
        rejects(() -> required.read(new Cells(noMime)), "名称或类型");

        Object[] unknownSize = {"primary:work/notes.txt", "notes.txt", "text/plain", -1L};
        DocumentSearchColumns sized = new DocumentSearchColumns(
            new String[]{"document_id", "_display_name", "mime_type", "_size"}, true, VIRTUAL);
        equal(sized.read(new Cells(unknownSize)).size, null);
        System.out.println("DocumentSearchColumnsTest passed");
    }

    private interface Action { void run() throws IOException; }
    private static void rejects(Action action, String message) throws Exception {
        try { action.run(); throw new AssertionError("Expected provider metadata rejection"); }
        catch (IOException expected) {
            if (!expected.getMessage().contains(message)) throw expected;
        }
    }
    private static void equal(Object actual, Object expected) {
        if (actual == null ? expected != null : !actual.equals(expected)) {
            throw new AssertionError("Expected " + expected + ", got " + actual);
        }
    }
    private static final class Cells implements DocumentSearchColumns.Values {
        private final Object[] data;
        Cells(Object[] data) { this.data = data; }
        public boolean isNull(int index) { return data[index] == null; }
        public String string(int index) { return (String) data[index]; }
        public long longValue(int index) { return ((Number) data[index]).longValue(); }
        public int intValue(int index) { return ((Number) data[index]).intValue(); }
    }
}
