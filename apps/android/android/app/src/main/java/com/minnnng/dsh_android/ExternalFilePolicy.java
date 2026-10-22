package com.minnnng.dsh_android;

/** Validates the one relative App-workspace file selected by the user. */
public final class ExternalFilePolicy {
    private ExternalFilePolicy() {}

    public static String[] segments(String path) {
        if (path == null || path.isEmpty() || path.length() > 4096 || path.startsWith("/")
                || path.endsWith("/") || path.indexOf('\\') >= 0 || path.indexOf(':') >= 0) {
            throw new IllegalArgumentException("请选择工作区内的文件");
        }
        String[] parts = path.split("/", -1);
        for (String part : parts) {
            if (part.isEmpty() || part.equals(".") || part.equals(".."))
                throw new IllegalArgumentException("文件路径无效，请重新选择");
            for (int i = 0; i < part.length(); i++) {
                char value = part.charAt(i);
                if (value < 32 || value == 127) throw new IllegalArgumentException("文件路径无效，请重新选择");
            }
        }
        return parts;
    }

    public static String displayName(String name) {
        if (name == null || name.isEmpty() || name.length() > 240 || name.equals(".") || name.equals("..")
                || name.indexOf('/') >= 0 || name.indexOf('\\') >= 0 || name.indexOf(':') >= 0) {
            throw new IllegalArgumentException("文件名无效，请重新选择");
        }
        for (int i = 0; i < name.length(); i++) {
            char value = name.charAt(i);
            if (value < 32 || value == 127) throw new IllegalArgumentException("文件名无效，请重新选择");
        }
        return name;
    }
}
