package com.minnnng.dsh_android;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collection;
import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Objects;
import java.util.Set;

/** Java collection and String operations available without core-library desugaring on API 28. */
final class AndroidJava28 {
    private AndroidJava28() { }

    @SafeVarargs
    static <T> List<T> listOf(T... values) {
        return copyList(Arrays.asList(Objects.requireNonNull(values)));
    }

    static <T> List<T> copyList(Collection<? extends T> values) {
        Objects.requireNonNull(values);
        ArrayList<T> copy = new ArrayList<>(values.size());
        for (T value : values) copy.add(Objects.requireNonNull(value));
        return Collections.unmodifiableList(copy);
    }

    @SafeVarargs
    static <T> Set<T> setOf(T... values) {
        Objects.requireNonNull(values);
        LinkedHashSet<T> copy = new LinkedHashSet<>();
        for (T value : values) {
            if (!copy.add(Objects.requireNonNull(value))) {
                throw new IllegalArgumentException("Duplicate set element");
            }
        }
        return Collections.unmodifiableSet(copy);
    }

    static <T> Set<T> copySet(Collection<? extends T> values) {
        Objects.requireNonNull(values);
        LinkedHashSet<T> copy = new LinkedHashSet<>();
        for (T value : values) copy.add(Objects.requireNonNull(value));
        return Collections.unmodifiableSet(copy);
    }

    static boolean isBlank(String value) {
        Objects.requireNonNull(value);
        for (int offset = 0; offset < value.length();) {
            int point = value.codePointAt(offset);
            if (!Character.isWhitespace(point)) return false;
            offset += Character.charCount(point);
        }
        return true;
    }
}
