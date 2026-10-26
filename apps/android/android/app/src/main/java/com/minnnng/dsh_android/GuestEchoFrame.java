package com.minnnng.dsh_android;

import java.nio.CharBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;

/** Canonical JSON for the sole admitted diagnostic binding; this is not a script parser. */
public final class GuestEchoFrame {
    public static final int MAX_FRAME_BYTES = 8192;
    public static final int MAX_TEXT_BYTES = 4096;
    private static final String REQUEST = "{\"version\":1,\"binding\":\"diagnostic.echo\",\"input\":{\"text\":\"";
    private static final String BROKER_RESULT = "{\"version\":1,\"value\":{\"text\":\"";
    private static final String COMPLETION = "{\"version\":1,\"result\":{\"text\":\"";
    private static final String END = "\"}}";
    private static final char[] HEX = "0123456789abcdef".toCharArray();

    private GuestEchoFrame() {}

    public static String request(String raw) { return parse(raw, REQUEST); }
    public static String brokerResult(String raw) { return parse(raw, BROKER_RESULT); }
    public static String completion(String raw) { return parse(raw, COMPLETION); }
    public static String requestForText(String text) { return frame(REQUEST, text); }
    public static String brokerResultForText(String text) { return frame(BROKER_RESULT, text); }
    public static String completionForText(String text) { return frame(COMPLETION, text); }

    private static String frame(String prefix, String text) {
        if (strictUtf8(text).length > MAX_TEXT_BYTES) throw new IllegalArgumentException("Guest text exceeds 4 KiB");
        StringBuilder out = new StringBuilder(prefix);
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            switch (c) {
                case '"' -> out.append("\\\"");
                case '\\' -> out.append("\\\\");
                case '\b' -> out.append("\\b");
                case '\f' -> out.append("\\f");
                case '\n' -> out.append("\\n");
                case '\r' -> out.append("\\r");
                case '\t' -> out.append("\\t");
                default -> {
                    if (c < 0x20) {
                        out.append("\\u00").append(HEX[c >> 4]).append(HEX[c & 0xf]);
                    } else out.append(c);
                }
            }
        }
        out.append(END);
        String raw = out.toString();
        if (strictUtf8(raw).length > MAX_FRAME_BYTES) throw new IllegalArgumentException("Guest JSON exceeds 8 KiB");
        return raw;
    }

    private static String parse(String raw, String prefix) {
        if (raw == null || strictUtf8(raw).length > MAX_FRAME_BYTES ||
                !raw.startsWith(prefix) || !raw.endsWith(END)) {
            throw new IllegalArgumentException("Guest JSON is not an admitted frame");
        }
        String encoded = raw.substring(prefix.length(), raw.length() - END.length());
        StringBuilder text = new StringBuilder(encoded.length());
        for (int i = 0; i < encoded.length(); i++) {
            char c = encoded.charAt(i);
            if (c == '"' || c < 0x20) throw new IllegalArgumentException("Invalid guest JSON string");
            if (c != '\\') {
                text.append(c);
                continue;
            }
            if (++i >= encoded.length()) throw new IllegalArgumentException("Incomplete guest JSON escape");
            switch (encoded.charAt(i)) {
                case '"' -> text.append('"');
                case '\\' -> text.append('\\');
                case 'b' -> text.append('\b');
                case 'f' -> text.append('\f');
                case 'n' -> text.append('\n');
                case 'r' -> text.append('\r');
                case 't' -> text.append('\t');
                case 'u' -> {
                    if (i + 4 >= encoded.length()) throw new IllegalArgumentException("Incomplete Unicode escape");
                    int value = 0;
                    for (int j = 0; j < 4; j++) {
                        int digit = Character.digit(encoded.charAt(++i), 16);
                        if (digit < 0) throw new IllegalArgumentException("Invalid Unicode escape");
                        value = (value << 4) | digit;
                    }
                    text.append((char) value);
                }
                default -> throw new IllegalArgumentException("Unsupported guest JSON escape");
            }
        }
        String decoded = text.toString();
        if (!frame(prefix, decoded).equals(raw)) throw new IllegalArgumentException("Guest JSON is not canonical");
        return decoded;
    }

    private static byte[] strictUtf8(String value) {
        try {
            var encoder = StandardCharsets.UTF_8.newEncoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT);
            var encoded = encoder.encode(CharBuffer.wrap(value));
            byte[] bytes = new byte[encoded.remaining()];
            encoded.get(bytes);
            return bytes;
        } catch (CharacterCodingException error) {
            throw new IllegalArgumentException("Guest text contains malformed UTF-16", error);
        }
    }
}
