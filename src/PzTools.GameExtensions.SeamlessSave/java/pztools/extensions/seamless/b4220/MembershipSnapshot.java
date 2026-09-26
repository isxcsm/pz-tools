package pztools.extensions.seamless.b4220;

import java.io.IOException;
import java.util.*;

/** Detects structural transfers without mutating or waiting for the UI.
 * Values inside an item are not a whole-world transaction; membership and ownership are checked.
 */
final class MembershipSnapshot {
    @FunctionalInterface interface Read { Object get() throws Exception; }
    @FunctionalInterface private interface Check { boolean unchanged() throws Exception; }
    private final ArrayList<Check> checks = new ArrayList<>();
    private final long maximumBytes;
    private long bytes;
    MembershipSnapshot(long maximumBytes) { this.maximumBytes = maximumBytes; }
    long retainedBytes() { return bytes; }
    private void add(Check check, int entries) throws IOException {
        bytes = Math.addExact(bytes, 64L + 8L * entries);
        if (bytes > maximumBytes) throw new IOException("Chunk membership exceeds the capture budget");
        checks.add(check);
    }
    Object reference(Read read) throws Exception {
        Object expected = read.get();
        add(() -> read.get() == expected, 1);
        return expected;
    }
    Object[] list(Read read) throws Exception {
        Object value = read.get();
        if (!(value instanceof List<?> list)) throw new IOException("Unsupported serialized collection");
        // PZArrayList supports size/get but deliberately rejects iterator(), including inherited toArray().
        Object[] entries = new Object[list.size()];
        for (int i = 0; i < entries.length; i++) entries[i] = list.get(i);
        add(() -> {
            if (read.get() != list || list.size() != entries.length) return false;
            for (int i = 0; i < entries.length; i++) if (list.get(i) != entries[i]) return false;
            return true;
        }, entries.length);
        return entries;
    }
    Object[] array(Read read) throws Exception {
        Object value = read.get();
        if (value == null) { reference(read); return new Object[0]; }
        if (!(value instanceof Object[] array)) throw new IOException("Unsupported serialized array");
        Object[] entries = array.clone();
        add(() -> {
            if (read.get() != array || array.length != entries.length) return false;
            for (int i = 0; i < entries.length; i++) if (array[i] != entries[i]) return false;
            return true;
        }, entries.length);
        return array;
    }
    void value(Read read) throws Exception {
        Object value = read.get();
        add(() -> Objects.equals(value, read.get()), 1);
    }
    boolean unchanged() throws Exception {
        for (Check check : checks) if (!check.unchanged()) return false;
        return true;
    }
}
