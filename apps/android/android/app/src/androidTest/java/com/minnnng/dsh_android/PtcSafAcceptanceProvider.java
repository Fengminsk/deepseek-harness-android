package com.minnnng.dsh_android;

import android.content.Context;
import android.content.Intent;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.Binder;
import android.os.Bundle;
import android.os.CancellationSignal;
import android.os.ParcelFileDescriptor;
import android.os.Process;
import android.provider.DocumentsContract;
import android.provider.DocumentsProvider;
import java.io.File;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

/** Independent test-APK UID: only Android/Java dependencies, two generated files per grant. */
public final class PtcSafAcceptanceProvider extends DocumentsProvider {
    public static final String AUTHORITY = "com.minnnng.dsh_android.test.ptc.documents";
    public static final String TARGET = "com.minnnng.dsh_android";
    public static final String CONTROL_URI = "content://" + AUTHORITY;
    private static final String[] FILES = {"alpha.txt", "beta.txt"};
    private static final String[] COLUMNS = {"document_id", "_display_name", "mime_type", "flags", "_size", "last_modified"};
    private final ConcurrentHashMap<String, Fixture> fixtures = new ConcurrentHashMap<>();

    private static final class Fixture {
        final File directory;
        final AtomicBoolean hold = new AtomicBoolean();
        final AtomicBoolean entered = new AtomicBoolean();
        final AtomicBoolean signalPresent = new AtomicBoolean();
        Fixture(File directory) { this.directory = directory; }
    }
    private static final class Selection {
        final Fixture fixture;
        final String name;
        Selection(Fixture fixture, String name) { this.fixture = fixture; this.name = name; }
    }
    static void requireCase(String value) {
        if (value == null || !UUID.fromString(value).toString().equals(value) || value.charAt(14) != '4')
            throw new IllegalArgumentException("Invalid fixture UUID");
    }
    static void requireMethod(String value) {
        if (!"ptc.create".equals(value) && !"ptc.arm".equals(value) && !"ptc.state".equals(value)
                && !"ptc.revoke".equals(value) && !"ptc.remove".equals(value))
            throw new IllegalArgumentException("Unknown fixture operation");
    }
    private static void require(boolean condition, String message) {
        if (!condition) throw new IllegalStateException(message);
    }
    @Override public boolean onCreate() { return true; }

    @Override public synchronized Bundle call(String method, String id, Bundle extras) {
        if (method == null || !method.startsWith("ptc.")) return super.call(method, id, extras);
        requireMethod(method);
        requireCase(id);
        if (Binder.getCallingUid() != Process.myUid()) throw new SecurityException("Fixture control requires the test APK UID");
        if (extras != null && !extras.isEmpty()) throw new IllegalArgumentException("Unexpected fixture arguments");
        Context app = getContext();
        require(app != null, "Provider has no context");
        long identity = Binder.clearCallingIdentity();
        try {
            Bundle result = new Bundle();
            if ("ptc.create".equals(method)) {
                require(fixtures.size() < 4 && !fixtures.containsKey(id), "Fixture limit or duplicate UUID");
                File folder = new File(app.getCacheDir(), "ptc-saf-" + id);
                require(folder.mkdir(), "Fixture directory already exists");
                try {
                    Files.write(new File(folder, "alpha.txt").toPath(), ("PTC SAF needle " + id + "\n").getBytes(StandardCharsets.UTF_8));
                    Files.write(new File(folder, "beta.txt").toPath(), "unmatched fixture\n".getBytes(StandardCharsets.UTF_8));
                } catch (IOException failure) { throw new IllegalStateException("Fixture creation failed", failure); }
                require(fixtures.putIfAbsent(id, new Fixture(folder)) == null, "Duplicate fixture");
                Uri uri = DocumentsContract.buildTreeDocumentUri(AUTHORITY, id);
                app.grantUriPermission(TARGET, uri, Intent.FLAG_GRANT_READ_URI_PERMISSION
                        | Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION | Intent.FLAG_GRANT_PREFIX_URI_PERMISSION);
                result.putString("uri", uri.toString());
                return result;
            }
            Fixture fixture = fixtures.get(id);
            require(fixture != null, "Unknown test root");
            switch (method) {
                case "ptc.arm": fixture.entered.set(false); fixture.signalPresent.set(false); fixture.hold.set(true); break;
                case "ptc.state":
                    result.putBoolean("entered", fixture.entered.get());
                    result.putBoolean("signalPresent", fixture.signalPresent.get());
                    break;
                case "ptc.revoke":
                case "ptc.remove":
                    app.revokeUriPermission(TARGET, DocumentsContract.buildTreeDocumentUri(AUTHORITY, id), Intent.FLAG_GRANT_READ_URI_PERMISSION);
                    if ("ptc.remove".equals(method)) {
                        for (String name : FILES) require(new File(fixture.directory, name).delete(), "Fixture file removal failed");
                        require(fixture.directory.delete(), "Fixture directory removal failed");
                        require(fixtures.remove(id, fixture), "Fixture changed during removal");
                    }
                    break;
                default: throw new IllegalArgumentException("Unknown fixture operation");
            }
            return result;
        } finally { Binder.restoreCallingIdentity(identity); }
    }
    @Override public Cursor queryRoots(String[] projection) {
        return new MatrixCursor(projection != null ? projection : new String[] {DocumentsContract.Root.COLUMN_ROOT_ID,
                DocumentsContract.Root.COLUMN_DOCUMENT_ID, DocumentsContract.Root.COLUMN_TITLE, DocumentsContract.Root.COLUMN_FLAGS});
    }
    private Selection selection(String documentId) throws FileNotFoundException {
        if (documentId == null) throw new FileNotFoundException("Unknown test document");
        String[] parts = documentId.split(":", -1);
        if (parts.length < 1 || parts.length > 2 || (parts.length == 2 && !isFile(parts[1])))
            throw new FileNotFoundException("Unknown test document");
        Fixture fixture = fixtures.get(parts[0]);
        if (fixture == null) throw new FileNotFoundException("Unknown test root");
        return new Selection(fixture, parts.length == 2 ? parts[1] : null);
    }
    private static boolean isFile(String name) { return "alpha.txt".equals(name) || "beta.txt".equals(name); }
    private void row(MatrixCursor cursor, String documentId) throws FileNotFoundException {
        Selection selected = selection(documentId);
        File file = selected.name == null ? null : new File(selected.fixture.directory, selected.name);
        String[] columns = cursor.getColumnNames();
        Object[] values = new Object[columns.length];
        for (int i = 0; i < columns.length; i++) {
            switch (columns[i]) {
                case "document_id": values[i] = documentId; break;
                case "_display_name": values[i] = file == null ? "PTC acceptance" : selected.name; break;
                case "mime_type": values[i] = file == null ? DocumentsContract.Document.MIME_TYPE_DIR : "text/plain"; break;
                case "flags": values[i] = 0; break;
                case "_size": values[i] = file == null ? 0L : file.length(); break;
                case "last_modified": values[i] = file == null ? 0L : file.lastModified(); break;
                default: values[i] = null;
            }
        }
        cursor.addRow(values);
    }
    @Override public Cursor queryDocument(String documentId, String[] projection) throws FileNotFoundException {
        MatrixCursor result = new MatrixCursor(projection != null ? projection : COLUMNS);
        row(result, documentId);
        return result;
    }
    @Override public Cursor queryChildDocuments(String parentDocumentId, String[] projection, String sortOrder) throws FileNotFoundException {
        require(selection(parentDocumentId).name == null, "Test parent must be a directory");
        MatrixCursor result = new MatrixCursor(projection != null ? projection : COLUMNS);
        for (String name : FILES) row(result, parentDocumentId + ":" + name);
        return result;
    }
    @Override public boolean isChildDocument(String parentDocumentId, String documentId) {
        if (!fixtures.containsKey(parentDocumentId)) return false;
        for (String name : FILES) if ((parentDocumentId + ":" + name).equals(documentId)) return true;
        return false;
    }
    @Override public ParcelFileDescriptor openDocument(String documentId, String mode, CancellationSignal signal) throws FileNotFoundException {
        if (!"r".equals(mode)) throw new FileNotFoundException("Read-only test documents");
        Selection selected = selection(documentId);
        if (selected.name == null) throw new FileNotFoundException("Directory");
        if (selected.fixture.hold.get()) {
            CountDownLatch cancelled = new CountDownLatch(1);
            if (signal != null) signal.setOnCancelListener(cancelled::countDown);
            selected.fixture.signalPresent.set(signal != null);
            selected.fixture.entered.set(true);
            try {
                require(cancelled.await(20, TimeUnit.SECONDS), "Test search was not cancelled");
                require(signal != null, "Missing search cancellation signal");
                signal.throwIfCanceled();
                throw new IllegalStateException("Cancellation latch completed without cancellation");
            } catch (InterruptedException failure) {
                Thread.currentThread().interrupt();
                throw new IllegalStateException("Provider search interrupted", failure);
            } finally { if (signal != null) signal.setOnCancelListener(null); }
        }
        if (signal != null) signal.throwIfCanceled();
        return ParcelFileDescriptor.open(new File(selected.fixture.directory, selected.name), ParcelFileDescriptor.MODE_READ_ONLY);
    }
}
