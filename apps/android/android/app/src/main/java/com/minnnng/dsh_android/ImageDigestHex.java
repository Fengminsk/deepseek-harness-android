package com.minnnng.dsh_android;

/** Lowercase digest encoding without Android API-level dependent java.util.HexFormat. */
final class ImageDigestHex {
    private static final char[] DIGITS = "0123456789abcdef".toCharArray();

    private ImageDigestHex() { }

    static String encode(byte[] bytes) {
        char[] output = new char[bytes.length * 2];
        for (int index = 0; index < bytes.length; index++) {
            int value = bytes[index] & 0xff;
            output[index * 2] = DIGITS[value >>> 4];
            output[index * 2 + 1] = DIGITS[value & 0x0f];
        }
        return new String(output);
    }
}
