package com.minnnng.dsh_android;

import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.UUID;

/** Bounded cache for the single-file copies granted to Android viewers. */
public final class ExternalStageCache {
    public static final long MAX_BYTES = 512L * 1024 * 1024;
    public static final long MAX_AGE_MS = 24L * 60 * 60 * 1000;
    private ExternalStageCache() {}

    private static boolean stageName(String name) {
        try { return UUID.fromString(name).toString().equals(name); }
        catch (IllegalArgumentException ignored) { return false; }
    }

    public static File root(File cacheDir) throws IOException {
        File base = cacheDir.getCanonicalFile();
        File selected = new File(base, "external-open");
        if (Files.isSymbolicLink(selected.toPath())) throw new IOException("Staging root is a link");
        if (!selected.mkdirs() && !selected.isDirectory()) throw new IOException("Staging root unavailable");
        File canonical = selected.getCanonicalFile();
        if (!base.equals(canonical.getParentFile())) throw new IOException("Staging root left cache");
        return canonical;
    }

    public static File create(File root, String displayName) throws IOException {
        String name = ExternalFilePolicy.displayName(displayName);
        File directory = new File(root, UUID.randomUUID().toString());
        if (!directory.mkdir() || !directory.getCanonicalFile().getParentFile().equals(root.getCanonicalFile()))
            throw new IOException("Cannot create staging directory");
        return new File(directory, name);
    }

    /** Delete only one ordinary file in one app-created UUID directory. Never traverse links. */
    public static void delete(File root, File staged) throws IOException {
        if (staged == null) return;
        File base = root.getCanonicalFile();
        File parent = staged.getParentFile();
        if (parent == null || !stageName(parent.getName()) || Files.isSymbolicLink(parent.toPath())
                || !parent.getCanonicalFile().getParentFile().equals(base)
                || Files.isSymbolicLink(staged.toPath()) || !staged.getCanonicalFile().getParentFile().equals(parent.getCanonicalFile()))
            throw new IOException("Refusing to remove an unowned staging path");
        if (Files.isRegularFile(staged.toPath(), LinkOption.NOFOLLOW_LINKS)) Files.deleteIfExists(staged.toPath());
        parent.delete();
    }

    /** Prune on startup, periodically, and before and after each copy. Protect the active copy. */
    public static void prune(File root, long now, File active) throws IOException {
        prune(root, now, active, MAX_BYTES);
    }

    static void prune(File root, long now, File active, long maxBytes) throws IOException {
        if (maxBytes < 0) throw new IllegalArgumentException("Invalid staging budget");
        File base = root.getCanonicalFile();
        if (Files.isSymbolicLink(root.toPath()) || !base.isDirectory()) throw new IOException("Staging root unavailable");
        File[] children = base.listFiles();
        if (children == null) throw new IOException("Cannot list staging cache");
        List<Stage> stages = new ArrayList<>();
        long total = 0;
        for (File directory : children) {
            if (!stageName(directory.getName()) || Files.isSymbolicLink(directory.toPath()) || !directory.isDirectory()
                    || !directory.getCanonicalFile().getParentFile().equals(base)) continue;
            File[] files = directory.listFiles();
            if (files != null && files.length == 0 && active == null
                    && now - directory.lastModified() >= MAX_AGE_MS) {
                directory.delete();
                continue;
            }
            if (files == null || files.length != 1) continue;
            File file = files[0];
            if (Files.isSymbolicLink(file.toPath()) || !Files.isRegularFile(file.toPath(), LinkOption.NOFOLLOW_LINKS)
                    || !file.getCanonicalFile().getParentFile().equals(directory.getCanonicalFile())) continue;
            boolean protectedFile = active != null && file.equals(active);
            long age = now - directory.lastModified();
            if (!protectedFile && age >= MAX_AGE_MS) { delete(base, file); continue; }
            long length = file.length();
            total = Math.addExact(total, length);
            stages.add(new Stage(file, directory.lastModified(), length, protectedFile));
        }
        stages.sort(Comparator.comparingLong(stage -> stage.modified));
        for (Stage stage : stages) {
            if (total <= maxBytes) break;
            if (!stage.protectedFile) { delete(base, stage.file); total -= stage.length; }
        }
        if (total > maxBytes) throw new IOException("Staging cache limit reached");
    }

    private static final class Stage {
        final File file;
        final long modified;
        final long length;
        final boolean protectedFile;
        Stage(File file, long modified, long length, boolean protectedFile) {
            this.file = file;
            this.modified = modified;
            this.length = length;
            this.protectedFile = protectedFile;
        }
    }
}
