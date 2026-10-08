package pztools.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.lang.reflect.Field;
import java.util.ArrayList;
import java.util.IdentityHashMap;
import java.util.function.LongSupplier;

/**
 * {@code vision.hiddenZombieFix}: a zombie that stands where the player sees it, and that the game does not draw.
 *
 * <p>The game decides who is drawn in {@code IsoGameCharacter.updateSeenVisibility}: a zombie it does not find seen
 * gets the alpha it fades to set to 0. Some squares in the player's cone and view distance are not found seen
 * ({@code IsoGridSquare.isCanSee}) though nothing stands between them and the player. This looks at exactly those
 * zombies, once a frame, on the game's thread, in the game's own list: the ones the game does not draw, on the player's
 * floor or the floor above or below, inside the view distance and the vision cone the game uses for the shadows. For
 * such a zombie it draws a line from the player and, when nothing blocks it, sets the alpha the zombie fades to back to 1
 * every frame, as the game would have had it. The game's own working is not touched: only the alpha it fades to.
 *
 * <p>The line on the player's floor runs from the exact positions across the squares, and stops at a square edge the game
 * blocks vision at ({@code testVisionAdjacent}, as {@code LosUtil.lineClear} asks it); to the floor above or below it is
 * {@code LosUtil.lineClear}, which has the game's floors and stairs. Only a blocked result stops the line, as in the game.
 * What a line found is not kept for a square or a place: a zombie's line is drawn again 0.06 to 0.1 seconds after the
 * last, when the zombie is first looked at and from then on while it stays a candidate, so what is shown is never older
 * than 0.1 seconds (the starts differ from zombie to zombie, so that the lines are spread over the frames). A zombie that
 * is shown is also offered to {@code IsoPlayer.TestZombieSpotPlayer} every 0.1 to 0.5 seconds, as the game does for the
 * zombies it draws.
 *
 * <p>The cost is the filter: a pass over the zombies the cell holds, each asked one array read and, when it is not drawn,
 * its position. Nothing is allocated for a zombie that is not a candidate. Unlike the rest of the formulas it is not a
 * hook in the game's code: while no mod declares it, nothing runs.
 */
final class HiddenZombies {
    /** The clock, in nanoseconds; the tests set it. */
    static volatile LongSupplier clock = System::nanoTime;
    /** The lines drawn since the API started, for the tests and the measure; the game thread's. */
    static long rays;

    private static final long RAY_MIN = 60_000_000L, RAY_SPREAD = 40_000_000L, SPOT_MIN = 100_000_000L, SPOT_SPREAD = 400_000_000L;
    // A zombie that has not been a candidate for this many frames is forgotten at the next sweep.
    private static final int FORGET_AFTER = 8, SWEEP_EVERY = 64;

    private final Game game;
    private final Players players;
    // IsoCell.getZombieList(); and see Reads for what is asked of each zombie.
    private final MethodHandle zombiesOf;
    // IsoPlayer.TestZombieSpotPlayer(IsoMovingObject), IsoPlayer.getX(), getY(), getZ().
    private final MethodHandle spot, xOf, yOf, zOf;
    // IsoPlayer: isSeeEveryone(), isAsleep(), isDead(), getVehicle(), getLookVector(Vector2).
    private final MethodHandle seesAll, asleep, dead, vehicleOf, lookOf;
    // GameTime.getInstance().getViewDist(); LightingJNI's smoothed vision cone in degrees, which the lighting reads.
    private final MethodHandle timeOf, viewDist, cone;
    // IsoGridSquare.testVisionAdjacent(dx, dy, dz, boolean, boolean); LosUtil.lineClear(cell, x0, y0, z0, x1, y1, z1, boolean).
    private final MethodHandle vision, lineClear;
    private final Object blocked, vector;
    private final Field vectorX, vectorY;

    /** Whether a mod declares the fix; set from any thread, read by the frame. */
    private volatile boolean on;
    // The game thread's: what is known of each zombie that is a candidate, by player.
    private final IdentityHashMap<Object, Candidate>[] candidates;
    private int epoch;
    private long random = 0x9E3779B97F4A7C15L;

    // The loader Reads is built for: set by the first instance before Reads is first used.
    private static ClassLoader loading;

    /**
     * What the pass asks of each zombie, as handles that are constants: a call through one is built into the loop (the same
     * call through a handle in a field is not, and costs several times as much). They are made once for the game's loader;
     * an instance made for another one does not work.
     */
    private static final class Reads {
        static final ClassLoader LOADER = loading;
        // IsoMovingObject.getX(), getY(), getZ(); IsoGameCharacter.isVisibleToPlayer; IsoObject.setTargetAlpha(int, float).
        static final MethodHandle X, Y, Z, VISIBLE, ALPHA;

        static {
            try {
                Class<?> moving = Game.type(LOADER, "zombie.iso.IsoMovingObject"), object = Game.type(LOADER, "zombie.iso.IsoObject");
                var number = MethodType.methodType(float.class, Object.class);
                X = Game.exact(moving.getMethod("getX"), number);
                Y = Game.exact(moving.getMethod("getY"), number);
                Z = Game.exact(moving.getMethod("getZ"), number);
                VISIBLE = MethodHandles.publicLookup().unreflectGetter(Game.type(LOADER, "zombie.characters.IsoGameCharacter").getField("isVisibleToPlayer"))
                    .asType(MethodType.methodType(boolean[].class, Object.class));
                ALPHA = Game.exact(object.getMethod("setTargetAlpha", int.class, float.class),
                    MethodType.methodType(void.class, Object.class, int.class, float.class));
            } catch (ReflectiveOperationException failure) {
                throw new ExceptionInInitializerError(failure);
            }
        }
    }

    private static final class Candidate {
        long rayAt, spotAt;
        boolean clear;
        int seen;
    }

    @SuppressWarnings("unchecked")
    HiddenZombies(ClassLoader loader, Game game, Players players) throws ReflectiveOperationException, IllegalAccessException {
        this.game = game;
        this.players = players;
        synchronized (HiddenZombies.class) { if (loading == null) loading = loader; }
        if (Reads.LOADER != loader) throw new IllegalStateException("the zombie reads were built for another game loader");
        Class<?> cell = Game.type(loader, "zombie.iso.IsoCell"), moving = Game.type(loader, "zombie.iso.IsoMovingObject");
        Class<?> character = Game.type(loader, "zombie.characters.IsoGameCharacter");
        Class<?> player = Game.type(loader, "zombie.characters.IsoPlayer"), square = Game.type(loader, "zombie.iso.IsoGridSquare");
        Class<?> los = Game.type(loader, "zombie.iso.LosUtil"), results = Game.type(loader, "zombie.iso.LosUtil$TestResults");
        Class<?> time = Game.type(loader, "zombie.GameTime"), lighting = Game.type(loader, "zombie.iso.LightingJNI");
        Class<?> vectorType = Game.type(loader, "zombie.iso.Vector2");
        zombiesOf = Game.exact(cell.getMethod("getZombieList"), MethodType.methodType(ArrayList.class, Object.class));
        var number = MethodType.methodType(float.class, Object.class);
        xOf = Game.exact(moving.getMethod("getX"), number);
        yOf = Game.exact(moving.getMethod("getY"), number);
        zOf = Game.exact(moving.getMethod("getZ"), number);
        spot = Game.exact(player.getMethod("TestZombieSpotPlayer", moving), MethodType.methodType(void.class, Object.class, Object.class));
        var flag = MethodType.methodType(boolean.class, Object.class);
        seesAll = Game.exact(player.getMethod("isSeeEveryone"), flag);
        asleep = Game.exact(character.getMethod("isAsleep"), flag);
        dead = Game.exact(character.getMethod("isDead"), flag);
        vehicleOf = Game.exact(character.getMethod("getVehicle"), MethodType.methodType(Object.class, Object.class));
        lookOf = Game.exact(character.getMethod("getLookVector", vectorType), MethodType.methodType(Object.class, Object.class, Object.class));
        timeOf = Game.exact(time.getMethod("getInstance"), MethodType.methodType(Object.class));
        viewDist = Game.exact(time.getMethod("getViewDist"), number);
        // The degrees the lighting smooths over time and hands to the shadows: read, never asked for again by calculateVisionCone,
        // which moves the smoothing each time it is called.
        Field degrees = Game.accessible(lighting.getDeclaredField("visionConeLerp"));
        cone = MethodHandles.lookup().unreflectGetter(degrees).asType(MethodType.methodType(float.class));
        vision = Game.exact(square.getMethod("testVisionAdjacent", int.class, int.class, int.class, boolean.class, boolean.class),
            MethodType.methodType(Object.class, Object.class, int.class, int.class, int.class, boolean.class, boolean.class));
        lineClear = Game.exact(los.getMethod("lineClear", cell, int.class, int.class, int.class, int.class, int.class, int.class, boolean.class),
            MethodType.methodType(Object.class, Object.class, int.class, int.class, int.class, int.class, int.class, int.class, boolean.class));
        blocked = results.getField("Blocked").get(null);
        vector = vectorType.getConstructor().newInstance();
        vectorX = vectorType.getField("x");
        vectorY = vectorType.getField("y");
        candidates = new IdentityHashMap[players.all().length];
        for (int index = 0; index < candidates.length; index++) candidates[index] = new IdentityHashMap<>();
    }

    /** Whether a mod declares the fix. */
    void declare(boolean declared) { on = declared; }

    /** Each frame, on the game's thread. */
    void frame() throws Throwable {
        if (!on) { forget(); return; }
        Object cell = game.cell();
        if (cell == null) { forget(); return; }
        Object[] local = players.all();
        ArrayList<?> zombies = null;
        float view = 0;
        long now = clock.getAsLong();
        boolean sweep = ++epoch % SWEEP_EVERY == 0;
        for (int index = 0; index < local.length && index < candidates.length; index++) {
            Object who = local[index];
            if (who == null) continue;
            if (zombies == null) {
                zombies = (ArrayList<?>)zombiesOf.invokeExact(cell);
                view = (float)viewDist.invokeExact((Object)timeOf.invokeExact());
            }
            // Nobody sees in a sleep, in the grave or from a car (the cone then is the car's), and a player who sees everyone has it done.
            if (!(boolean)dead.invokeExact(who) && !(boolean)asleep.invokeExact(who) && !(boolean)seesAll.invokeExact(who)
                    && (Object)vehicleOf.invokeExact(who) == null)
                watch(index, who, cell, zombies, view, now);
            if (sweep) candidates[index].values().removeIf(known -> epoch - known.seen > FORGET_AFTER);
        }
    }

    private void forget() { for (var known : candidates) if (!known.isEmpty()) known.clear(); }

    private void watch(int index, Object who, Object cell, ArrayList<?> zombies, float view, long now) throws Throwable {
        float px = (float)xOf.invokeExact(who), py = (float)yOf.invokeExact(who);
        int pz = floor((float)zOf.invokeExact(who));
        float degrees = (float)cone.invokeExact();
        // The cone is the angle on both sides of where the player looks: a candidate is within half of it of that direction.
        boolean all = degrees >= 360f;
        Object look = (Object)lookOf.invokeExact(who, vector);
        float lx = vectorX.getFloat(look), ly = vectorY.getFloat(look);
        float length = (float)Math.sqrt(lx * lx + ly * ly);
        if (length == 0f) all = true;
        float cosine = (float)Math.cos(Math.toRadians(degrees * 0.5));
        float within = view * view;
        var known = candidates[index];
        for (int at = 0, count = zombies.size(); at < count; at++) {
            Object zombie = zombies.get(at);
            boolean[] drawn = (boolean[])Reads.VISIBLE.invokeExact(zombie);
            if (drawn[index]) continue;
            float zx = (float)Reads.X.invokeExact(zombie), zy = (float)Reads.Y.invokeExact(zombie);
            float dx = zx - px, dy = zy - py;
            float squared = dx * dx + dy * dy;
            if (squared > within) continue;
            int floor = floor((float)Reads.Z.invokeExact(zombie));
            if (floor - pz > 1 || pz - floor > 1) continue;
            if (!all && dx * lx + dy * ly < cosine * length * (float)Math.sqrt(squared)) continue;
            Candidate state = known.get(zombie);
            if (state == null) {
                state = new Candidate();
                state.rayAt = now;
                state.spotAt = now;
                known.put(zombie, state);
            }
            state.seen = epoch;
            if (now - state.rayAt >= 0) {
                state.clear = clear(cell, px, py, pz, zx, zy, floor);
                state.rayAt = now + RAY_MIN + (next() % RAY_SPREAD);
            }
            if (!state.clear) continue;
            Reads.ALPHA.invokeExact(zombie, index, 1f);
            if (now - state.spotAt >= 0) {
                spot.invokeExact(who, zombie);
                state.spotAt = now + SPOT_MIN + (next() % SPOT_SPREAD);
            }
        }
    }

    /** Whether nothing blocks the way from the player's place to the zombie's. */
    private boolean clear(Object cell, float px, float py, int pz, float zx, float zy, int zz) throws Throwable {
        rays++;
        int x = floor(px), y = floor(py), tx = floor(zx), ty = floor(zy);
        // Another floor: the game's own line, which knows the floors, stairs and openings between them.
        if (zz != pz) return (Object)lineClear.invokeExact(cell, x, y, pz, tx, ty, zz, false) != blocked;
        // The same floor: from the exact positions, square by square across the edges the line crosses.
        Object last = game.square(cell, x, y, pz);
        int lastX = x, lastY = y;
        float dx = zx - px, dy = zy - py;
        int stepX = dx > 0 ? 1 : -1, stepY = dy > 0 ? 1 : -1;
        float deltaX = dx == 0 ? Float.MAX_VALUE : 1f / Math.abs(dx), deltaY = dy == 0 ? Float.MAX_VALUE : 1f / Math.abs(dy);
        float nextX = dx == 0 ? Float.MAX_VALUE : (stepX > 0 ? x + 1 - px : px - x) * deltaX;
        float nextY = dy == 0 ? Float.MAX_VALUE : (stepY > 0 ? y + 1 - py : py - y) * deltaY;
        while (x != tx || y != ty) {
            // The nearer edge first; never past the zombie's square on either axis, so that the walk ends where the zombie is.
            if (x == tx) { y += stepY; nextY += deltaY; }
            else if (y == ty || nextX < nextY) { x += stepX; nextX += deltaX; }
            else { y += stepY; nextY += deltaY; }
            Object square = game.square(cell, x, y, pz);
            // A square the game has not loaded does not block, as in LosUtil.lineClear.
            if (square != null && last != null && (Object)vision.invokeExact(square, lastX - x, lastY - y, 0, true, false) == blocked) return false;
            last = square;
            lastX = x;
            lastY = y;
        }
        return true;
    }

    private static int floor(float value) {
        int whole = (int)value;
        return value < whole ? whole - 1 : whole;
    }

    // A spread for when each zombie is looked at next: xorshift, so that the frame takes no lock and allocates nothing.
    private long next() {
        random ^= random << 13;
        random ^= random >>> 7;
        random ^= random << 17;
        return random >>> 1;
    }
}
