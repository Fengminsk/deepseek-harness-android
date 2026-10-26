package com.minnnng.dsh_android;

import java.io.IOException;

public final class DocumentColumnsTest {
    public static void main(String[] args) throws Exception {
        String[] projection = {"document_id", "_display_name", "mime_type", "_size"};
        String[] providerColumns = {"_size", "mime_type", "document_id", "_display_name"};
        Object[] row = {13L, "text/plain", "primary:work/notes.txt", "notes.txt"};
        DocumentColumns columns = new DocumentColumns(providerColumns);
        equal(row[columns.required(projection[0])], "primary:work/notes.txt", "document id follows its name");
        equal(row[columns.required(projection[1])], "notes.txt", "display name follows its name");
        equal(row[columns.required(projection[2])], "text/plain", "MIME type follows its name");
        equal(row[columns.optional(projection[3])], 13L, "size follows its name");

        DocumentColumns noSize = new DocumentColumns(new String[]{"mime_type", "_display_name"});
        equal(noSize.optional("_size"), -1, "size may be omitted");
        equal(noSize.required("_display_name"), 1, "required columns still work without size");
        try {
            noSize.required("document_id");
            throw new AssertionError("missing document id must fail closed");
        } catch (IOException expected) {
            if (!expected.getMessage().contains("document_id")) throw expected;
        }
        System.out.println("DocumentColumnsTest passed");
    }

    private static void equal(Object actual, Object expected, String description) {
        if (!expected.equals(actual)) throw new AssertionError(description + ": " + actual);
    }
}
