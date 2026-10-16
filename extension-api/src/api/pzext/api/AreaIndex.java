package pzext.api;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import pzext.api.Members.Area;
import pzext.api.Network.Position;

/**
 * The squares of many networks' areas in one table, for the hooks: which of the networks (by their place in the list the
 * index was made from) have a square, in one box test and one hash probe whatever the number of networks. The areas' blocks
 * of 8 by 8 squares are merged: a block that several areas reach keeps the squares of each, in the order of the list.
 * Immutable; read on any thread without allocating; made on the game's thread.
 */
final class AreaIndex {
    static final AreaIndex EMPTY = new AreaIndex(SquareMap.EMPTY, new long[0][], new int[0][]);

    // Each block of squares to its entry: the members that reach it, in order, and the squares each reaches (one bit each).
    private final SquareMap blocks;
    private final long[][] bits;
    private final int[][] members;

    private AreaIndex(SquareMap blocks, long[][] bits, int[][] members) {
        this.blocks = blocks;
        this.bits = bits;
        this.members = members;
    }

    /**
     * The index of the areas (null for none) in the order given: a square is the member's when it is in the member's
     * rooms, or with {@code shelter} also in its shell (Members.Area).
     */
    static AreaIndex of(List<Area> areas, boolean shelter) {
        var found = new HashMap<Position, ArrayList<long[]>>();
        for (int member = 0; member < areas.size(); member++) {
            Area area = areas.get(member);
            if (area == null) continue;
            final int each = member;
            area.blocks().forEach((x, y, z, value) -> add(found, x, y, z, each, value));
            if (shelter) area.shell().forEach((x, y, z, value) -> add(found, x, y, z, each, value));
        }
        if (found.isEmpty()) return EMPTY;
        var slots = new HashMap<Position, Long>();
        var entryBits = new ArrayList<long[]>();
        var entryMembers = new ArrayList<int[]>();
        for (var block : found.entrySet()) {
            slots.put(block.getKey(), (long)entryBits.size());
            var list = block.getValue();
            long[] squares = new long[list.size()];
            int[] who = new int[list.size()];
            for (int at = 0; at < squares.length; at++) { who[at] = (int)list.get(at)[0]; squares[at] = list.get(at)[1]; }
            entryBits.add(squares);
            entryMembers.add(who);
        }
        return new AreaIndex(new SquareMap(slots), entryBits.toArray(long[][]::new), entryMembers.toArray(int[][]::new));
    }

    /** The member's squares of the block, ORed into what it has there already (it is the last of the block's list). */
    private static void add(HashMap<Position, ArrayList<long[]>> found, int x, int y, int z, int member, long value) {
        ArrayList<long[]> list = found.computeIfAbsent(new Position(x, y, z), unused -> new ArrayList<>(1));
        if (!list.isEmpty() && list.get(list.size() - 1)[0] == member) list.get(list.size() - 1)[1] |= value;
        else list.add(new long[] { member, value });
    }

    boolean isEmpty() { return blocks.isEmpty(); }

    /** Whether any member has the square. */
    boolean any(int x, int y, int z) { return next(x, y, z, -1) >= 0; }

    /**
     * The first member after {@code after} (-1 for the first of all) that has the square, or -1: so that a caller goes over the
     * members that have it in order, and stops at the first that suits.
     */
    int next(int x, int y, int z, int after) {
        int entry = (int)blocks.get(x >> 3, y >> 3, z, -1);
        if (entry < 0) return -1;
        long bit = 1L << ((y & 7) << 3 | x & 7);
        long[] squares = bits[entry];
        int[] who = members[entry];
        for (int at = 0; at < who.length; at++) if (who[at] > after && (squares[at] & bit) != 0) return who[at];
        return -1;
    }
}
