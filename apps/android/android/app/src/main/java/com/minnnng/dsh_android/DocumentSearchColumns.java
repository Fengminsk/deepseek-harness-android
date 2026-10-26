package com.minnnng.dsh_android;

import java.io.IOException;

/** A provider may reorder projection columns and omit optional document metadata. */
public final class DocumentSearchColumns {
    public interface Values {
        boolean isNull(int index);
        String string(int index);
        long longValue(int index);
        int intValue(int index);
    }

    public static final class Row {
        public final String documentId;
        public final String name;
        public final String mime;
        public final Long size;
        public final Long modified;
        public final boolean virtual;

        private Row(String documentId, String name, String mime, Long size,
                Long modified, boolean virtual) {
            this.documentId = documentId;
            this.name = name;
            this.mime = mime;
            this.size = size;
            this.modified = modified;
            this.virtual = virtual;
        }
    }

    private final int documentId;
    private final int name;
    private final int mime;
    private final int size;
    private final int modified;
    private final int flags;
    private final int virtualMask;
    private final boolean child;

    public DocumentSearchColumns(String[] names, boolean child, int virtualMask) throws IOException {
        DocumentColumns columns = new DocumentColumns(names);
        documentId = child ? columns.required("document_id") : columns.optional("document_id");
        name = columns.required("_display_name");
        mime = columns.required("mime_type");
        size = columns.optional("_size");
        modified = columns.optional("last_modified");
        flags = columns.optional("flags");
        this.virtualMask = virtualMask;
        this.child = child;
    }

    public Row read(Values values) throws IOException {
        String id = text(values, documentId);
        String displayName = text(values, name);
        String mimeType = text(values, mime);
        if (child && (id == null || id.isEmpty())) {
            throw new IOException("文件提供方返回的目录项目缺少文档标识，请重新选择");
        }
        if (displayName == null || displayName.isEmpty() || mimeType == null || mimeType.isEmpty()) {
            throw new IOException("文件提供方返回的项目缺少名称或类型，请重新选择");
        }
        Long bytes = number(values, size);
        if (bytes != null && bytes < 0) bytes = null;
        return new Row(id, displayName, mimeType, bytes, number(values, modified),
            flags >= 0 && !values.isNull(flags) &&
                (values.intValue(flags) & virtualMask) != 0);
    }

    private static String text(Values values, int index) {
        return index < 0 || values.isNull(index) ? null : values.string(index);
    }

    private static Long number(Values values, int index) {
        return index < 0 || values.isNull(index) ? null : values.longValue(index);
    }
}
