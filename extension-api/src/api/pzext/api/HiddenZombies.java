package pzext.api;

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
 * such a zombie it draws a line from the player and, when nothing blocks it, asks the rest of the game's test of a zombie in
 * sight ({@code IsoGameCharacter.TestIfSeen}: the view distance, the light of the square, the detection range, the fade and the
 * dot with where the player looks; the line stands for {@code isCanSee} and nothing else of it is changed), and when that is
 * passed sets the alpha the zombie fades to back to 1 every frame, as the game would have had it, and brings its alpha up
 * itself over {@link #FADE_IN_NS} (the game's own fade does not: with PZ Optimize the alpha it fades to is 0 again by the time
 * it fades, so a zombie the fix showed stayed unseen). The game's own working is not touched: only the alphas.
 *
 * <p>The player and the zombie are bodies, not points: each has its middle and its two sides across the line between them
 * ({@link #BODY} to each side). The cone takes the zombie's middle or a side; the line is drawn middle to middle, and when that
 * is blocked side to side (left to left, right to right, and crossed), so that a zombie half behind a door frame or a wall's end,
 * or one the player sees past a corner it stands at, is found by the sides that show. A side is used only when nothing the game
 * blocks vision at stands between it and its body's middle (a side through a wall is not the body's).
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
 * <p>Night sight ({@code vision.nightSight}) lifts the dark the squares are drawn with ({@link NightLamps}); the light the
 * game's test reads is not lifted, so a zombie in a room the player sees lifted would stay unseen in the dark. While night
 * sight lifts ({@link #lift}), the light the test reads here is lifted as the squares are ({@link NightLamps#lift(float, float)},
 * each colour), so a zombie the game keeps unseen for the dark alone is shown; without the fix declared, a zombie is in sight
 * here when the game finds its square so ({@code ILighting.bCanSee}), not by a line of this part's.
 *
 * <p>The cost is the filter: a pass over the zombies the cell holds, each asked one array read and, when it is not drawn,
 * its position. Nothing is allocated for a zombie that is not a candidate. Unlike the rest of the formulas it is not a
 * hook in the game's code: while no mod declares it and night sight does not lift, nothing runs.
 */
final class HiddenZombies {
    /** The clock, in nanoseconds; the tests set it. */
    static volatile LongSupplier clock = System::nanoTime;
    /** The lines drawn since the API started, for the tests and the measure; the game thread's. */
    static long rays;

    // IsoObject.getAlpha(int), setAlpha(int, float).
    private final MethodHandle alphaOf, setAlpha;

    private static final long RAY_MIN = 60_000_000L, RAY_SPREAD = 40_000_000L, SPOT_MIN = 100_000_000L, SPOT_SPREAD = 400_000_000L;
    // How long a zombie shown takes to come up from unseen, and the longest frame counted for it, in nanoseconds.
    static final long FADE_IN_NS = 300_000_000L, LONGEST_FRAME_NS = 100_000_000L;
    // This frame's step of the fade in, and when the last frame was.
    private float fadeStep;
    private long lastFrame;
    // How far a body's sides (the player's, a zombie's) are from its middle, across the line between them, in squares.
    static final float BODY = 0.25f;
    // A zombie that has not been a candidate for this many frames is forgotten at the next sweep.
    private static final int FORGET_AFTER = 8, SWEEP_EVERY = 64;

    private final Game game;
    private final Players players;
    // IsoPlayer.TestZombieSpotPlayer(IsoMovingObject), IsoPlayer.getX(), getY(), getZ() (what is asked of each zombie is in ZombieReads).
    private final MethodHandle spot, xOf, yOf, zOf;
    // IsoPlayer: isSeeEveryone(), isAsleep(), getVehicle(), getLookVector(Vector2).
    private final MethodHandle seesAll, asleep, vehicleOf, lookOf;
    // GameTime.getInstance().getViewDist(); LightingJNI's smoothed vision cone in degrees, which the lighting reads.
    private final MethodHandle timeOf, viewDist, cone;
    // IsoGridSquare.testVisionAdjacent(dx, dy, dz, boolean, boolean); LosUtil.lineClear(cell, x0, y0, z0, x1, y1, z1, boolean).
    private final MethodHandle vision, lineClear;
    private final Object blocked, vector;
    private final Field vectorX, vectorY;
    // IsoGridSquare.ILighting.bCanSee(): the game's own finding that a square is in the player's sight.
    private final MethodHandle canSee;

    /** Whether a mod declares the fix; set from any thread, read by the frame. */
    private volatile boolean on;
    /** Night sight's lift of the dark, 0 to 1 (0: none); set from any thread, read by the frame. */
    private volatile float lift;
    // The game thread's: what is known of each zombie that is a candidate, by player.
    private final IdentityHashMap<Object, Candidate>[] candidates;
    private int epoch;
    // Whether anything is kept for the zombies since the fix was last off (so that a frame with it off has nothing to forget).
    private boolean holding;
    private long random = 0x9E3779B97F4A7C15L;

    private static final class Candidate {
        long rayAt, spotAt;
        boolean shown;
        int seen;
    }

    @SuppressWarnings("unchecked")
    HiddenZombies(ClassLoader loader, Game game, Players players) throws ReflectiveOperationException, IllegalAccessException {
        this.game = game;
        this.players = players;
        ZombieReads.use(loader);
        Class<?> object = Game.type(loader, "zombie.iso.IsoObject");
        alphaOf = Game.exact(object.getMethod("getAlpha", int.class), MethodType.methodType(float.class, Object.class, int.class));
        setAlpha = Game.exact(object.getMethod("setAlpha", int.class, float.class), MethodType.methodType(void.class, Object.class, int.class, float.class));
        Class<?> moving = Game.type(loader, "zombie.iso.IsoMovingObject");
        Class<?> character = Game.type(loader, "zombie.characters.IsoGameCharacter");
        Class<?> player = Game.type(loader, "zombie.characters.IsoPlayer"), square = Game.type(loader, "zombie.iso.IsoGridSquare");
        Class<?> cell = Game.type(loader, "zombie.iso.IsoCell"), los = Game.type(loader, "zombie.iso.LosUtil"), results = Game.type(loader, "zombie.iso.LosUtil$TestResults");
        Class<?> time = Game.type(loader, "zombie.GameTime"), lighting = Game.type(loader, "zombie.iso.LightingJNI");
        Class<?> vectorType = Game.type(loader, "zombie.iso.Vector2");
        var number = MethodType.methodType(float.class, Object.class);
        xOf = Game.exact(moving.getMethod("getX"), number);
        yOf = Game.exact(moving.getMethod("getY"), number);
        zOf = Game.exact(moving.getMethod("getZ"), number);
        spot = Game.exact(player.getMethod("TestZombieSpotPlayer", moving), MethodType.methodType(void.class, Object.class, Object.class));
        var flag = MethodType.methodType(boolean.class, Object.class);
        seesAll = Game.exact(player.getMethod("isSeeEveryone"), flag);
        asleep = Game.exact(character.getMethod("isAsleep"), flag);
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
        canSee = Game.exact(Game.type(loader, "zombie.iso.IsoGridSquare$ILighting").getMethod("bCanSee"), flag);
        blocked = results.getField("Blocked").get(null);
        vector = vectorType.getConstructor().newInstance();
        vectorX = vectorType.getField("x");
        vectorY = vectorType.getField("y");
        candidates = new IdentityHashMap[players.all().length];
        for (int index = 0; index < candidates.length; index++) candidates[index] = new IdentityHashMap<>();
    }

    /** Whether a mod declares the fix. */
    void declare(boolean declared) {
        if (declared != on) System.err.println("[PZExt] hidden zombies: " + (declared ? "on" : "off"));
        on = declared;
    }

    /** Night sight's lift of the dark the squares are drawn with, 0 to 1 (0 when it does not lift). */
    void lift(float f) {
        lift = Math.max(0f, Math.min(1f, f));
    }

    /** Each frame, on the game's thread. */
    void frame() throws Throwable {
        if (!on && !(lift > 0f)) { if (holding) forget(); return; }
        Object cell = game.cell();
        if (cell == null) { forget(); return; }
        holding = true;
        Object[] local = players.all();
        ArrayList<?> zombies = null;
        float view = 0;
        boolean fix = on;
        float f = lift;
        long now = clock.getAsLong();
        fadeStep = Math.min(now - lastFrame, LONGEST_FRAME_NS) / (float)FADE_IN_NS;
        lastFrame = now;
        boolean sweep = ++epoch % SWEEP_EVERY == 0;
        for (int index = 0; index < local.length && index < candidates.length; index++) {
            Object who = local[index];
            if (who == null) continue;
            if (zombies == null) {
                zombies = (ArrayList<?>)ZombieReads.Handles.LIST.invokeExact(cell);
                view = (float)viewDist.invokeExact((Object)timeOf.invokeExact());
            }
            // Nobody sees in a sleep, in the grave or from a car (the cone then is the car's), and a player who sees everyone has it done.
            if (!(boolean)ZombieReads.Handles.DEAD.invokeExact(who) && !(boolean)asleep.invokeExact(who) && !(boolean)seesAll.invokeExact(who)
                    && (Object)vehicleOf.invokeExact(who) == null)
                watch(index, who, cell, zombies, view, now, fix, f);
            if (sweep) candidates[index].values().removeIf(known -> epoch - known.seen > FORGET_AFTER);
        }
    }

    private void forget() {
        for (var known : candidates) if (!known.isEmpty()) known.clear();
        holding = false;
    }

    private void watch(int index, Object who, Object cell, ArrayList<?> zombies, float view, long now, boolean fix, float f) throws Throwable {
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
            boolean[] drawn = (boolean[])ZombieReads.Handles.VISIBLE.invokeExact(zombie);
            if (drawn[index]) continue;
            float zx = (float)ZombieReads.Handles.X.invokeExact(zombie), zy = (float)ZombieReads.Handles.Y.invokeExact(zombie);
            float dx = zx - px, dy = zy - py;
            float squared = dx * dx + dy * dy;
            if (squared > within) continue;
            int floor = floor((float)ZombieReads.Handles.Z.invokeExact(zombie));
            if (floor - pz > 1 || pz - floor > 1) continue;
            float distance = (float)Math.sqrt(squared);
            // Its sides across the view: half the body to the left and to the right of its middle.
            float sideX = distance == 0f ? 0f : -dy / distance * BODY, sideY = distance == 0f ? 0f : dx / distance * BODY;
            if (!all && !inCone(dx, dy, lx, ly, cosine * length) && !inCone(dx + sideX, dy + sideY, lx, ly, cosine * length)
                    && !inCone(dx - sideX, dy - sideY, lx, ly, cosine * length)) continue;
            Candidate state = known.get(zombie);
            if (state == null) {
                state = new Candidate();
                state.rayAt = now;
                state.spotAt = now;
                known.put(zombie, state);
            }
            state.seen = epoch;
            if (now - state.rayAt >= 0) {
                // With the fix the line stands for the game's square grid (isCanSee), else the game's grid is taken; what the game
                // goes on to ask of a zombie it finds in sight is asked here, its light lifted as night sight lifts the squares'.
                boolean inSight = fix ? clear(cell, px, py, pz, zx, zy, floor) || sides(cell, px, py, pz, zx, zy, floor, sideX, sideY)
                    : sees(index, zombie);
                state.shown = inSight && lit(index, who, zombie, zx, zy, view, f);
                state.rayAt = now + RAY_MIN + (next() % RAY_SPREAD);
            }
            if (!state.shown) continue;
            ZombieReads.Handles.ALPHA.invokeExact(zombie, index, 1f);
            float alpha = (float)alphaOf.invokeExact(zombie, index);
            if (alpha < 1f) setAlpha.invokeExact(zombie, index, Math.min(1f, alpha + fadeStep));
            if (now - state.spotAt >= 0) {
                spot.invokeExact(who, zombie);
                state.spotAt = now + SPOT_MIN + (next() % SPOT_SPREAD);
            }
        }
    }

    /**
     * What the game decides about a zombie it finds in sight, after the part that finds it in sight: the rest of
     * {@code IsoGameCharacter.TestIfSeen(int, IsoPlayer)}, in the same order and arithmetic (the game's jar and PZ Optimize's
     * class have the same). The zombie is in sight here (a clear line inside the cone stands for {@code isCanSee}), so the
     * allowances for a zombie that is not ({@code canSeeHeadSquare}; {@code isCouldSee} with the detection range) are not reached.
     * The light is the native lighting's per-square light, read as the game reads it, each colour lifted by night sight's
     * {@code f} as the squares are drawn (0: as the game has it).
     */
    private boolean lit(int index, Object who, Object zombie, float zx, float zy, float view, float f) throws Throwable {
        float distance = (float)ZombieReads.Handles.DISTANCE.invokeExact(zombie, who);
        // Beyond the view distance the game does not see it (the filter used the same bound on the squares).
        if (distance > view) return false;
        float range = (float)ZombieReads.Handles.RANGE.invokeExact(who);
        Object square = (Object)ZombieReads.Handles.SQUARE.invokeExact(zombie);
        if (square == null) return false;
        Object slot = ((Object[])ZombieReads.Handles.LIGHTING.invokeExact(square))[index];
        Object color = slot == null ? null : (Object)ZombieReads.Handles.LIGHT.invokeExact(slot);
        if (color == null) return false;
        float light = light(color, f);
        // Near enough to be heard, the player's own square lights it too.
        if (distance < range) {
            Object ours = (Object)ZombieReads.Handles.SQUARE.invokeExact(who);
            if (ours != null) {
                Object theirs = ((Object[])ZombieReads.Handles.LIGHTING.invokeExact(ours))[index];
                Object found = theirs == null ? null : (Object)ZombieReads.Handles.LIGHT.invokeExact(theirs);
                if (found != null) {
                    float other = light(found, f);
                    if (!(light > other)) light = other;
                }
            }
        }
        if (light > 0.6f) light = 1f;
        float fade = 1f - distance / view;
        if (light == 1f && fade > 0.3f) fade = 1f;
        float dot = (float)ZombieReads.Handles.DOT.invokeExact(who, zx, zy);
        if (dot < 0.5f) dot = 0.5f;
        light *= dot;
        if (light < 0f) light = 0f;
        if (distance <= 1f) {
            fade = 1f;
            light *= 2f;
        }
        light *= fade;
        light *= 100f;
        return light > 0.025f;
    }

    /** A square's light as the game's test reads it, (r + g + b) / 3, each colour lifted by {@code f} first when it is above 0. */
    private static float light(Object color, float f) throws Throwable {
        float r = (float)ZombieReads.Handles.RED.invokeExact(color), g = (float)ZombieReads.Handles.GREEN.invokeExact(color);
        float b = (float)ZombieReads.Handles.BLUE.invokeExact(color);
        if (f > 0f) { r = NightLamps.lift(r, f); g = NightLamps.lift(g, f); b = NightLamps.lift(b, f); }
        return (r + g + b) / 3f;
    }

    /** Whether the game finds the zombie's square in the player's sight ({@code ILighting.bCanSee}). */
    private boolean sees(int index, Object zombie) throws Throwable {
        Object square = (Object)ZombieReads.Handles.SQUARE.invokeExact(zombie);
        if (square == null) return false;
        Object slot = ((Object[])ZombieReads.Handles.LIGHTING.invokeExact(square))[index];
        return slot != null && (boolean)canSee.invokeExact(slot);
    }

    /** Whether the point {@code (dx, dy)} from the player is within the cone ({@code reach}: the cone's cosine times the look's length). */
    private static boolean inCone(float dx, float dy, float lx, float ly, float reach) {
        return dx * lx + dy * ly >= reach * (float)Math.sqrt(dx * dx + dy * dy);
    }

    /**
     * Whether a line side to side is clear: the player's left to the zombie's left, right to right, and crossed, each side used
     * when it is its body's own ({@link #side}). Asked only when the line middle to middle is blocked.
     */
    private boolean sides(Object cell, float px, float py, int pz, float zx, float zy, int zz, float ox, float oy) throws Throwable {
        boolean playerLeft = side(cell, px, py, pz, ox, oy), playerRight = side(cell, px, py, pz, -ox, -oy);
        boolean zombieLeft = side(cell, zx, zy, zz, ox, oy), zombieRight = side(cell, zx, zy, zz, -ox, -oy);
        return playerLeft && zombieLeft && clear(cell, px + ox, py + oy, pz, zx + ox, zy + oy, zz)
            || playerRight && zombieRight && clear(cell, px - ox, py - oy, pz, zx - ox, zy - oy, zz)
            || playerLeft && zombieRight && clear(cell, px + ox, py + oy, pz, zx - ox, zy - oy, zz)
            || playerRight && zombieLeft && clear(cell, px - ox, py - oy, pz, zx + ox, zy + oy, zz)
            || zombieLeft && clear(cell, px, py, pz, zx + ox, zy + oy, zz)
            || zombieRight && clear(cell, px, py, pz, zx - ox, zy - oy, zz);
    }

    /** Whether a body's side ({@code ox, oy} from its middle) is its own: in its square, or across an edge the game does not block vision at. */
    private boolean side(Object cell, float zx, float zy, int zz, float ox, float oy) throws Throwable {
        if (ox == 0f && oy == 0f) return false;
        int x = floor(zx), y = floor(zy), sx = floor(zx + ox), sy = floor(zy + oy);
        if (x == sx && y == sy) return true;
        Object square = game.square(cell, sx, sy, zz);
        return square != null && (Object)vision.invokeExact(square, x - sx, y - sy, 0, true, false) != blocked;
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
