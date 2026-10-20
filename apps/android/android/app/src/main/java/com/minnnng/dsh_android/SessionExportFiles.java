package com.minnnng.dsh_android;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.util.function.BooleanSupplier;

/** Fixed-cache export access and bounded copying; callers own the destination URI. */
public final class SessionExportFiles {
    private SessionExportFiles() {}

    public static File source(File directory, String id) throws IOException {
        if (id == null || !id.matches("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")) {
            throw new IllegalArgumentException("无效的导出标识");
        }
        File root = directory.getCanonicalFile();
        File source = new File(root, id + ".zip");
        if (!source.getCanonicalFile().getParentFile().equals(root)
                || !Files.isRegularFile(source.toPath(), LinkOption.NOFOLLOW_LINKS)) {
            throw new IOException("导出缓存已失效，请重新生成");
        }
        return source;
    }

    /** Does not delete or truncate destinations; a failed copy may have written a partial ZIP. */
    public static long copy(File source, OutputStream destination, BooleanSupplier cancelled) throws IOException {
        try (InputStream input = Files.newInputStream(source.toPath(), LinkOption.NOFOLLOW_LINKS)) {
            byte[] buffer = new byte[65536];
            long total = 0;
            while (true) {
                if (cancelled.getAsBoolean()) throw new IOException("导出已取消");
                int count = input.read(buffer);
                if (count < 0) break;
                destination.write(buffer, 0, count);
                total += count;
            }
            if (cancelled.getAsBoolean()) throw new IOException("导出已取消");
            destination.flush();
            return total;
        }
    }
}
