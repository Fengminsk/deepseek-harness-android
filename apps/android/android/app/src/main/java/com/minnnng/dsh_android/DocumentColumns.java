package com.minnnng.dsh_android;

import java.io.IOException;
import java.util.HashMap;
import java.util.Map;

/** Resolves SAF cursor columns by name; providers may omit optional columns or reorder them. */
public final class DocumentColumns {
    private final Map<String, Integer> indices = new HashMap<>();

    public DocumentColumns(String[] names) {
        for (int index = 0; index < names.length; index++) {
            indices.putIfAbsent(names[index], index);
        }
    }

    public int required(String name) throws IOException {
        int index = optional(name);
        if (index < 0) {
            throw new IOException("文件提供方未返回必需字段 " + name + "，请换用其他文件提供方或重新选择");
        }
        return index;
    }

    public int optional(String name) {
        return indices.getOrDefault(name, -1);
    }
}
