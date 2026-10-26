package com.minnnng.dsh_android;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Set;

/** Plain JVM semantics check; Android API presence still needs an API 28 device. */
public final class AndroidJava28Test {
    public static void main(String[] args) {
        List<String> mutable = new ArrayList<>(Arrays.asList("one", "two"));
        List<String> snapshot = AndroidJava28.copyList(mutable);
        mutable.set(0, "changed");
        require(snapshot.equals(Arrays.asList("one", "two")));
        rejectedMutation(() -> snapshot.add("three"));
        require(AndroidJava28.listOf().isEmpty());
        rejectedNull(() -> AndroidJava28.listOf("one", null));
        rejectedNull(() -> AndroidJava28.copyList(Arrays.asList("one", null)));

        Set<String> set = AndroidJava28.copySet(Arrays.asList("one", "one", "two"));
        require(set.size() == 2);
        rejectedMutation(() -> set.add("three"));
        require(AndroidJava28.setOf().isEmpty());
        try { AndroidJava28.setOf("one", "one"); throw new AssertionError("duplicate accepted"); }
        catch (IllegalArgumentException expected) { /* Matches Set.of duplicate rejection. */ }
        rejectedNull(() -> AndroidJava28.copySet(Arrays.asList("one", null)));

        require(AndroidJava28.isBlank("\u2003\t"));
        require(!AndroidJava28.isBlank("\u00a0"));
        require(!AndroidJava28.isBlank("x"));
        System.out.println("AndroidJava28Test passed");
    }

    private static void require(boolean condition) {
        if (!condition) throw new AssertionError("API 28 collection semantics changed");
    }
    private static void rejectedMutation(Runnable action) {
        try { action.run(); throw new AssertionError("mutable snapshot accepted"); }
        catch (UnsupportedOperationException expected) { }
    }
    private static void rejectedNull(Runnable action) {
        try { action.run(); throw new AssertionError("null accepted"); }
        catch (NullPointerException expected) { }
    }
}
