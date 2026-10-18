package pzext.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodType;
import java.util.Arrays;

/**
 * {@code PZExtAPI.squares.path}: the cheapest way over squares of one level from one square to another (docs/design.md,
 * "Squares"), found in Java. A mod that lays a pipe or a cable round what is in the way asks for hundreds of squares of search, each
 * a few game calls; in Lua that is a table and a closure call for every one.
 *
 * <p>The search is A* over states of a square and the direction it was entered by (so that a turn can cost), inside the box of the two
 * ends grown by {@code margin}; the heuristic is the Manhattan distance times the cheapest step, which no step undercuts. Steps are
 * to the four squares beside. A step onto a square costs {@code cost.outside}, or {@code cost.inside} when the square belongs to a
 * building as the meta grid says (the room at the square, as {@code buildings.at} asks it: loaded or not); a step onto the goal costs 1.
 * One the game blocks ({@code from:isBlockedTo(to)}, both squares loaded) adds {@code cost.blocked} to the step's cost; a change of
 * direction adds {@code cost.turn}, and with {@code into} so does a last step in another direction than it. A loaded square must meet
 * {@code pass}; one that is not loaded is taken as open ground, and so are the two ends, which a mod chose and which are not asked of
 * the filter. The search keeps primitive arrays that a call reuses, so a call allocates only its result.
 */
final class SquarePaths {
    /** The most squares in the search box (as the other queries' bound), and the widest margin. */
    static final int MAX_SQUARES = 250_000, MAX_MARGIN = 64, DEFAULT_MARGIN = 12;
    static final String KEY = "squarePathGeneration";
    private static final String AREA = "PZExtAPI.squares.path";
    private static final double COST_LIMIT = 1e12;
    private static final Object[] NO_WAY = { null };
    // Steps by direction 1..4 (0 is the start, entered by none).
    private static final int[] STEP_X = { 0, 1, -1, 0, 0 }, STEP_Y = { 0, 0, 0, 1, -1 };
    // States kept for the next call; a larger search is let go after its call.
    private static final int RETAIN = 1 << 20;

    private final Kahlua lua;
    private final Game game;
    private final Generation generation;
    private final Class<?> squareType;
    // IsoGridSquare.isBlockedTo(to); IsoMetaGrid.getRoomAt(x, y, z).
    private final MethodHandle blocked, roomAt;

    // The call's: costs, the box, the ends, the squares' state.
    private double[] dist = new double[0], enter = new double[0], heapCost = new double[0];
    private int[] from = new int[0], heapState = new int[0];
    private byte[] edge = new byte[0];
    private Object[] squares = new Object[0];
    private int heapSize;
    private double outsideCost, insideCost, blockedCost, turnCost, stepMin;
    private int minX, minY, maxX, maxY, height, level, goalX, goalY, startX, startY, into;
    private Object cell, meta;
    private SquareFilter pass;

    SquarePaths(Kahlua lua, Game game, Object meta, ClassLoader loader) throws ReflectiveOperationException {
        this.lua = lua;
        this.game = game;
        generation = new Generation(lua, meta, KEY);
        squareType = Game.type(loader, "zombie.iso.IsoGridSquare");
        blocked = Game.exact(squareType.getMethod("isBlockedTo", squareType), MethodType.methodType(boolean.class, Object.class, Object.class));
        roomAt = Game.exact(Game.type(loader, "zombie.iso.IsoMetaGrid").getMethod("getRoomAt", int.class, int.class, int.class),
            MethodType.methodType(Object.class, Object.class, int.class, int.class, int.class));
    }

    /** Sets the function into the squares' table (which the square watches fill as well). */
    void register(Object table) throws ReflectiveOperationException {
        generation.start();
        lua.set(table, "path", lua.function(AREA, arguments -> {
            generation.check(AREA);
            return path(arguments);
        }));
    }

    private synchronized Object[] path(Object[] arguments) throws ReflectiveOperationException {
        int[] start = end(arguments, 0, "from"), goal = end(arguments, 1, "to");
        Object options = arguments.length > 2 ? arguments[2] : null;
        if (options != null && !lua.isTable(options)) throw new IllegalArgumentException(AREA + ": options must be a table");
        int margin = DEFAULT_MARGIN;
        SquareFilter filter = null;
        double outside = 1, inside = 1, blockedBy = 0, turn = 0;
        int heading = 0;
        if (options != null) {
            Object value = lua.get(options, "margin");
            if (value != null) {
                if (!(value instanceof Double number) || number != Math.rint(number) || number < 0 || number > MAX_MARGIN)
                    throw new IllegalArgumentException(AREA + ": options.margin must be a whole number from 0 to " + MAX_MARGIN);
                margin = number.intValue();
            }
            heading = heading(lua.get(options, "into"));
            filter = SquareFilter.read(lua, game, lua.get(options, "pass"), AREA + " (options.pass)");
            Object costs = lua.get(options, "cost");
            if (costs != null) {
                if (!lua.isTable(costs)) throw new IllegalArgumentException(AREA + ": options.cost must be a table");
                outside = cost(costs, "outside", outside);
                inside = cost(costs, "inside", inside);
                blockedBy = cost(costs, "blocked", blockedBy);
                turn = cost(costs, "turn", turn);
            }
        }
        // Squares of one level only: another level has no way, as no step leaves the level.
        if (start[2] != goal[2]) return NO_WAY;
        long width = (long)Math.abs(start[0] - goal[0]) + 1 + 2L * margin, tall = (long)Math.abs(start[1] - goal[1]) + 1 + 2L * margin;
        if (width * tall > MAX_SQUARES)
            throw new IllegalArgumentException(AREA + ": the box has " + width * tall + " squares; at most " + MAX_SQUARES);
        outsideCost = outside; insideCost = inside; blockedCost = blockedBy; turnCost = turn;
        double cheapest = Math.min(Math.min(outside, inside), 1);
        stepMin = Double.isInfinite(cheapest) ? 0 : cheapest;
        startX = start[0]; startY = start[1]; goalX = goal[0]; goalY = goal[1]; level = start[2];
        minX = Math.min(startX, goalX) - margin; maxX = Math.max(startX, goalX) + margin;
        minY = Math.min(startY, goalY) - margin; maxY = Math.max(startY, goalY) + margin;
        height = maxY - minY + 1;
        int cells = (int)(width * tall);
        pass = filter;
        into = heading;
        cell = game.cell();
        meta = game.metaGrid();
        try {
            prepare(cells);
            int found = search();
            if (found < 0) return NO_WAY;
            return new Object[] { result(found), dist[found] };
        } catch (Throwable failure) {
            throw Game.thrown(failure);
        } finally {
            Arrays.fill(squares, 0, Math.min(cells, squares.length), null);
            pass = null;
            cell = null;
            meta = null;
            if (dist.length > RETAIN) release();
        }
    }

    /** A square or a table {@code x, y, z} as {@code x, y, z}. */
    private int[] end(Object[] arguments, int index, String name) throws ReflectiveOperationException {
        Object value = index < arguments.length ? arguments[index] : null;
        if (squareType.isInstance(value)) return new int[] { game.x(value), game.y(value), game.z(value) };
        if (lua.isTable(value)) {
            int[] result = new int[3];
            String[] keys = { "x", "y", "z" };
            for (int at = 0; at < 3; at++) {
                if (!(lua.get(value, keys[at]) instanceof Double number) || number != Math.rint(number)
                        || Math.abs(number) > SquareWatches.MAX_COORDINATE)
                    throw new IllegalArgumentException(AREA + ": " + name + "." + keys[at] + " must be a whole number");
                result[at] = number.intValue();
            }
            return result;
        }
        throw new IllegalArgumentException(AREA + ": " + name + " must be a square or a table with x, y and z");
    }

    /** The direction index of {@code into = { dx =, dy = }} (1 east, 2 west, 3 south, 4 north), 0 for none. */
    private int heading(Object into) throws ReflectiveOperationException {
        if (into == null) return 0;
        if (!lua.isTable(into) || !(lua.get(into, "dx") instanceof Double dx) || !(lua.get(into, "dy") instanceof Double dy)
                || Math.abs(dx) + Math.abs(dy) != 1 || dx != Math.rint(dx) || dy != Math.rint(dy))
            throw new IllegalArgumentException(AREA + ": options.into must be { dx =, dy = } for one step: (1, 0), (-1, 0), (0, 1) or (0, -1)");
        return dx > 0 ? 1 : dx < 0 ? 2 : dy > 0 ? 3 : 4;
    }

    private double cost(Object costs, String name, double fallback) throws ReflectiveOperationException {
        Object value = lua.get(costs, name);
        if (value == null) return fallback;
        if (!(value instanceof Double number) || !(number >= 0))
            throw new IllegalArgumentException(AREA + ": options.cost." + name + " must be a number, 0 or more (math.huge forbids it)");
        return number > COST_LIMIT ? Double.POSITIVE_INFINITY : number;
    }

    // ---- the search ----

    private void prepare(int cells) {
        int states = cells * 5;
        if (dist.length < states) { dist = new double[states]; from = new int[states]; }
        if (enter.length < cells) { enter = new double[cells]; squares = new Object[cells]; edge = new byte[cells * 4]; }
        Arrays.fill(dist, 0, states, Double.POSITIVE_INFINITY);
        Arrays.fill(enter, 0, cells, Double.NaN);
        Arrays.fill(edge, 0, cells * 4, (byte)0);
        heapSize = 0;
    }

    private void release() {
        dist = new double[0]; from = new int[0]; enter = new double[0]; squares = new Object[0]; edge = new byte[0];
        heapCost = new double[0]; heapState = new int[0];
    }

    /** The goal's state when a way is found, else -1. */
    private int search() throws Throwable {
        int origin = ((startX - minX) * height + startY - minY);
        squares[origin] = game.square(cell, startX, startY, level);
        enter[origin] = 0;
        int begin = origin * 5;
        dist[begin] = 0;
        push(heuristic(startX, startY), begin);
        while (heapSize > 0) {
            double estimate = heapCost[0];
            int state = heapState[0];
            pop();
            int index = state / 5, in = state - index * 5;
            int x = minX + index / height, y = minY + index % height;
            double cost = dist[state];
            if (estimate != cost + heuristic(x, y)) continue; // an older, dearer way to this state
            if (x == goalX && y == goalY) return state;
            for (int direction = 1; direction <= 4; direction++) {
                int nx = x + STEP_X[direction], ny = y + STEP_Y[direction];
                if (nx < minX || nx > maxX || ny < minY || ny > maxY) continue;
                int next = (nx - minX) * height + ny - minY;
                double step = enter[next];
                if (step != step) step = enter(next, nx, ny);
                if (step == Double.POSITIVE_INFINITY) continue;
                if (in != 0 && direction != in) step += turnCost;
                if (into != 0 && direction != into && nx == goalX && ny == goalY) step += turnCost;
                if (blockedCost > 0 && blocked(index, next, direction)) step += blockedCost;
                if (step == Double.POSITIVE_INFINITY) continue;
                double total = cost + step;
                int nextState = next * 5 + direction;
                if (total < dist[nextState]) {
                    dist[nextState] = total;
                    from[nextState] = state;
                    push(total + heuristic(nx, ny), nextState);
                }
            }
        }
        return -1;
    }

    /** The cheapest cost of the rest of the way: the steps left, if each cost the cheapest step. */
    private double heuristic(int x, int y) { return stepMin * (Math.abs(x - goalX) + Math.abs(y - goalY)); }

    /** What a step onto the square costs (infinity: it may not be stepped on), worked out once a call. */
    private double enter(int index, int x, int y) throws Throwable {
        Object square = game.square(cell, x, y, level);
        squares[index] = square;
        double cost;
        if (x == goalX && y == goalY) cost = 1;
        else if (square != null && pass != null && !(x == startX && y == startY) && !pass.test(square)) cost = Double.POSITIVE_INFINITY;
        else cost = meta != null && (Object)roomAt.invokeExact(meta, x, y, level) != null ? insideCost : outsideCost;
        enter[index] = cost;
        return cost;
    }

    /** Whether the game blocks the step between two squares both loaded, asked once for each. */
    private boolean blocked(int index, int next, int direction) throws Throwable {
        int slot = index * 4 + direction - 1;
        byte known = edge[slot];
        if (known == 0) {
            Object here = squares[index], there = squares[next];
            known = here != null && there != null && (boolean)blocked.invokeExact(here, there) ? (byte)2 : (byte)1;
            edge[slot] = known;
        }
        return known == 2;
    }

    /** The way to the goal state as x, y, x, y, ... from the start. */
    private Object result(int goal) throws ReflectiveOperationException {
        int count = 0;
        for (int state = goal;; state = from[state]) {
            count++;
            if (state / 5 == ((startX - minX) * height + startY - minY)) break;
        }
        Object table = lua.table();
        int state = goal;
        for (int at = count - 1; at >= 0; at--) {
            int index = state / 5;
            lua.set(table, (double)(2 * at + 1), (double)(minX + index / height));
            lua.set(table, (double)(2 * at + 2), (double)(minY + index % height));
            state = from[state];
        }
        return table;
    }

    // ---- the heap of states by estimated cost (a binary heap of two arrays) ----

    private void push(double cost, int state) {
        if (heapSize == heapCost.length) {
            int size = Math.max(256, heapSize * 2);
            heapCost = Arrays.copyOf(heapCost, size);
            heapState = Arrays.copyOf(heapState, size);
        }
        int at = heapSize++;
        while (at > 0) {
            int parent = (at - 1) >> 1;
            if (heapCost[parent] <= cost) break;
            heapCost[at] = heapCost[parent]; heapState[at] = heapState[parent];
            at = parent;
        }
        heapCost[at] = cost; heapState[at] = state;
    }

    private void pop() {
        int last = --heapSize;
        if (last == 0) return;
        double cost = heapCost[last];
        int state = heapState[last];
        int at = 0;
        while (true) {
            int child = 2 * at + 1;
            if (child >= last) break;
            if (child + 1 < last && heapCost[child + 1] < heapCost[child]) child++;
            if (heapCost[child] >= cost) break;
            heapCost[at] = heapCost[child]; heapState[at] = heapState[child];
            at = child;
        }
        heapCost[at] = cost; heapState[at] = state;
    }
}
