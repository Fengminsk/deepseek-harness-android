package com.minnnng.dsh_android;

import java.io.*;
import java.nio.ByteBuffer;
import java.nio.charset.*;
import java.nio.file.*;
import java.nio.file.attribute.BasicFileAttributes;
import java.security.MessageDigest;
import java.util.*;

/** Fixed-file recovery transactions. Journals never contain configuration text. */
public final class RecoveryFiles {
    public static final int MAX_BYTES = 1024 * 1024;
    public static final int LOG_BYTES = 64 * 1024;
    public static final String MISSING = "missing";
    private static final Map<String, String> FILES = new LinkedHashMap<>();
    static {
        FILES.put("profile-patch", "profiles/android/cordis.patch.yml");
        FILES.put("home-patch", "cordis.patch.yml");
        FILES.put("profile-manifest", "profiles/android/package.json");
    }
    public interface SyncDirectory { void sync(Path directory) throws IOException; }
    public interface Validator { void validate(String fileId, String text) throws Failure; }
    public static final class Failure extends IOException {
        public final String code;
        public String notStartedRequestId;
        public Failure(String code, String message) { super(message); this.code = code; }
    }
    private static final class Attempt { boolean journalAttempted; }
    private interface Mutation { Map<String, Object> run() throws IOException; }
    private Attempt attempt;
    private final Path base, home, recovery;
    private final SyncDirectory directorySync;
    private final Validator validator;
    private final String generation;

    public RecoveryFiles(Path noBackup, String generation, SyncDirectory sync, Validator validator) throws IOException {
        base = noBackup.toAbsolutePath().normalize();
        home = base.resolve("dsh");
        recovery = base.resolve("pocket-recovery");
        this.generation = generation;
        directorySync = sync;
        this.validator = validator;
        safe(base);
    }

    public static String hash(byte[] value) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(value);
            StringBuilder result = new StringBuilder();
            for (byte b : digest) result.append(String.format(Locale.ROOT, "%02x", b & 255));
            return result.toString();
        } catch (java.security.NoSuchAlgorithmException impossible) { throw new AssertionError(impossible); }
    }

    public static void requestId(String value) throws Failure {
        if (value == null || !value.matches("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}"))
            throw new Failure("recovery/request-invalid", "恢复操作标识无效");
    }

    private Path safe(Path path) throws IOException {
        Path normalized = path.toAbsolutePath().normalize();
        if (!normalized.startsWith(base)) throw new Failure("recovery/path-invalid", "恢复路径超出允许范围");
        Path current = base;
        if (Files.isSymbolicLink(current)) throw new Failure("recovery/path-invalid", "恢复目录不能是符号链接");
        for (Path part : base.relativize(normalized)) {
            current = current.resolve(part);
            if (Files.isSymbolicLink(current)) throw new Failure("recovery/path-invalid", "恢复路径不能包含符号链接");
        }
        return normalized;
    }

    private Path target(String id) throws IOException {
        String relative = FILES.get(id);
        if (relative == null) throw new Failure("recovery/file-invalid", "不支持的恢复文件");
        return safe(home.resolve(relative));
    }

    private byte[] bytes(Path path, int maximum) throws IOException {
        safe(path);
        BasicFileAttributes attributes;
        try { attributes = Files.readAttributes(path, BasicFileAttributes.class, LinkOption.NOFOLLOW_LINKS); }
        catch (NoSuchFileException missing) { return null; }
        if (!attributes.isRegularFile())
            throw new Failure("recovery/file-invalid", "配置目标不是普通文件");
        if (attributes.size() > maximum) throw new Failure("recovery/too-large", "配置文件超过恢复编辑大小限制");
        try (InputStream input = Files.newInputStream(path)) {
            ByteArrayOutputStream output = new ByteArrayOutputStream();
            byte[] buffer = new byte[8192];
            while (output.size() <= maximum) {
                int count = input.read(buffer, 0, Math.min(buffer.length, maximum + 1 - output.size()));
                if (count < 0) break;
                output.write(buffer, 0, count);
            }
            byte[] value = output.toByteArray();
            if (value.length > maximum) throw new Failure("recovery/too-large", "配置文件超过恢复编辑大小限制");
            return value;
        }
    }

    private static String text(byte[] value) throws Failure {
        try {
            return StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(value)).toString();
        } catch (CharacterCodingException failure) {
            throw new Failure("recovery/encoding-invalid", "文件不是有效 UTF-8，原字节未修改");
        }
    }

    private static String digest(byte[] value) { return value == null ? MISSING : hash(value); }

    public synchronized Map<String, Object> read(String id) throws IOException {
        byte[] value = bytes(target(id), MAX_BYTES);
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("id", id);
        result.put("exists", value != null);
        result.put("text", value == null ? "" : text(value));
        result.put("sha256", digest(value));
        result.put("private", true);
        return result;
    }

    public synchronized List<Map<String, Object>> files() throws IOException {
        List<Map<String, Object>> result = new ArrayList<>();
        for (String id : FILES.keySet()) {
            Path path = target(id);
            Map<String, Object> row = new LinkedHashMap<>();
            row.put("id", id);
            row.put("label", switch (id) {
                case "profile-patch" -> "Android 配置补丁";
                case "home-patch" -> "全局配置补丁";
                default -> "Android 配置包清单";
            });
            row.put("exists", Files.exists(path, LinkOption.NOFOLLOW_LINKS));
            try {
                byte[] value = bytes(path, MAX_BYTES);
                row.put("bytes", value == null ? 0 : value.length);
                row.put("sha256", digest(value));
                row.put("editable", true);
            } catch (Failure failure) {
                row.put("bytes", Files.isRegularFile(path) ? Files.size(path) : 0);
                row.put("sha256", "unavailable");
                row.put("editable", false);
                row.put("error", failure.code);
            }
            result.add(row);
        }
        return result;
    }

    public synchronized Map<String, Object> log() throws IOException {
        Path path = safe(home.resolve("runtime-stderr.log"));
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("id", "runtime-log");
        result.put("private", true);
        result.put("exists", Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS));
        if (!Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS)) {
            result.put("text", ""); result.put("sha256", MISSING); result.put("truncated", false);
            return result;
        }
        try (RandomAccessFile file = new RandomAccessFile(path.toFile(), "r")) {
            long length = file.length();
            file.seek(Math.max(0, length - LOG_BYTES));
            byte[] value = new byte[(int) Math.min(length, LOG_BYTES)];
            file.readFully(value);
            result.put("text", new String(value, StandardCharsets.UTF_8));
            result.put("sha256", hash(value));
            result.put("truncated", length > LOG_BYTES);
            return result;
        }
    }

    private void directories(Path path) throws IOException {
        safe(path);
        if (Files.exists(path, LinkOption.NOFOLLOW_LINKS)) {
            if (!Files.isDirectory(path, LinkOption.NOFOLLOW_LINKS))
                throw new Failure("recovery/path-invalid", "恢复父目录不是目录");
            return;
        }
        directories(path.getParent());
        Files.createDirectory(path);
        directorySync.sync(path.getParent());
    }

    private void atomic(Path path, byte[] content) throws IOException {
        safe(path);
        directories(path.getParent());
        Path temporary = path.resolveSibling("." + path.getFileName() + "-" + UUID.randomUUID() + ".pending");
        try (FileOutputStream output = new FileOutputStream(temporary.toFile())) {
            output.write(content);
            output.getFD().sync();
        }
        Files.move(temporary, path, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
        directorySync.sync(path.getParent());
    }

    private Path record(String requestId) throws IOException {
        requestId(requestId);
        return safe(recovery.resolve("operations").resolve(requestId + ".properties"));
    }

    private Properties properties(Path path) throws IOException {
        byte[] value = bytes(path, 64 * 1024);
        if (value == null) return null;
        Properties result = new Properties();
        try (InputStream input = new ByteArrayInputStream(value)) { result.load(input); }
        return result;
    }

    private void properties(Path path, Properties value) throws IOException {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        value.store(output, "Pocket Harness recovery metadata; contains no configuration text");
        atomic(path, output.toByteArray());
    }

    private Map<String, Object> receipt(Properties value) {
        Map<String, Object> result = new LinkedHashMap<>();
        String state = value.getProperty("state", "unknown");
        // External reads serialize behind mutations. A pending journal visible here
        // has no executing owner, even when a failed begin used this generation.
        if (state.equals("pending")) state = "unknown";
        result.put("state", state);
        for (String key : Arrays.asList("requestId", "method", "fileId", "sha256", "backupId", "generation"))
            if (value.containsKey(key)) result.put(key, value.getProperty(key));
        result.put("createdAt", Long.parseLong(value.getProperty("createdAt", "0")));
        result.put("restartRequired", true);
        return result;
    }

    public synchronized Map<String, Object> receipt(String id) throws IOException {
        Properties value = properties(record(id));
        if (value == null) {
            Map<String, Object> missing = new LinkedHashMap<>();
            missing.put("state", "unknown"); missing.put("requestId", id);
            return missing;
        }
        return receipt(value);
    }

    public synchronized List<Map<String, Object>> operations() throws IOException {
        return records("operations", false);
    }

    public synchronized List<Map<String, Object>> backups() throws IOException {
        return records("backups", true);
    }

    private List<Map<String, Object>> records(String directory, boolean backup) throws IOException {
        Path root = safe(recovery.resolve(directory));
        List<Map<String, Object>> result = new ArrayList<>();
        if (!Files.isDirectory(root)) return result;
        try (DirectoryStream<Path> entries = Files.newDirectoryStream(root, "*.properties")) {
            for (Path entry : entries) {
                Properties value = properties(entry);
                if (value == null) continue;
                Map<String, Object> row = new LinkedHashMap<>(receipt(value));
                if (backup) {
                    row.put("id", value.getProperty("backupId"));
                    row.put("bytes", Long.parseLong(value.getProperty("bytes", "0")));
                    row.put("exists", Boolean.parseBoolean(value.getProperty("exists", "true")));
                }
                result.add(row);
            }
        }
        result.sort((a, b) -> Long.compare((long) b.get("createdAt"), (long) a.get("createdAt")));
        return result.subList(0, Math.min(result.size(), 50));
    }

    private Properties begin(String id, String method, String fileId, String expected, String nextHash) throws IOException {
        Properties old = properties(record(id));
        if (old != null) {
            if (!method.equals(old.getProperty("signature", old.getProperty("method"))) || !fileId.equals(old.getProperty("fileId"))
                    || !expected.equals(old.getProperty("expected")) || !nextHash.equals(old.getProperty("sha256")))
                throw new Failure("recovery/request-conflict", "操作标识已用于不同内容，请核对原操作");
            return old;
        }
        Properties value = new Properties();
        value.setProperty("requestId", id);
        value.setProperty("method", method.startsWith("restore:") ? "restore" : method);
        value.setProperty("signature", method);
        value.setProperty("fileId", fileId);
        value.setProperty("expected", expected);
        value.setProperty("sha256", nextHash);
        value.setProperty("generation", generation);
        value.setProperty("createdAt", Long.toString(System.currentTimeMillis()));
        value.setProperty("state", "pending");
        value.setProperty("backupId", UUID.randomUUID().toString());
        if (attempt != null) attempt.journalAttempted = true;
        properties(record(id), value);
        return value;
    }

    private boolean existsOperation(String id) throws IOException { return properties(record(id)) != null; }

    /** Explicit evidence for a rejected request, never inferred from an error code. */
    public synchronized Failure rejection(String code, String message, String requestId) {
        Failure failure = new Failure(code, message);
        try {
            if (!existsOperation(requestId)) failure.notStartedRequestId = requestId;
        } catch (IOException ignored) { /* An unreadable prior journal is not proof of no write. */ }
        return failure;
    }

    private Map<String, Object> mutation(String requestId, Mutation action) throws IOException {
        requestId(requestId);
        boolean prior = existsOperation(requestId);
        Attempt current = new Attempt();
        attempt = current;
        try { return action.run(); }
        catch (IOException error) {
            Failure failure = error instanceof Failure ? (Failure) error :
                new Failure("recovery/io-unconfirmed", "恢复文件访问未完成，请核对操作记录");
            if (!prior && !current.journalAttempted) failure.notStartedRequestId = requestId;
            throw failure;
        } finally { attempt = null; }
    }

    private void backup(Properties operation, byte[] old) throws IOException {
        String id = operation.getProperty("backupId");
        Properties metadata = new Properties();
        metadata.putAll(operation);
        metadata.setProperty("state", "saved");
        metadata.setProperty("sha256", digest(old));
        metadata.setProperty("bytes", Integer.toString(old == null ? 0 : old.length));
        metadata.setProperty("exists", Boolean.toString(old != null));
        if (old != null) atomic(safe(recovery.resolve("backups").resolve(id + ".data")), old);
        properties(safe(recovery.resolve("backups").resolve(id + ".properties")), metadata);
    }

    public synchronized Map<String, Object> write(String id, String expected, String text, String requestId) throws IOException {
        return mutation(requestId, () -> {
        byte[] next = text.getBytes(StandardCharsets.UTF_8);
        if (next.length > MAX_BYTES) throw new Failure("recovery/too-large", "配置内容最多为 1 MiB");
        // Reject unpaired UTF-16 instead of silently replacing the user's draft.
        if (!text.equals(new String(next, StandardCharsets.UTF_8)))
            throw new Failure("recovery/encoding-invalid", "配置包含无效字符，草稿未写入");
        validator.validate(id, text);
        return mutate(id, expected, next, requestId, "write");
        });
    }

    public synchronized Map<String, Object> restore(String backupId, String expected, String requestId) throws IOException {
        return mutation(requestId, () -> {
        requestId(backupId);
        Properties stored = properties(safe(recovery.resolve("backups").resolve(backupId + ".properties")));
        if (stored == null) throw new Failure("recovery/backup-missing", "备份不存在");
        String id = stored.getProperty("fileId");
        target(id);
        byte[] next = Boolean.parseBoolean(stored.getProperty("exists"))
            ? bytes(safe(recovery.resolve("backups").resolve(backupId + ".data")), MAX_BYTES) : null;
        if (!digest(next).equals(stored.getProperty("sha256")))
            throw new Failure("recovery/backup-damaged", "备份校验失败，当前配置未修改");
        return mutate(id, expected, next, requestId, "restore:" + backupId);
        });
    }

    public synchronized Map<String, Object> readBackup(String backupId) throws IOException {
        requestId(backupId);
        Properties stored = properties(safe(recovery.resolve("backups").resolve(backupId + ".properties")));
        if (stored == null) throw new Failure("recovery/backup-missing", "备份不存在");
        String id = stored.getProperty("fileId");
        target(id);
        byte[] value = Boolean.parseBoolean(stored.getProperty("exists"))
            ? bytes(safe(recovery.resolve("backups").resolve(backupId + ".data")), MAX_BYTES) : null;
        if (!digest(value).equals(stored.getProperty("sha256")))
            throw new Failure("recovery/backup-damaged", "备份校验失败，当前配置未修改");
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("id", id); result.put("backupId", backupId);
        result.put("text", value == null ? "" : text(value));
        result.put("exists", value != null); result.put("sha256", digest(value));
        result.put("private", true);
        return result;
    }

    private Map<String, Object> mutate(String id, String expected, byte[] next, String requestId, String method) throws IOException {
        Path destination = target(id);
        if (expected == null || !(expected.equals(MISSING) || expected.matches("[0-9a-f]{64}")))
            throw new Failure("recovery/hash-invalid", "配置版本标识无效");
        if (existsOperation(requestId)) return receipt(begin(requestId, method, id, expected, digest(next)));
        byte[] old = bytes(destination, MAX_BYTES);
        if (!digest(old).equals(expected)) throw new Failure("recovery/conflict", "配置已变化，未覆盖；请重新读取并保留草稿");
        Properties operation = begin(requestId, method, id, expected, digest(next));
        try {
            backup(operation, old);
            // The service is Node-free and serializes all recovery writes.
            if (!digest(bytes(destination, MAX_BYTES)).equals(expected))
                throw new Failure("recovery/conflict", "配置在保存前发生变化，请核对原文件");
            if (next == null) {
                Files.deleteIfExists(destination);
                if (Files.isDirectory(destination.getParent())) directorySync.sync(destination.getParent());
            } else atomic(destination, next);
            operation.setProperty("state", "saved");
            properties(record(requestId), operation);
            return receipt(operation);
        } catch (IOException failure) {
            operation.setProperty("state", "unknown");
            try { properties(record(requestId), operation); }
            catch (IOException journalFailure) { failure.addSuppressed(journalFailure); }
            throw new Failure("recovery/write-unconfirmed", "保存结果未确认；备份与操作记录已保留，请核对后再操作");
        }
    }

    public synchronized Map<String, Object> runtimeRepair(String hash, String requestId) throws IOException {
        return mutation(requestId, () -> {
        if (hash == null || !hash.matches("[0-9a-f]{64}"))
            throw new Failure("recovery/hash-invalid", "运行时校验值无效");
        if (existsOperation(requestId)) return receipt(begin(requestId, "runtimeRepair", "runtime-cache", hash, hash));
        Path source = safe(base.resolve("runtimes").resolve(hash));
        Properties operation = begin(requestId, "runtimeRepair", "runtime-cache", hash, hash);
        try {
            if (Files.exists(source, LinkOption.NOFOLLOW_LINKS)) {
                if (!Files.isDirectory(source, LinkOption.NOFOLLOW_LINKS))
                    throw new Failure("recovery/path-invalid", "运行时缓存不是目录");
                Path quarantine = safe(recovery.resolve("runtime-cache").resolve(operation.getProperty("backupId")));
                directories(quarantine.getParent());
                Files.move(source, quarantine, StandardCopyOption.ATOMIC_MOVE);
                directorySync.sync(source.getParent());
                directorySync.sync(quarantine.getParent());
            }
            operation.setProperty("state", "saved");
            properties(record(requestId), operation);
            return receipt(operation);
        } catch (IOException failure) {
            operation.setProperty("state", "unknown");
            try { properties(record(requestId), operation); }
            catch (IOException journalFailure) { failure.addSuppressed(journalFailure); }
            throw new Failure("recovery/repair-unconfirmed", "运行时缓存隔离结果未确认，请核对操作记录");
        }
        });
    }

    /** Main-process single writer; the Agent reads fresh disk bytes on each process start. */
    public synchronized void setMode(String mode, String token) throws IOException {
        if (!mode.equals("active") && !mode.equals("maintenance"))
            throw new Failure("recovery/mode-invalid", "不支持的服务模式");
        requestId(token);
        atomic(safe(base.resolve("pocket-recovery-mode")), (mode + "\n" + token + "\n").getBytes(StandardCharsets.UTF_8));
    }

    public synchronized String[] mode() throws IOException {
        byte[] raw = bytes(safe(base.resolve("pocket-recovery-mode")), 256);
        if (raw == null) return new String[] {"active", "initial"};
        String[] fields = text(raw).split("\n");
        if (fields.length != 2 || (!fields[0].equals("active") && !fields[0].equals("maintenance")))
            throw new Failure("recovery/control-damaged", "服务模式记录无法读取，请重新选择维护或启动");
        requestId(fields[1]);
        return fields;
    }
}
