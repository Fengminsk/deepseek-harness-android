package com.minnnng.dsh_android;

import java.util.Arrays;

public final class ExternalFilePolicyTest {
    private static int assertions;

    private static void check(boolean value) {
        assertions++;
        if (!value) throw new AssertionError("External file path assertion failed");
    }

    private static void rejects(String path) {
        try { ExternalFilePolicy.segments(path); throw new AssertionError("Accepted: " + path); }
        catch (IllegalArgumentException expected) { assertions++; }
    }

    public static void main(String[] args) {
        check(Arrays.equals(ExternalFilePolicy.segments("notes/report.pdf"), new String[] {"notes", "report.pdf"}));
        check(ExternalFilePolicy.displayName("报告.pdf").equals("报告.pdf"));
        for (String path : new String[] {"", "/etc/passwd", "notes/", "a//b", "../secret", "a/../b", "a/./b", "a\\b", "C:/a", "a/\0b", "a/\nb"}) rejects(path);
        for (String name : new String[] {"", ".", "..", "a/b", "a\\b", "a:b", "a\nb"}) {
            try { ExternalFilePolicy.displayName(name); throw new AssertionError("Accepted name: " + name); }
            catch (IllegalArgumentException expected) { assertions++; }
        }
        System.out.println("ExternalFilePolicy: " + assertions + " assertions passed");
    }
}
