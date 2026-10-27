package com.minnnng.dsh_android;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Host JVM framing tests; Linux boot and execution are separately verified on-device. */
public final class LinuxVmConsoleTest {
    public static void main(String[] args) {
        LinuxVmConsole console = new LinuxVmConsole("echo hello\nexit 7");
        String script = input(console);
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
