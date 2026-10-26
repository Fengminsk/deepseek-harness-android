package com.minnnng.dsh_android;

import java.io.IOException;
import java.util.Arrays;
import java.util.List;

/** Bounds SAF name-based traversal before a provider can force unbounded enumeration. */
public final class DocumentTraversalBudget {
    public static final int MAX_PATH_CHARS = 4096;
    public static final int MAX_DEPTH = 64;
    public static final int MAX_CHILDREN = 10_000;

    private int children;

    /** Empty path names the granted root; every other segment must be an unambiguous name. */
    public static List<String> segments(String path) {
        if (path == null || path.length() > MAX_PATH_CHARS) {
            throw new IllegalArgumentException("路径过长，请授权更近的子目录");
        }
        if (path.isEmpty()) return AndroidJava28.listOf();
        String[] parts = path.split("/", -1);
        if (parts.length > MAX_DEPTH) {
            throw new IllegalArgumentException("路径超过 64 级，请授权更近的子目录");
        }
        for (String part : parts) {
            if (part.isEmpty() || part.equals(".") || part.equals("..") || part.indexOf('\\') >= 0) {
                throw new IllegalArgumentException("相对路径无效，请从授权目录重新选择");
            }
        }
        return AndroidJava28.copyList(Arrays.asList(parts));
    }

    /** Count even rows whose names do not match; duplicate-name detection requires a full bounded scan. */
    public void nextChild() throws IOException {
        if (++children > MAX_CHILDREN) {
            throw new IOException("目录超过 10000 项，请用系统文件选择器直接授权更近的子目录");
        }
    }
}
