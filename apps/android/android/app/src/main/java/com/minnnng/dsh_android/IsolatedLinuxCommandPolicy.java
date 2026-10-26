package com.minnnng.dsh_android;

import java.nio.ByteBuffer;
import java.nio.CharBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/** A typed Linux utility ABI with no caller-controlled executable, shell source or path. */
final class IsolatedLinuxCommandPolicy {
    static final int MAX_STDIN_BYTES = 64 * 1024;
    static final int MAX_ARGUMENT_BYTES = 128;
    static final int MAX_OUTPUT_BYTES = 4096;
    static final long CHILD_DEADLINE_MS = 1500L;
    static final long HOST_DEADLINE_MS = 4000L;

    enum Command {
        KERNEL("kernel", AndroidJava28.listOf("/system/bin/uname", "-a"), false, false, false, false),
        IDENTITY("identity", AndroidJava28.listOf("/system/bin/id", "-u"), false, false, false, false),
        SHA256("sha256", AndroidJava28.listOf("/system/bin/toybox", "sha256sum"), true, false, false, false),
        COUNT_BYTES("count_bytes", AndroidJava28.listOf("/system/bin/toybox", "wc", "-c"), true, false, false, false),
        COUNT_LINES("count_lines", AndroidJava28.listOf("/system/bin/toybox", "wc", "-l"), true, false, false, false),
        SORT_LINES("sort_lines", AndroidJava28.listOf("/system/bin/toybox", "sort"), true, false, true, false),
        FILTER_LITERAL("filter_literal", AndroidJava28.listOf("/system/bin/toybox", "grep", "-F", "-e"), true, true, true, false),
        // Test-only IDs are rejected by non-debuggable services.
        TEST_PACKAGED_COUNT_BYTES("_test_packaged_count_bytes", AndroidJava28.listOf(), true, false, false, true),
        TEST_DELAY("_test_delay", AndroidJava28.listOf("/system/bin/toybox", "sleep", "30"), false, false, false, true),
        TEST_OUTPUT_FLOOD("_test_output_flood", AndroidJava28.listOf("/system/bin/toybox", "yes"), false, false, false, true),
        TEST_SERVICE_DEATH("_test_service_death", AndroidJava28.listOf("/system/bin/toybox", "true"), false, false, false, true);

        final String wireName;
        final boolean acceptsStdin;
        final boolean requiresArgument;
        final boolean textInput;
        final boolean testOnly;
        private final List<String> baseArgv;

        Command(String wireName, List<String> baseArgv, boolean acceptsStdin,
                boolean requiresArgument, boolean textInput, boolean testOnly) {
            this.wireName = wireName;
            this.baseArgv = baseArgv;
            this.acceptsStdin = acceptsStdin;
            this.requiresArgument = requiresArgument;
            this.textInput = textInput;
            this.testOnly = testOnly;
        }

        List<String> argv() { return baseArgv; }
        boolean isTestOnly() { return testOnly; }
    }

    static final class Request {
        final Command command;
        final String argument;
        private final byte[] input;

        private Request(Command command, String argument, byte[] input) {
            this.command = command;
            this.argument = argument;
            this.input = input.clone();
        }

        static Request of(Command command, String argument, byte[] input) {
            if (command == null) throw new IllegalArgumentException("Missing command");
            byte[] bytes = input == null ? new byte[0] : input.clone();
            if (bytes.length > MAX_STDIN_BYTES || (!command.acceptsStdin && bytes.length != 0)) {
                throw new IllegalArgumentException("Command input exceeds its declared scope");
            }
            if (command.textInput) requireUtf8Text(bytes);
            if (command.requiresArgument) requireLiteral(argument);
            else if (argument != null && !argument.isEmpty()) {
                throw new IllegalArgumentException("This command accepts no argument");
            }
            return new Request(command, command.requiresArgument ? argument : null, bytes);
        }

        static Request fromWire(String name, String argument, byte[] input) {
            Command command = IsolatedLinuxCommandPolicy.fromWire(name);
            if (command == null) return null;
            try { return of(command, argument, input); }
            catch (IllegalArgumentException invalid) { return null; }
        }

        byte[] input() { return input.clone(); }

        List<String> argv() {
            if (!command.requiresArgument) return command.argv();
            List<String> argv = new ArrayList<>(command.argv());
            argv.add(argument);
            return AndroidJava28.copyList(argv);
        }
    }

    static Command fromWire(String name) {
        if (name == null) return null;
        for (Command command : Command.values()) {
            if (command.wireName.equals(name)) return command;
        }
        return null;
    }

    private static void requireLiteral(String value) {
        if (value == null || value.isEmpty()) throw new IllegalArgumentException("A literal is required");
        for (int offset = 0; offset < value.length(); ) {
            int point = value.codePointAt(offset);
            if (point < 0x20 || point == 0x7f) {
                throw new IllegalArgumentException("Control characters are not allowed in literals");
            }
            offset += Character.charCount(point);
        }
        try {
            ByteBuffer encoded = StandardCharsets.UTF_8.newEncoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .encode(CharBuffer.wrap(value));
            if (encoded.remaining() > MAX_ARGUMENT_BYTES) {
                throw new IllegalArgumentException("Literal exceeds the byte limit");
            }
        } catch (CharacterCodingException malformed) {
            throw new IllegalArgumentException("Literal is not valid UTF-8", malformed);
        }
    }

    private static void requireUtf8Text(byte[] bytes) {
        try {
            StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes));
            for (byte item : bytes) {
                if (item == 0) throw new IllegalArgumentException("NUL is not allowed in text input");
            }
        } catch (CharacterCodingException malformed) {
            throw new IllegalArgumentException("Command input is not valid UTF-8", malformed);
        }
    }

    private IsolatedLinuxCommandPolicy() { }
}
