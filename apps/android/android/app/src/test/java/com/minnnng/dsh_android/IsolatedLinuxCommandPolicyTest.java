package com.minnnng.dsh_android;

import java.util.List;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.HashSet;

/** Plain JVM contract check; Android Binder isolation still needs instrumentation. */
public final class IsolatedLinuxCommandPolicyTest {
    public static void main(String[] args) {
        require(IsolatedLinuxCommandPolicy.fromWire("kernel") == IsolatedLinuxCommandPolicy.Command.KERNEL);
        require(IsolatedLinuxCommandPolicy.fromWire("identity") == IsolatedLinuxCommandPolicy.Command.IDENTITY);
        require(IsolatedLinuxCommandPolicy.fromWire("sha256") == IsolatedLinuxCommandPolicy.Command.SHA256);
        require(IsolatedLinuxCommandPolicy.fromWire("count_bytes") == IsolatedLinuxCommandPolicy.Command.COUNT_BYTES);
        require(IsolatedLinuxCommandPolicy.fromWire("count_lines") == IsolatedLinuxCommandPolicy.Command.COUNT_LINES);
        require(IsolatedLinuxCommandPolicy.fromWire("sort_lines") == IsolatedLinuxCommandPolicy.Command.SORT_LINES);
        require(IsolatedLinuxCommandPolicy.fromWire("filter_literal") == IsolatedLinuxCommandPolicy.Command.FILTER_LITERAL);
        require(IsolatedLinuxCommandPolicy.fromWire("_test_packaged_count_bytes") ==
            IsolatedLinuxCommandPolicy.Command.TEST_PACKAGED_COUNT_BYTES);
        for (String unsafe : List.of("", "KERNEL", "kernel -a", "kernel; id", "../kernel", "/system/bin/sh")) {
            require(IsolatedLinuxCommandPolicy.fromWire(unsafe) == null);
        }
        require(IsolatedLinuxCommandPolicy.fromWire(null) == null);
        for (IsolatedLinuxCommandPolicy.Command command : IsolatedLinuxCommandPolicy.Command.values()) {
            if (command == IsolatedLinuxCommandPolicy.Command.TEST_PACKAGED_COUNT_BYTES) {
                require(command.argv().isEmpty());
                continue;
            }
            require(command.argv().get(0).startsWith("/system/bin/"));
            require(command.argv().stream().noneMatch(part -> part.equals("sh") || part.equals("/system/bin/sh")));
            try {
                command.argv().add("/system/bin/sh");
                throw new AssertionError("Static argv was mutable");
            } catch (UnsupportedOperationException expected) { /* Immutable. */ }
        }
        require(IsolatedLinuxCommandPolicy.Command.KERNEL.argv().equals(List.of("/system/bin/uname", "-a")));
        require(IsolatedLinuxCommandPolicy.Command.IDENTITY.argv().equals(List.of("/system/bin/id", "-u")));
        require(new HashSet<>(Arrays.stream(IsolatedLinuxCommandPolicy.Command.values())
            .map(command -> command.wireName).toList()).size() == IsolatedLinuxCommandPolicy.Command.values().length);
        byte[] input = "b\na\n".getBytes(StandardCharsets.UTF_8);
        IsolatedLinuxCommandPolicy.Request sorting = IsolatedLinuxCommandPolicy.Request.of(
            IsolatedLinuxCommandPolicy.Command.SORT_LINES, null, input);
        input[0] = 'x';
        require(sorting.input()[0] == 'b');
        byte[] returned = sorting.input();
        returned[0] = 'y';
        require(sorting.input()[0] == 'b');
        require(sorting.argv().equals(List.of("/system/bin/toybox", "sort")));
        IsolatedLinuxCommandPolicy.Request filtering = IsolatedLinuxCommandPolicy.Request.of(
            IsolatedLinuxCommandPolicy.Command.FILTER_LITERAL, "-e ; /data/data", "safe\n".getBytes(StandardCharsets.UTF_8));
        require(filtering.argv().equals(List.of("/system/bin/toybox", "grep", "-F", "-e", "-e ; /data/data")));
        require(IsolatedLinuxCommandPolicy.Request.fromWire("filter_literal", "needle", "text".getBytes(StandardCharsets.UTF_8)) != null);
        require(IsolatedLinuxCommandPolicy.Request.fromWire("filter_literal", "", new byte[0]) == null);
        require(IsolatedLinuxCommandPolicy.Request.fromWire("filter_literal", "needle\nmore", new byte[0]) == null);
        require(IsolatedLinuxCommandPolicy.Request.fromWire("filter_literal", "needle", new byte[] {(byte) 0xc3}) == null);
        require(IsolatedLinuxCommandPolicy.Request.fromWire("filter_literal", "needle", new byte[] {0}) == null);
        require(IsolatedLinuxCommandPolicy.Request.fromWire("identity", null, new byte[] {1}) == null);
        require(IsolatedLinuxCommandPolicy.Request.fromWire("sort_lines", null,
            new byte[IsolatedLinuxCommandPolicy.MAX_STDIN_BYTES + 1]) == null);
        require(IsolatedLinuxCommandPolicy.Request.fromWire("sha256", null,
            new byte[IsolatedLinuxCommandPolicy.MAX_STDIN_BYTES]) != null);
        require(IsolatedLinuxCommandPolicy.Request.fromWire("filter_literal",
            "n".repeat(IsolatedLinuxCommandPolicy.MAX_ARGUMENT_BYTES + 1), new byte[0]) == null);
        require(IsolatedLinuxCommandPolicy.Request.fromWire("filter_literal", "中".repeat(42), new byte[0]) != null);
        require(IsolatedLinuxCommandPolicy.Request.fromWire("filter_literal", "中".repeat(43), new byte[0]) == null);
        require(IsolatedLinuxCommandPolicy.Request.fromWire("filter_literal", "\ud800", new byte[0]) == null);
        require(IsolatedLinuxCommandPolicy.Request.fromWire("sha256", null, new byte[] {0, (byte) 0xff}) != null);
        require(IsolatedLinuxCommandPolicy.Command.TEST_DELAY.isTestOnly());
        require(IsolatedLinuxCommandPolicy.Command.TEST_OUTPUT_FLOOD.isTestOnly());
        require(IsolatedLinuxCommandPolicy.Command.TEST_SERVICE_DEATH.isTestOnly());
        require(IsolatedLinuxCommandPolicy.Command.TEST_PACKAGED_COUNT_BYTES.isTestOnly());
        require(IsolatedLinuxCommandPolicy.Request.fromWire("_test_packaged_count_bytes", null,
            "safe".getBytes(StandardCharsets.UTF_8)) != null);
        require(!IsolatedLinuxCommandPolicy.Command.SHA256.isTestOnly());
        System.out.println("IsolatedLinuxCommandPolicyTest passed");
    }

    private static void require(boolean condition) {
        if (!condition) throw new AssertionError("Fixed Linux command contract failed");
    }
}
