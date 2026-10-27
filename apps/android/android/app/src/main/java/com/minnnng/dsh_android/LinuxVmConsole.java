package com.minnnng.dsh_android;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.UUID;

/** Bounded serial transcript for one boot, shell invocation, and guest shutdown. */
final class LinuxVmConsole {
    static final int MAX_COMMAND_BYTES = 32 * 1024;
    static final int MAX_OUTPUT_BYTES = 64 * 1024;
    private static final int MAX_LINE_BYTES = MAX_OUTPUT_BYTES + 256;
    private final String marker = "DSH-" + UUID.randomUUID();
    private final byte[] input;
    private final ByteArrayOutputStream line = new ByteArrayOutputStream();
    private final ByteArrayOutputStream output = new ByteArrayOutputStream();
    private int inputOffset;
    private boolean started;
    private boolean truncated;
    private Integer exitCode;

    LinuxVmConsole(String command) {
        this(command, false, false);
    }

    LinuxVmConsole(String command, boolean workspace, boolean workspaceFresh) {
        byte[] bytes = command.getBytes(StandardCharsets.UTF_8);
        if (bytes.length == 0 || bytes.length > MAX_COMMAND_BYTES || command.indexOf('\0') >= 0)
            throw new IllegalArgumentException("Invalid Linux VM command");
        String encoded = Base64.getEncoder().encodeToString(bytes);
        String delimiter = "DSH_SCRIPT_" + UUID.randomUUID().toString().replace("-", "");
        StringBuilder script = new StringBuilder("stty -echo; exec /bin/sh /dev/hvc0\n");
        script.append("mount -t proc proc /proc 2>/dev/null\n")
            .append("mount -t sysfs sysfs /sys 2>/dev/null\n")
            .append("mkdir -p /workspace\n")
            .append("cat > /tmp/dsh-command.b64 <<'").append(delimiter).append("'\n");
        // Linux canonical TTY input has a per-line bound. A large command is
        // transported as short base64 lines, never as one oversized shell line.
        for (int offset = 0; offset < encoded.length(); offset += 512)
            script.append(encoded, offset, Math.min(offset + 512, encoded.length())).append('\n');
        script.append(delimiter).append('\n')
            .append("base64 -d /tmp/dsh-command.b64 > /tmp/dsh-command.sh\n")
            .append("printf '\\n").append(marker).append(":BEGIN\\n'\n")
            .append("dsh_setup=0\n");
        if (workspace) {
            if (workspaceFresh) script.append("mkfs.ext2 -F /dev/vdb >/tmp/dsh-workspace-format.log 2>&1 || { cat /tmp/dsh-workspace-format.log; dsh_setup=125; }\n");
            script.append("if [ \"$dsh_setup\" -eq 0 ]; then mount -t ext2 /dev/vdb /workspace || dsh_setup=125; fi\n");
        }
        script.append("if [ \"$dsh_setup\" -eq 0 ]; then\n")
            .append("mkdir -p /workspace/.home\nexport HOME=/workspace/.home\n")
            .append("(cd /workspace && /bin/sh /tmp/dsh-command.sh) </dev/null\ndsh_status=$?\n")
            .append("else dsh_status=$dsh_setup; fi\nsync\n");
        if (workspace) script.append("umount /workspace 2>/dev/null\n");
        script
            .append("printf '\\n").append(marker).append(":END:%s\\n' \"$dsh_status\"\n")
            .append("sync\n")
            .append("poweroff -f\n");
        input = script.toString().getBytes(StandardCharsets.UTF_8);
    }

    /** The emulator calls this only after VirtIO console reports input capacity. */
    synchronized int read(byte[] buffer, int capacity) {
        int length = Math.min(Math.min(buffer.length, capacity), input.length - inputOffset);
        if (length < 0) throw new IllegalArgumentException("Negative console capacity");
        System.arraycopy(input, inputOffset, buffer, 0, length);
        inputOffset += length;
        return length;
    }

    /** Serial output is untrusted data and cannot change host paths or execution authority. */
    synchronized void write(byte[] bytes) {
        for (byte item : bytes) {
            if (item == '\n') {
                consumeLine();
            } else if (item != '\r') {
                if (line.size() == MAX_LINE_BYTES) flushLongLine();
                line.write(item);
            }
        }
    }

    private void flushLongLine() {
        if (started && exitCode == null) append(line.toByteArray(), false);
        line.reset();
    }

    private void consumeLine() {
        byte[] bytes = line.toByteArray();
        line.reset();
        String value = new String(bytes, StandardCharsets.UTF_8);
        if (!started) {
            if (value.equals(marker + ":BEGIN")) started = true;
            return;
        }
        if (exitCode != null) return;
        String suffix = marker + ":END:";
        if (value.startsWith(suffix)) {
            String number = value.substring(suffix.length());
            if (number.matches("[0-9]{1,3}")) {
                int status = Integer.parseInt(number);
                if (status <= 255) { exitCode = status; return; }
            }
        }
        append(bytes, true);
    }

    private void append(byte[] bytes, boolean newline) {
        int remaining = MAX_OUTPUT_BYTES - output.size();
        int length = Math.min(remaining, bytes.length);
        output.write(bytes, 0, length);
        if (length != bytes.length) truncated = true;
        if (newline) {
            if (output.size() < MAX_OUTPUT_BYTES) output.write('\n');
            else truncated = true;
        }
    }

    synchronized String output() {
        // Malformed bytes expand to replacement characters. Apply the UTF-8
        // budget in one pass, including arbitrary binary command output.
        byte[] bytes = output.toByteArray();
        String result = new String(bytes, StandardCharsets.UTF_8);
        int end = 0, used = 0;
        while (end < result.length()) {
            int cp = result.codePointAt(end);
            int size = cp <= 0x7f ? 1 : cp <= 0x7ff ? 2 : cp <= 0xffff ? 3 : 4;
            if (size > MAX_OUTPUT_BYTES - used) { truncated = true; break; }
            used += size; end += Character.charCount(cp);
        }
        return end == result.length() ? result : result.substring(0, end);
    }
    synchronized boolean truncated() { return truncated; }
    synchronized Integer exitCode() { return exitCode; }
}
