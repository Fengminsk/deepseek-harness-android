package com.minnnng.dsh_android;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Host JVM framing tests; Linux boot and execution are separately verified on-device. */
public final class LinuxVmConsoleTest {
    public static void main(String[] args) {
        long before = System.currentTimeMillis() / 1000L;
        LinuxVmConsole console = new LinuxVmConsole("echo hello\nexit 7");
        String script = input(console);
        long after = System.currentTimeMillis() / 1000L;
        check(script.contains("export PATH=/bin:/usr/bin:/sbin:/usr/sbin\n"));
        check(script.indexOf("export PATH=") < script.indexOf("/bin/sh /tmp/dsh-command.sh"));
        Matcher clock = Pattern.compile("/bin/busybox date -u -s @([0-9]+) >/dev/null 2>&1").matcher(script);
        check(clock.find());
        long captured = Long.parseLong(clock.group(1));
        check(captured >= before && captured <= after);
        String fixedClock = input(new LinuxVmConsole("echo guest-command", true, true, 1793060921L));
        check(fixedClock.contains("/bin/busybox date -u -s @1793060921 "));
        check(fixedClock.indexOf("date -u -s @") < fixedClock.indexOf("mkfs.ext2"));
        check(fixedClock.indexOf("date -u -s @") < fixedClock.indexOf("/bin/sh /tmp/dsh-command.sh"));
        check(fixedClock.contains("clock initialization failed\\n'; dsh_setup=125; }"));
        check(fixedClock.contains("if [ \"$dsh_setup\" -eq 0 ]; then mkfs.ext2"));
        check(fixedClock.contains("if [ \"$dsh_setup\" -eq 0 ]; then\nmkdir -p /workspace/.home"));
        check(fixedClock.contains("else dsh_status=$dsh_setup; fi"));
        try { new LinuxVmConsole("echo forbidden", true, true, -1); throw new AssertionError(); }
        catch (IllegalArgumentException expected) { }
        Matcher marker = Pattern.compile("DSH-[a-f0-9-]+:BEGIN").matcher(script);
        check(marker.find());
        String prefix = marker.group().replace(":BEGIN", "");
        feed(console, "Linux boot log\n# " + script + "\n" + prefix + ":BEGIN\r\n");
        feed(console, "hello\r\nnot-a-marker:END:0\n" + prefix + ":END:7\nshutdown log\n");
        check(console.exitCode() == 7);
        check(console.output().equals("hello\nnot-a-marker:END:0\n"));
        check(!console.truncated());

        LinuxVmConsole large = new LinuxVmConsole("x".repeat(32768));
        String transport = input(large);
        for (String line : transport.split("\n")) check(line.length() < 1024);
        Matcher largeMarker = Pattern.compile("DSH-[a-f0-9-]+:BEGIN").matcher(transport);
        check(largeMarker.find());
        String largePrefix = largeMarker.group().replace(":BEGIN", "");
        feed(large, largePrefix + ":BEGIN\n" + "汉".repeat(30000) + "\n" + largePrefix + ":END:0\n");
        check(large.exitCode() == 0);
        check(large.truncated());
        check(large.output().getBytes(StandardCharsets.UTF_8).length <= LinuxVmConsole.MAX_OUTPUT_BYTES);
        LinuxVmConsole binary = new LinuxVmConsole("binary output");
        Matcher binaryMarker = Pattern.compile("DSH-[a-f0-9-]+:BEGIN").matcher(input(binary));
        check(binaryMarker.find());
        String binaryPrefix = binaryMarker.group().replace(":BEGIN", "");
        feed(binary, binaryPrefix + ":BEGIN\n");
        byte[] invalidUtf8 = new byte[LinuxVmConsole.MAX_OUTPUT_BYTES];
        java.util.Arrays.fill(invalidUtf8, (byte) 0xff);
        binary.write(invalidUtf8);
        feed(binary, "\n" + binaryPrefix + ":END:0\n");
        check(binary.output().getBytes(StandardCharsets.UTF_8).length <= LinuxVmConsole.MAX_OUTPUT_BYTES);
        check(binary.output().codePointCount(0, binary.output().length()) == LinuxVmConsole.MAX_OUTPUT_BYTES / 3);
        check(binary.truncated() && binary.exitCode() == 0);
        LinuxVmConsole network = new LinuxVmConsole("true");
        var polls = new java.util.concurrent.atomic.AtomicInteger();
        long interpreter = Thread.currentThread().getId();
        network.attachInterpreterPoll(() -> {
            check(Thread.currentThread().getId() == interpreter);
            polls.incrementAndGet();
        });
        input(network);
        int exhausted = polls.get();
        check(exhausted > 1 && network.read(new byte[1], 1) == 0 && polls.get() == exhausted + 1);
        try { network.attachInterpreterPoll(() -> { }); throw new AssertionError(); }
        catch (IllegalStateException expected) { }
        System.out.println("Linux VM console framing: PASS");
    }
    private static String input(LinuxVmConsole console) {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        byte[] chunk = new byte[97];
        int read;
        while ((read = console.read(chunk, 31)) != 0) bytes.write(chunk, 0, read);
        return bytes.toString(StandardCharsets.UTF_8);
    }
    private static void feed(LinuxVmConsole console, String value) {
        byte[] bytes = value.getBytes(StandardCharsets.UTF_8);
        for (byte item : bytes) console.write(new byte[] { item });
    }
    private static void check(boolean value) { if (!value) throw new AssertionError(); }
}
