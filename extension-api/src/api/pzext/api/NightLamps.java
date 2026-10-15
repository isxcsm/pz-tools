package pzext.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.lang.invoke.VarHandle;
import java.lang.reflect.Field;

/**
 * Night sight on the screen: a least light lifted into the light each square is drawn with, and greyed by the shaders
 * that draw the world's tiles.
 *
 * <p>The lift ({@link #floorLight}, f of 0 to 255) goes into each square's corner lights as the game reads them from its
 * lighting ({@code LightingJNI.getSquareLighting}, whose 8 corner colours from index {@link #CORNERS} light the floors,
 * walls and the sprites drawn on the square), and into the light the game draws the square's objects with
 * ({@code FBORenderCell.sanitizeLightInfo}): each colour c (0 to 1) becomes {@code c + f (1 - c)^2} ({@link #lift}), so
 * that the dark is lifted to f and the light is all but left as it is. A square the player has never seen (an
 * unexplored room, which the game draws black) is not lifted. The square's own light ({@code lightInfo}), which the
 * game's zombies, the vision cone and reading ask, is left as the game has it (the zombies the game keeps unseen for the
 * dark alone are shown through the same lift by {@link HiddenZombies}). The game keeps each chunk's look baked
 * and reads a square's lighting again only when the native lighting says it changed ({@code getSquareDirty}; it does not
 * know of the lift), so each square keeps the lift it was read with, and one read with another is read again
 * ({@link #squareStale}).
 *
 * <p>The shaders that draw the world (the tiles, the walls cut away for the player and the models: Hooks.SightShaders)
 * get {@code PZT_NightFloor} (f over 255) and work out, from the light each pixel is drawn with (the
 * corners', blended across the square by the GPU as the game's own), the light it had before the lift: the lift is
 * undone exactly ({@link #unlift}, f below 0.5), the share of colour the game's light gives is kept, and what the lift
 * adds is drawn in a cold grey, as the eye's rods see. All of it is in the light each vertex carries and the pixel's own
 * colour: nothing is read across squares or from the screen, so walls, corners and rooms are each drawn from their own
 * light. Models (characters, zombies, animals, vehicles, items, corpses, doors and furniture) are not: the game lights
 * them from the corners and makes more light of that (a character's ambient colour, and two lights beside it from it),
 * which a shader cannot take apart again, so every read of a model's light is taken back to the light before the lift
 * ({@link #modelLight}, {@link #modelObjectLight}) and the models' shaders add the grey from that light alone.
 *
 * <p>The shaders' uniform is set into every program that has it when the lift changes or a program with it is compiled
 * ({@link #tileDraw}): PZ Optimization draws the world's tiles with programs of its own, which the game never binds where
 * it can be seen.
 */
final class NightLamps {
    /** Where the corner lights start in what {@code getSquareLighting} hands (the visibility, the light, two darknesses, the level). */
    static final int CORNERS = 5;
    /** The most lift (of 255): below half, so that the shaders can undo it. */
    static final int MOST = 115;
    /** The tile shaders' uniform: the lift, 0 to 1. */
    static final String FLOOR = "PZT_NightFloor";

    private final Players players;
    // IsoGridSquare.lighting; ILighting.bSeen(); ColorInfo.r, g, b, a and set(r, g, b, a).
    private final MethodHandle lighting, everSeen, infoR, infoG, infoB, infoA, setAll;
    // IsoGridSquare.getVertLight(corner, player), x, y and z; IsoCamera.frameState and its playerIndex.
    private final MethodHandle vertLight, squareX, squareY, squareZ, frameState, framePlayer;
    // GL: glGetUniformLocation, glUniform1f, glGetInteger, glIsProgram, glGetProgrami, glUseProgram.
    private final MethodHandle uniformAt, uniform1f, getInteger, isProgram, programValue, useProgram;
    private static final int CURRENT_PROGRAM = 0x8B8D;

    /** The lift, 0 to 255 (0: none); read on any thread the lighting is read on. */
    private volatile int floor;
    // Whether squares were ever lifted: until then the lighting's reads and the tile shaders are left alone. Each square
    // as its corners were last read, for each player of this machine and floor (-32 to 31, each made as it is first
    // read): the lift it was read with, with its x and y over 256 and a bit that says it is there, in one int written and
    // read whole. A floor's squares are kept by x and y modulo 256, more than the squares the game keeps around a player;
    // another square in the same place replaces it. Both are the game's, kept for every API it runs: a Lua reload makes a
    // new one, which reads again the squares the last one lifted (and sets the tile shaders' uniform) whether it lifts or not.
    private static volatile boolean raising;
    private static final int SEEN_SIDE = 256, FLOORS = 64, PLAYERS = 4, SEEN = 1 << 30;
    private static final VarHandle SEEN_INT = MethodHandles.arrayElementVarHandle(int[].class);
    private static final VarHandle SEEN_FLOOR = MethodHandles.arrayElementVarHandle(int[][].class);
    private static final int[][][] seen = new int[PLAYERS][FLOORS][];
    // A square's mark (beside its lift) that a chunk level left it stale, not read (chunkStale).
    private static final int LEFT = 0x100;
    // The chunk levels: CHUNK_SIDE x CHUNK_SIDE of each player's floor, a level's marks, and how long one is asked to be
    // read before the squares it leaves unread are let go (ms).
    private static final int CHUNK_SIDE = 32, KNOWN = 1 << 9, PENDING = 1 << 8, GIVE_UP_MS = 3000;
    private static final int[][][] chunks = new int[PLAYERS][FLOORS][];
    // The visibility's bit that says the player has seen the square (ILighting.bSeen).
    private static final int SEEN_BIT = 1;
    // The light objects are drawn with when it is lifted: four for each thread that asks (the game draws with it at once),
    // used in turn.
    private static final class Lifted {
        final Object[] four = new Object[4];
        // The game's light each was lifted from.
        final Object[] origin = new Object[4];
        int next;
    }
    private final ThreadLocal<Lifted> lifted;
    // ownCorner's table, made again when the lift changes (read and replaced whole on any thread).
    private volatile int[] unlifted = { 0 };

    // The render thread's: the lift last set into the programs and how many sources with the step there were then (-1:
    // none yet); the highest program met; how many programs took it last and how many times it was set. Program ids are
    // looked at from 1 to at least SCAN (twice the highest met, if more).
    private int setLift = -1, setSources = -1, highest;
    private volatile int taking;
    private volatile long settings;
    private static final int SCAN = 4096, LINK_STATUS = 0x8B82;

    NightLamps(ClassLoader loader, Players players) throws ReflectiveOperationException {
        this.players = players;
        var lookup = MethodHandles.publicLookup();
        Class<?> square = Game.type(loader, "zombie.iso.IsoGridSquare"), lights = Game.type(loader, "zombie.iso.IsoGridSquare$ILighting");
        Class<?> info = Game.type(loader, "zombie.core.textures.ColorInfo");
        lighting = lookup.unreflectGetter(square.getField("lighting")).asType(MethodType.methodType(Object[].class, Object.class));
        everSeen = Game.exact(lights.getMethod("bSeen"), MethodType.methodType(boolean.class, Object.class));
        infoR = getter(lookup, info, "r");
        infoG = getter(lookup, info, "g");
        infoB = getter(lookup, info, "b");
        infoA = getter(lookup, info, "a");
        setAll = Game.exact(info.getMethod("set", float.class, float.class, float.class, float.class),
            MethodType.methodType(void.class, Object.class, float.class, float.class, float.class, float.class));
        MethodHandle make = lookup.unreflectConstructor(info.getConstructor()).asType(MethodType.methodType(Object.class));
        vertLight = Game.exact(square.getMethod("getVertLight", int.class, int.class), MethodType.methodType(int.class, Object.class, int.class, int.class));
        squareX = lookup.unreflectGetter(square.getField("x")).asType(MethodType.methodType(int.class, Object.class));
        squareY = lookup.unreflectGetter(square.getField("y")).asType(MethodType.methodType(int.class, Object.class));
        squareZ = lookup.unreflectGetter(square.getField("z")).asType(MethodType.methodType(int.class, Object.class));
        Class<?> camera = Game.type(loader, "zombie.iso.IsoCamera");
        Field state = camera.getField("frameState");
        frameState = lookup.unreflectGetter(state).asType(MethodType.methodType(Object.class));
        framePlayer = lookup.unreflectGetter(state.getType().getField("playerIndex")).asType(MethodType.methodType(int.class, Object.class));
        Class<?> gl20 = Game.type(loader, "org.lwjgl.opengl.GL20");
        uniformAt = Game.exact(gl20.getMethod("glGetUniformLocation", int.class, CharSequence.class),
            MethodType.methodType(int.class, int.class, CharSequence.class));
        uniform1f = Game.exact(gl20.getMethod("glUniform1f", int.class, float.class), MethodType.methodType(void.class, int.class, float.class));
        getInteger = Game.exact(Game.type(loader, "org.lwjgl.opengl.GL11").getMethod("glGetInteger", int.class), MethodType.methodType(int.class, int.class));
        isProgram = Game.exact(gl20.getMethod("glIsProgram", int.class), MethodType.methodType(boolean.class, int.class));
        programValue = Game.exact(gl20.getMethod("glGetProgrami", int.class, int.class), MethodType.methodType(int.class, int.class, int.class));
        useProgram = Game.exact(gl20.getMethod("glUseProgram", int.class), MethodType.methodType(void.class, int.class));
        lifted = ThreadLocal.withInitial(() -> {
            var made = new Lifted();
            try { for (int index = 0; index < made.four.length; index++) made.four[index] = (Object)make.invokeExact(); }
            catch (Throwable failure) { throw new IllegalStateException("a ColorInfo could not be made", failure); }
            return made;
        });
    }

    private static MethodHandle getter(MethodHandles.Lookup lookup, Class<?> owner, String name) throws ReflectiveOperationException {
        Field field = owner.getField(name);
        return lookup.unreflectGetter(field).asType(MethodType.methodType(float.class, Object.class));
    }

    /**
     * Sets the lift (0 to 255, at most {@link #MOST}; 0 for none). Each square read with another is read again as the
     * game next asks for its lighting, and the chunks it is in are baked again.
     */
    void floorLight(int light) {
        int next = Math.max(0, Math.min(MOST, light));
        if (next == floor) return;
        if (next > 0) raising = true;
        floor = next;
    }

    int floorLight() { return floor; }

    /**
     * What {@code getSquareLighting} handed for a player's square, as the game is about to read it: its corner lights
     * are lifted, each colour, for a player of this machine. A square the player has never seen is left as it is: night
     * sight shows nothing the game hides; it is kept as read all the same, and is read again when the lighting says it
     * changed (as it is seen). On whatever thread reads the lighting.
     */
    void squareLit(int playerIndex, int x, int y, int z, int[] lit) {
        if (!raising || lit == null || lit.length < CORNERS + 8) return;
        int[] floorSeen = floorSeen(playerIndex, z, true);
        if (floorSeen == null) return;
        int least = floor;
        if (least > 0 && (lit[0] & SEEN_BIT) != 0)
            for (int corner = CORNERS; corner < CORNERS + 8; corner++) lit[corner] = lift(lit[corner], least);
        SEEN_INT.setOpaque(floorSeen, seenAt(x, y), seenKey(x, y) | least);
    }

    /**
     * Whether a player's square the native lighting has not changed is to be read again: it was read with another lift,
     * or not read since squares are lifted. A square whose place another took is left alone (it cannot be told from it).
     * On whatever thread reads the lighting; the game asks it of every square it reads.
     */
    boolean squareStale(int playerIndex, int x, int y, int z) {
        if (!raising) return false;
        int[] floorSeen = floorSeen(playerIndex, z, false);
        int entry = floorSeen == null ? 0 : (int)SEEN_INT.getOpaque(floorSeen, seenAt(x, y));
        if (entry == 0) return floor > 0 && local(playerIndex);
        return (entry & ~0xFFFF) == seenKey(x, y) && (entry & 0xFF) != floor;
    }

    /**
     * Whether a chunk level of a player's, which the native lighting says has not changed, is to be read all the same:
     * the renderer reads a level's squares (and so asks {@link #squareStale}) only when it changed, and a new lift
     * changes none, so the squares read with another would stay as they were until their light changed. A level is
     * clean when none of its squares was last read with another lift (one table read once it is known clean). One that
     * stays stale for {@link #GIVE_UP_MS} has squares the renderer does not read (not drawn): they are marked so that the
     * level is clean, and each is still read again as the game next asks for it. On whatever thread asks.
     */
    boolean chunkStale(int playerIndex, int wx, int wy, int z) {
        if (!raising) return false;
        int[] state = floorChunks(playerIndex, z);
        if (state == null) return false;
        int least = floor, slot = (wy & CHUNK_SIDE - 1) * CHUNK_SIDE + (wx & CHUNK_SIDE - 1);
        int clean = chunkKey(wx, wy) | KNOWN | least, entry = (int)SEEN_INT.getOpaque(state, slot);
        if (entry == clean) return false;
        int[] floorSeen = floorSeen(playerIndex, z, false);
        boolean stale = false;
        if (floorSeen != null)
            for (int i = 0; i < 64 && !stale; i++) stale = staleIn(floorSeen, wx * 8 + (i & 7), wy * 8 + (i >> 3), least);
        if (!stale) { SEEN_INT.setOpaque(state, slot, clean); return false; }
        int now = (int)(System.nanoTime() / 1_000_000L);
        if (entry != (clean | PENDING)) {
            SEEN_INT.setOpaque(state, slot + CHUNK_SIDE * CHUNK_SIDE, now);
            SEEN_INT.setOpaque(state, slot, clean | PENDING);
            return true;
        }
        if (now - (int)SEEN_INT.getOpaque(state, slot + CHUNK_SIDE * CHUNK_SIDE) < GIVE_UP_MS) return true;
        for (int i = 0; i < 64; i++) {
            int x = wx * 8 + (i & 7), y = wy * 8 + (i >> 3);
            if (staleIn(floorSeen, x, y, least)) SEEN_INT.setOpaque(floorSeen, seenAt(x, y), (int)SEEN_INT.getOpaque(floorSeen, seenAt(x, y)) | LEFT);
        }
        SEEN_INT.setOpaque(state, slot, clean);
        return false;
    }

    // Whether the square was last read with another lift, and is not one a chunk level left (still stale for squareStale).
    private static boolean staleIn(int[] floorSeen, int x, int y, int least) {
        int entry = (int)SEEN_INT.getOpaque(floorSeen, seenAt(x, y));
        return (entry & ~0xFFFF) == seenKey(x, y) && (entry & LEFT) == 0 && (entry & 0xFF) != least;
    }

    // Each chunk level kept of a player's floor, by wx and wy modulo 32: its key, KNOWN, PENDING and the lift it is clean
    // at; then when it was first found stale (ms). Made as asked; null for a player or floor out of range.
    private int[] floorChunks(int playerIndex, int z) {
        if (playerIndex < 0 || playerIndex >= PLAYERS || z < -FLOORS / 2 || z >= FLOORS / 2 || !local(playerIndex)) return null;
        int[][] floors = chunks[playerIndex];
        int[] state = (int[])SEEN_FLOOR.getAcquire(floors, z + FLOORS / 2);
        if (state != null) return state;
        synchronized (floors) {
            state = (int[])SEEN_FLOOR.getAcquire(floors, z + FLOORS / 2);
            if (state == null) {
                state = new int[2 * CHUNK_SIDE * CHUNK_SIDE];
                SEEN_FLOOR.setRelease(floors, z + FLOORS / 2, state);
            }
            return state;
        }
    }

    private static int chunkKey(int wx, int wy) { return (wx >> 5 & 0x7FF) << 21 | (wy >> 5 & 0x7FF) << 10; }

    // The squares kept of a player's floor, made when asked to; null for a player or floor out of range.
    private int[] floorSeen(int playerIndex, int z, boolean make) {
        if (playerIndex < 0 || playerIndex >= PLAYERS || z < -FLOORS / 2 || z >= FLOORS / 2) return null;
        int[][] floors = seen[playerIndex];
        int[] floorSeen = (int[])SEEN_FLOOR.getAcquire(floors, z + FLOORS / 2);
        if (floorSeen != null || !make || !local(playerIndex)) return floorSeen;
        synchronized (floors) {
            floorSeen = (int[])SEEN_FLOOR.getAcquire(floors, z + FLOORS / 2);
            if (floorSeen == null) {
                floorSeen = new int[SEEN_SIDE * SEEN_SIDE];
                SEEN_FLOOR.setRelease(floors, z + FLOORS / 2, floorSeen);
            }
            return floorSeen;
        }
    }

    private boolean local(int playerIndex) {
        Object[] local = players.all();
        return playerIndex >= 0 && playerIndex < local.length && local[playerIndex] != null;
    }

    private static int seenAt(int x, int y) { return (y & SEEN_SIDE - 1) * SEEN_SIDE + (x & SEEN_SIDE - 1); }

    // The square's place, above the lift's 8 bits: x and y over 256, 7 bits each, and a bit that says it is there.
    private static int seenKey(int x, int y) { return SEEN | (x >> 8 & 0x7F) << 23 | (y >> 8 & 0x7F) << 16; }

    /** A corner light (0xAABBGGRR) with each colour lifted by {@code f} (0 to 255): {@code c + f (1 - c)^2}. */
    static int lift(int corner, int f) {
        return corner & 0xFF000000 | liftColour(corner >>> 16 & 0xFF, f) << 16 | liftColour(corner >>> 8 & 0xFF, f) << 8
            | liftColour(corner & 0xFF, f);
    }

    /** One colour (0 to 255) lifted by {@code f} (0 to 255). */
    static int liftColour(int value, int f) {
        int dark = 255 - value;
        return Math.min(255, value + (f * dark * dark + 32512) / 65025);
    }

    /** One colour (0 to 1) lifted by {@code f} (0 to 1). */
    static float lift(float value, float f) {
        float dark = 1f - Math.max(0f, Math.min(1f, value));
        return Math.min(1f, value + f * dark * dark);
    }

    /** The colour (0 to 1) before a lift by {@code f} (0 to 1, below 0.5): what the tile shaders work out. */
    static float unlift(float value, float f) {
        if (f <= 0f) return value;
        float dark = (1f - (float)Math.sqrt(Math.max(0f, 1f - 4f * f * (1f - value)))) / (2f * f);
        return Math.max(0f, Math.min(value, 1f - dark));
    }

    /**
     * A corner light ({@code 0xAABBGGRR}) as it was before the lift: the floor's blood is tinted with its square's corners
     * on the CPU and drawn with no step to grey it, so it keeps the game's light and shows as a dark stain on the lifted
     * floor (as blood looks at night) rather than lit red. One table of 256 colours for the lift now.
     */
    int ownCorner(int corner) {
        int least = floor;
        if (least == 0) return corner;
        int[] table = unlifted;
        if (table[0] != least) unlifted = table = unliftTable(least);
        return corner & 0xFF000000 | table[1 + (corner >>> 16 & 0xFF)] << 16 | table[1 + (corner >>> 8 & 0xFF)] << 8
            | table[1 + (corner & 0xFF)];
    }

    /**
     * PZ Optimization's lights for a chunk level's floor blood, as it fills them (the mean of each square's corners, r, g,
     * b, then 1 for a square drawn), taken back to before the lift: the same as {@link #ownCorner} for its GPU path.
     */
    void ownSquares(float[] squares) {
        int least = floor;
        if (least == 0) return;
        float f = least / 255f;
        for (int at = 0; at + 3 < squares.length; at += 4) {
            if (squares[at + 3] <= 0.5f) continue;
            squares[at] = unlift(squares[at], f);
            squares[at + 1] = unlift(squares[at + 1], f);
            squares[at + 2] = unlift(squares[at + 2], f);
        }
    }

    /** The lift, then each colour (0 to 255) before it. */
    static int[] unliftTable(int least) {
        int[] table = new int[257];
        table[0] = least;
        float f = least / 255f;
        for (int value = 0; value < 256; value++) table[1 + value] = Math.round(255f * unlift(value / 255f, f));
        return table;
    }

    /**
     * The light the game draws a square's objects with, for a player: the game's, or a copy of it lifted (the game's own
     * is the square's, which it also asks for its zombies and its vision, and is never changed); the game's on a square
     * the player has never seen.
     */
    Object objectLight(Object info, int playerIndex, Object square) throws Throwable {
        int least = floor;
        if (least == 0 || info == null || !local(playerIndex)) return info;
        if (square != null) {
            Object[] all = (Object[])lighting.invokeExact(square);
            Object lit = all != null && playerIndex < all.length ? all[playerIndex] : null;
            if (lit != null && !(boolean)everSeen.invokeExact(lit)) return info;
        }
        float f = least / 255f;
        float r = (float)infoR.invokeExact(info), g = (float)infoG.invokeExact(info), b = (float)infoB.invokeExact(info);
        Lifted mine = lifted.get();
        int slot = mine.next++ & 3;
        Object copy = mine.four[slot];
        mine.origin[slot] = info;
        setAll.invokeExact(copy, lift(r, f), lift(g, f), lift(b, f), (float)infoA.invokeExact(info));
        return copy;
    }

    /**
     * The light a model object (a door, furniture) is drawn with: the game's, when it is a lifted copy {@link #objectLight}
     * made on this thread. The game makes more light of it beside the model, which a shader cannot take apart again.
     */
    Object modelObjectLight(Object info) {
        if (!raising || info == null) return info;
        Lifted mine = lifted.get();
        for (int slot = 0; slot < 4; slot++) if (mine.four[slot] == info) return mine.origin[slot];
        return info;
    }

    /**
     * A model's light, which the game has just read from a square's corners into {@code info}
     * ({@code IsoGridSquare.interpolateLight}, at x and y across the square, for the player the frame is drawn for): read
     * again as the game reads it, from the corners as they were before the lift they were read with. A square the player
     * has never seen was not lifted. On the thread that reads it.
     */
    void modelLight(Object square, Object info, float fx, float fy) throws Throwable {
        if (!raising || square == null || info == null) return;
        int player = (int)framePlayer.invokeExact((Object)frameState.invokeExact());
        if (player < 0 || player >= PLAYERS || !local(player)) return;
        Object[] all = (Object[])lighting.invokeExact(square);
        Object lit = all != null && player < all.length ? all[player] : null;
        if (lit == null || !(boolean)everSeen.invokeExact(lit)) return;
        int with = liftRead(player, (int)squareX.invokeExact(square), (int)squareY.invokeExact(square), (int)squareZ.invokeExact(square));
        if (with == 0) return;
        int[] table = unliftFor(with);
        // As the game: x and y within the square; the top and bottom edges across x, then between them across y.
        float x = Math.max(0f, Math.min(1f, fx)), y = Math.max(0f, Math.min(1f, fy));
        int tl = (int)vertLight.invokeExact(square, 0, player), tr = (int)vertLight.invokeExact(square, 1, player);
        int br = (int)vertLight.invokeExact(square, 2, player), bl = (int)vertLight.invokeExact(square, 3, player);
        setAll.invokeExact(info, across(table, tl, tr, br, bl, 0, x, y), across(table, tl, tr, br, bl, 8, x, y),
            across(table, tl, tr, br, bl, 16, x, y), (float)infoA.invokeExact(info));
    }

    // One colour (by its shift in 0xAABBGGRR) at x, y across the corners, each before the lift.
    private static float across(int[] table, int tl, int tr, int br, int bl, int shift, float x, float y) {
        float a = before(table, tl, shift), b = before(table, tr, shift), c = before(table, br, shift), d = before(table, bl, shift);
        float top = a + (b - a) * x, bottom = d + (c - d) * x;
        return top + (bottom - top) * y;
    }

    private static float before(int[] table, int corner, int shift) { return 0.003921569f * table[1 + (corner >>> shift & 0xFF)]; }

    // The lift a player's square was last read with (0: none), or the lift now when it is not kept.
    private int liftRead(int player, int x, int y, int z) {
        int[] floorSeen = floorSeen(player, z, false);
        if (floorSeen == null) return floor;
        int entry = (int)SEEN_INT.getOpaque(floorSeen, seenAt(x, y));
        return (entry & ~0xFFFF) == seenKey(x, y) ? entry & 0xFF : floor;
    }

    // ownCorner's table for a lift, kept for the lift now.
    private int[] unliftFor(int lift) {
        int[] table = unlifted;
        if (table[0] == lift) return table;
        table = unliftTable(lift);
        if (lift == floor) unlifted = table;
        return table;
    }

    /**
     * Each time a shader that draws the world is bound or starts drawing, on the render thread ({@code id} its program;
     * {@code sources}, how many sources with night sight's step were loaded so far): once night sight has ever lifted,
     * when the lift changed or a program with the step was compiled since, every linked program of the context that has
     * the uniform takes the lift (the one bound bound again after). A program keeps its uniforms, and PZ Optimization
     * draws the world's tiles with programs of its own the game never binds where it can be seen, so all of them are set
     * at once rather than the one bound at a draw. Otherwise nothing is called.
     */
    void tileDraw(int id, int sources) throws Throwable {
        if (!raising) return;
        if (id > highest) highest = id;
        int lift = floor;
        if (lift == setLift && sources == setSources) return;
        setLift = lift;
        setSources = sources;
        int bound = (int)getInteger.invokeExact(CURRENT_PROGRAM), last = Math.max(SCAN, 2 * Math.max(highest, bound)), took = 0;
        float value = lift / 255f;
        for (int program = 1; program <= last; program++) {
            if (!(boolean)isProgram.invokeExact(program) || (int)programValue.invokeExact(program, LINK_STATUS) == 0) continue;
            int place = (int)uniformAt.invokeExact(program, (CharSequence)FLOOR);
            if (place < 0) continue;
            useProgram.invokeExact(program);
            uniform1f.invokeExact(place, value);
            took++;
        }
        useProgram.invokeExact(bound);
        taking = took;
        settings++;
    }

    /** How many programs took the lift when it was last set, and how many times it was set (for formulas.nightSight()). */
    int taking() { return taking; }
    long settings() { return settings; }
}
