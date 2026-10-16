package pzext.api;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.function.Consumer;

/**
 * The chunks that networks wait for to load (the squares of their consumers or producers that are not loaded), and which networks
 * wait for each: the grid looks at each distinct chunk once a pass, however many networks wait for it, and wakes those that wait for
 * one that has loaded since. Registered when a network is worked out; looked at on the game's thread.
 *
 * <p>A pass looks at {@link #BUDGET} chunks at most, going on from where the last stopped: the game loads a handful of chunks in a
 * frame, but a map with thousands of networks waits for thousands of chunks, which one second's look cannot afford to read
 * all of. With up to {@link #BUDGET} chunks waited for, every pass reads them all; with more, a chunk that loaded is found within
 * as many seconds as the registry has budgets.
 */
final class ChunkWaits {
    /** The most chunks one {@link #probe} reads. */
    static final int BUDGET = 1024;

    private final HashMap<Long, List<Network>> byChunk = new HashMap<>();
    private final HashMap<Network, long[]> chunksOf = new HashMap<>();
    // The registry as flat arrays for the look (made again after it changed), and where the next look starts.
    private long[] keys = new long[0];
    private List<Network>[] waiting = newArray(0);
    private boolean flat = true;
    private int cursor;

    @SuppressWarnings("unchecked")
    private static List<Network>[] newArray(int size) { return (List<Network>[])new List<?>[size]; }

    /** The network waits for these chunks (and no others). */
    void set(Network network, long[] chunks) {
        long[] before = chunksOf.get(network);
        if (before == null ? chunks.length == 0 : Arrays.equals(before, chunks)) return;
        remove(network);
        if (chunks.length == 0) return;
        chunksOf.put(network, chunks);
        for (long chunk : chunks) byChunk.computeIfAbsent(chunk, unused -> new ArrayList<>(1)).add(network);
        flat = false;
    }

    /** The network waits for nothing (it was removed, or replaced, or is worked out). */
    void remove(Network network) {
        long[] chunks = chunksOf.remove(network);
        if (chunks == null) return;
        for (long chunk : chunks) {
            List<Network> list = byChunk.get(chunk);
            if (list == null) continue;
            list.remove(network);
            if (list.isEmpty()) byChunk.remove(chunk);
        }
        flat = false;
    }

    void clear() {
        byChunk.clear();
        chunksOf.clear();
        flat = false;
    }

    int chunks() { return byChunk.size(); }

    /**
     * Calls {@code arrived} for the networks that wait for a chunk that is loaded now, and stops them waiting (they register
     * again as they are worked out). Allocates nothing while no chunk has loaded.
     */
    void probe(Game game, Object cells, Consumer<Network> arrived) throws ReflectiveOperationException {
        if (byChunk.isEmpty()) return;
        if (!flat) flatten();
        long[] keys = this.keys;
        int size = keys.length, looks = Math.min(size, BUDGET), at = cursor >= size ? 0 : cursor;
        ArrayList<Network> woken = null;
        for (int look = 0; look < looks; look++, at = at + 1 == size ? 0 : at + 1) {
            if (!game.chunkLoaded(cells, keys[at])) continue;
            if (woken == null) woken = new ArrayList<>();
            woken.addAll(waiting[at]);
        }
        cursor = at;
        if (woken == null) return;
        for (Network network : woken) remove(network);
        for (Network network : woken) arrived.accept(network);
    }

    private void flatten() {
        int size = byChunk.size();
        keys = new long[size];
        waiting = newArray(size);
        int at = 0;
        for (var entry : byChunk.entrySet()) {
            keys[at] = entry.getKey();
            waiting[at++] = entry.getValue();
        }
        flat = true;
    }
}
