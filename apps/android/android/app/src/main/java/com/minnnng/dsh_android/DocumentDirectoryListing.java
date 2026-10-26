package com.minnnng.dsh_android;

import java.io.IOException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/** Validates a bounded SAF directory result before exposing name-addressed entries. */
public final class DocumentDirectoryListing {
    public static final class Entry {
        public final String documentId;
        public final String name;
        public final String mime;
        public final Long size;

        private Entry(String documentId, String name, String mime, Long size) {
            this.documentId = documentId;
            this.name = name;
            this.mime = mime;
            this.size = size;
        }
    }

    private final String parentPath;
    private final DocumentTraversalBudget budget = new DocumentTraversalBudget();
    private final Set<String> names = new HashSet<>();
    private final Set<String> ids = new HashSet<>();
    private final List<Entry> entries = new ArrayList<>();

    public DocumentDirectoryListing(String parentPath) {
        DocumentTraversalBudget.segments(parentPath);
        this.parentPath = parentPath;
    }

    public void add(String documentId, String name, String mime, Long size) throws IOException {
        budget.nextChild();
        if (documentId == null || documentId.isEmpty() || name == null || name.isEmpty()
                || mime == null || mime.isEmpty()) {
            throw new IOException("文件提供方返回的目录项目缺少标识、名称或类型，请重新选择");
        }
        if (name.equals(".") || name.equals("..") || name.indexOf('/') >= 0 || name.indexOf('\\') >= 0) {
            throw new IOException("文件提供方返回了无法通过授权目录访问的项目名称，请授权更近的子目录");
        }
        String childPath = parentPath.isEmpty() ? name : parentPath + "/" + name;
        try {
            DocumentTraversalBudget.segments(childPath);
        } catch (IllegalArgumentException invalid) {
            throw new IOException("目录项目路径超出安全访问范围，请授权更近的子目录", invalid);
        }
        if (!names.add(name) || !ids.add(documentId)) {
            throw new IOException("文件提供方返回了重复的目录项目，无法确定要打开哪一个，请刷新后重试");
        }
        entries.add(new Entry(documentId, name, mime, size == null || size < 0 ? null : size));
    }

    public List<Entry> entries() {
        List<Entry> sorted = new ArrayList<>(entries);
        sorted.sort(Comparator.comparing(entry -> entry.name));
        return Collections.unmodifiableList(sorted);
    }
}
