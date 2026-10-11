package pztools.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.lang.invoke.VarHandle;
import java.lang.reflect.Field;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Night sight on the screen: the least light the player's screen draws each square with, and the screen pass that
 * keeps what the eye saw without night sight in colour and greys what night sight adds.
 *
 * <p>The least light ({@link #floorLight}) goes into each square's corner lights as the game reads them from its
 * lighting ({@code LightingJNI.getSquareLighting}, whose 8 corner colours from index {@link #CORNERS} light the floors,
 * walls and every model drawn on the square), and into the light the game draws the square's objects with
 * ({@code FBORenderCell.sanitizeLightInfo}). The square's own light ({@code lightInfo}), which the game's zombies, the
 * vision cone and reading ask, is left as the game has it, and so is the light the game gives a room through its
 * openings: a sealed room is lit as well as an open one. The game keeps each chunk's look baked and reads a square's
 * lighting again only when the native lighting says it changed ({@code getSquareDirty}; it does not know of the least
 * light), and bakes it again when the corners it reads change: each square keeps the least light it was raised to, and
 * one raised to another is read again ({@link #squareStale}).
 *
 * <p>The screen pass: a square keeps the colour of the share of its light the game gives it (the mean of its corner
 * lights as the game handed them, kept as they are raised, against the least light; the square's {@code lightInfo}
 * for one not seen yet: it can read 0 where the corners light a room through its stairs), and its light sources' share
 * of its light is not lifted either. A light source's share is the
 * light the lights the game finds reach the square give it ({@code IsoGridSquare.lighting}: each falling off from its
 * colour at its square to nothing at its radius, measured; a room's light fills it) against the square's whole light.
 * The values of the {@link #SIZE} squares on a side around the player, on the player's floor, are worked out on the
 * game's thread every {@link #REFRESH_NS} nanoseconds while night sight is declared, and handed to the render thread,
 * which puts them into a small texture the shader reads, smoothly between squares. Beyond them, the mean of the ones
 * on their edge. Where a pixel is on the floor is worked out from where the game draws three points of it
 * ({@code isoToScreenX}, {@code isoToScreenY}), every frame. A wall or a thing standing on a square is drawn above it
 * and read as the squares behind; so a wall's face has the squares it covers take the values of the square it stands
 * on ({@link #faces}), and a character standing on a square (a player of this machine, a zombie) has the
 * {@link #STANDING} squares behind it, where it is drawn, and their sides keep at least its square's values, and keeps
 * the colour its square does. Whether the player is in a dark place (most of the squares within {@link #DARK_RADIUS}
 * with almost none of the game's own light) is worked out with the values, for the least light. Split screen gets the
 * least light but no values (the pass does not say whose screen it
 * draws): the colour is kept there.
 *
 * <p>Nothing on the screen moves in steps. Each set of values carries the last set's values of the same squares beside
 * its own, and the pass goes from the one to the other every frame over the time the next set takes
 * ({@link #blend}): the game's light fades as the game fades it, not 10 times a second. And while the values run, the
 * squares are raised to the dark place's least light whether the player is in one or not, and the pass takes them down
 * to the least light shown ({@link #shadeOf}, eased every frame): the baked squares change only when night sight's
 * value does, and a dark place comes and goes smoothly, where raising the squares to it would make every chunk bake
 * again, one batch after another. Each set's values also go towards the squares' by at most nightSight.reveal's pace
 * ({@link #toward}): the game hands a square's light as its lighting gets to it, in jumps (more so with PZ
 * Optimization's lighting), and the share of colour kept follows them as a fade, not a step a set. That pace is the
 * game's own (it fades a square coming into view in about as long), not the eye's (nightSight.ease, the dark place
 * and night sight's strength): what comes into sight right in front of the player is not dark for seconds.
 *
 * <p>The least light is for the night: outside a dark place the least light shown follows the game's night
 * ({@code ClimateManager.getNightStrength}, 0 by day), so that by day a square keeps the game's light and colour (the
 * game darkens what the player does not see, and the pass would otherwise grey it as night sight's), the squares
 * still raised (a pixel is taken down to the game's light) and nothing baked again.
 *
 * <p>Night sight is for what the player sees. A square out of the player's sight (out of the vision cone, behind a
 * wall: {@code bCouldSee} false; not {@code bCanSee}, which also asks for light) the game draws dimmed its own way, not with the corners it hands (they read none, and the least light does not
 * reach it): the pass leaves it as drawn. As it comes into sight the game draws it with its raised corners at once;
 * the pass shows it as the game's light would first (its colour times its share kept) and goes to night sight's over
 * nightSight.reveal, as it does back when it goes out of sight ({@code PZT_SightLamps}' second half: how much of night
 * sight a square shows, and how much of what is drawn is the game's).
 *
 * <p>Two buffers go between the threads: the render thread takes the one ready, copies it to the texture and gives it
 * back; nothing is allocated after the first frame. The texture is bound on its own unit ({@link #UNIT}), and the unit
 * that was active is made active again.
 */
final class NightLamps {
    /** Squares on a side of the values, and how often they are worked out. */
    static final int SIZE = 64;
    static final long REFRESH_NS = 100_000_000L;
    /** The texture unit the values are bound on: one no screen pass uses (PZ Optimization's passes use others). */
    static final int UNIT = 16;
    /** Where the corner lights start in what {@code getSquareLighting} hands (the visibility, the light, two darknesses, the level). */
    static final int CORNERS = 5;
    /** Squares behind a standing character that it is drawn over (the default of nightSight.standing). */
    static final int STANDING = 3;
    /** Squares a wall rises over on the screen: the diagonal rows behind it that its face covers (a floor's height). */
    static final int WALL = 3;
    /** Of those, the rows a doorway with no closed door opens on (the squares behind are seen through it); the wall above it covers the rest. */
    static final int DOORWAY = 2;
    /**
     * A dark place: of the squares within DARK_RADIUS of the player that the game lights, the share with less than
     * DARK_LIGHT of its own light; at DARK_IN or more the player is in one, at DARK_OUT or less no longer (between, as it was).
     * The defaults of the nightSight tunings of the same names.
     */
    static final int DARK_RADIUS = 6;
    static final float DARK_LIGHT = 0.03f, DARK_IN = 0.75f, DARK_OUT = 0.55f;
    static final String STRENGTH = "PZT_NightSight", ON = "PZT_SightOn", KEEP = "PZT_SightKeep", LAMPS = "PZT_SightLamps", U = "PZT_SightU",
        V = "PZT_SightV", LIFT = "PZT_SightLift", BLEND = "PZT_SightBlend", SHADE = "PZT_SightShade";

    private static final int TEXTURE_2D = 0x0DE1, TEXTURE0 = 0x84C0, ACTIVE_TEXTURE = 0x84E0, RGBA8 = 0x8058, RGBA = 0x1908, UNSIGNED_BYTE = 0x1401,
        MIN_FILTER = 0x2801, MAG_FILTER = 0x2800, LINEAR = 0x2601, WRAP_S = 0x2802, WRAP_T = 0x2803, CLAMP_TO_EDGE = 0x812F;

    private final Game game;
    private final Players players;
    // The dark place's and the standing characters' numbers, and the seconds a square's values follow it over, as tuned.
    private final Tunings.Tuning darkLight, darkIn, darkOut, darkRadius, standingSquares, reveal;
    // ClimateManager.getInstance().getNightStrength().
    private final MethodHandle climate, nightStrength;
    // IsoGridSquare.lighting; ILighting.lightInfo(), resultLightCount(), getResultLight(int), bCouldSee(), bSeen(); ColorInfo.r, g, b, a,
    // set(r, g, b, a) and its constructor; ResultLight.x, y, radius, flags and r, g, b; IsoMovingObject.getX(), getY(), getZ().
    private final MethodHandle lighting, lightInfo, lightCount, light, couldSee, everSeen, infoR, infoG, infoB, infoA, setAll, newInfo,
        lightX, lightY, lightRadius, lightFlags, lightR, lightG, lightB, xOf, yOf, zOf;
    private final int roomLight;
    // IsoCell.getZombieList().
    private final MethodHandle zombieList;
    // IsoGridSquare.hasProperty(IsoFlagType) and the flags of what stands on its edges: a wall on the square's north edge,
    // west edge, both; a door frame and a window frame on each. IsoGridSquare.hasClosedDoorOnEdge(IsoDirections) with N
    // and W, and getPlayerCutawayFlag(player, now) (1 the north wall cut away, 2 the west one).
    private final MethodHandle hasFlag, closedDoor, cutaway;
    private final Object wallN, wallW, wallNW, doorN, doorW, windowN, windowW, edgeN, edgeW;
    // LuaManager.GlobalObject.isoToScreenX and Y (player, x, y, z); Core.getInstance().getScreenHeight().
    private final MethodHandle screenX, screenY, core, screenHeight;
    // GL: glGetUniformLocation, glUniform1f, glUniform1i, glUniform3f, glGenTextures, glBindTexture, glTexParameteri,
    // glTexImage2D, glTexSubImage2D, glGetInteger, glActiveTexture.
    private final MethodHandle uniformAt, uniform1f, uniform1i, uniform3f, genTexture, bindTexture, textureParameter, textureImage,
        textureSubImage, getInteger, activeTexture;

    /** The least light of a square on the screen, 0 to 255 (0: none); read on any thread the lighting is read on. */
    private volatile int floor;
    // The least light shown against the one the squares are raised to (0 to 1), for the screen pass; and whether the
    // values were stopped (a fault).
    private volatile float shade = 1f;
    private volatile boolean stopped;
    // Each square as its corners were last read, for each player of this machine and floor (-32 to 31, each made as it
    // is first read): the least light it was raised to and the game's own light of it (0 to 255 each), with its x and y
    // over 256, in one int written and read whole. A floor's squares are kept by x and y modulo 256, more than the
    // squares the game keeps around a player; another square in the same place replaces it.
    private static final int SEEN_SIDE = 256, FLOORS = 64, PLAYERS = 4, SEEN = 1 << 30;
    private static final VarHandle SEEN_INT = MethodHandles.arrayElementVarHandle(int[].class);
    private static final VarHandle SEEN_FLOOR = MethodHandles.arrayElementVarHandle(int[][].class);
    private final int[][][] seen = new int[PLAYERS][FLOORS][];
    // Whether squares were ever raised: until then the lighting's reads are left alone.
    private volatile boolean raising;
    // The light objects are drawn with when it is raised: four for each thread that asks (the game draws with it at once),
    // used in turn.
    private static final class Raised {
        final Object[] four = new Object[4];
        int next;
    }
    private final ThreadLocal<Raised> raised;

    // A set of values, rows of two halves of SIZE squares: four bytes a square in each, the last set's two of it, then
    // this set's; in the first half its share of colour kept and its light sources' share, in the second how much of
    // night sight it shows and the share of what is drawn that is the game's light. The colour kept beyond them, the
    // last set's and this one's; the time since the last set (the time the next is to take).
    private static final class Values {
        final ByteBuffer data = ByteBuffer.allocateDirect(SIZE * SIZE * 8);
        int x0, y0;
        float keepFrom, keepTo;
        long period;
    }

    // The values ready for the render thread, and the one it gave back; the game thread's own, which it fills.
    private final AtomicReference<Values> ready = new AtomicReference<>(), spare = new AtomicReference<>(new Values());
    private Values filling = new Values();
    private long valuesAt;
    // The last set's own values (four bytes a square), where they start and the colour kept beyond them, and the one
    // being made; none after the values paused (the game thread's).
    private byte[] lastValues = new byte[SIZE * SIZE * 4], nextValues = new byte[SIZE * SIZE * 4];
    private int lastX, lastY;
    private float lastBeyond;
    private boolean hasLast;
    // Whether the player is in a dark place, as the last values had it, what they counted and the mean share of colour
    // kept near the player; how far into the night it is, as last read (the game's thread's).
    private boolean darkPlace;
    private final int[] counted = new int[4];
    // The walls of the last values' squares ({@link #walls}) and their own values before the walls' faces took theirs.
    private final byte[] walls = new byte[SIZE * SIZE], own = new byte[SIZE * SIZE * 4];
    private float keptAround, night;
    // Where a pixel of the screen (x, y up from the bottom, 1) is on the floor: world x and y, as the game thread last
    // worked it out (written whole, then published).
    private volatile double[] onFloor;
    private double[] nextFloor = new double[6], lastFloor = new double[6];

    // The render thread's: the program the locations are of, the locations, the texture and where its values start, the
    // colour kept beyond them (from, to), when they came and the time the next is to take.
    private int program = -1, strengthAt = -1, onAt = -1, keepAt = -1, lampsAt = -1, uAt = -1, vAt = -1, liftAt = -1, blendAt = -1,
        shadeAt = -1, texture;
    private int shownX, shownY;
    private boolean shown;
    private float keepFrom = 1f, keepTo = 1f;
    private long shownAt, shownPeriod = REFRESH_NS;

    NightLamps(ClassLoader loader, Game game, Players players, Tunings.Tuning darkLight, Tunings.Tuning darkIn, Tunings.Tuning darkOut,
            Tunings.Tuning darkRadius, Tunings.Tuning standing, Tunings.Tuning reveal) throws ReflectiveOperationException {
        this.game = game;
        this.players = players;
        this.darkLight = darkLight;
        this.darkIn = darkIn;
        this.darkOut = darkOut;
        this.darkRadius = darkRadius;
        this.standingSquares = standing;
        this.reveal = reveal;
        var lookup = MethodHandles.publicLookup();
        Class<?> climateType = Game.type(loader, "zombie.iso.weather.ClimateManager");
        climate = Game.exact(climateType.getMethod("getInstance"), MethodType.methodType(Object.class));
        nightStrength = Game.exact(climateType.getMethod("getNightStrength"), MethodType.methodType(float.class, Object.class));
        Class<?> square = Game.type(loader, "zombie.iso.IsoGridSquare"), lights = Game.type(loader, "zombie.iso.IsoGridSquare$ILighting");
        Class<?> result = Game.type(loader, "zombie.iso.IsoGridSquare$ResultLight"), info = Game.type(loader, "zombie.core.textures.ColorInfo");
        lighting = lookup.unreflectGetter(square.getField("lighting")).asType(MethodType.methodType(Object[].class, Object.class));
        lightInfo = Game.exact(lights.getMethod("lightInfo"), MethodType.methodType(Object.class, Object.class));
        lightCount = Game.exact(lights.getMethod("resultLightCount"), MethodType.methodType(int.class, Object.class));
        couldSee = Game.exact(lights.getMethod("bCouldSee"), MethodType.methodType(boolean.class, Object.class));
        everSeen = Game.exact(lights.getMethod("bSeen"), MethodType.methodType(boolean.class, Object.class));
        Class<?> flags = Game.type(loader, "zombie.iso.SpriteDetails.IsoFlagType");
        hasFlag = Game.exact(square.getMethod("hasProperty", flags), MethodType.methodType(boolean.class, Object.class, Object.class));
        wallN = flag(flags, "WallN");
        wallW = flag(flags, "WallW");
        wallNW = flag(flags, "WallNW");
        doorN = flag(flags, "DoorWallN");
        doorW = flag(flags, "DoorWallW");
        windowN = flag(flags, "WindowN");
        windowW = flag(flags, "WindowW");
        Class<?> directions = Game.type(loader, "zombie.iso.IsoDirections");
        closedDoor = Game.exact(square.getMethod("hasClosedDoorOnEdge", directions), MethodType.methodType(boolean.class, Object.class, Object.class));
        edgeN = flag(directions, "N");
        edgeW = flag(directions, "W");
        cutaway = Game.exact(square.getMethod("getPlayerCutawayFlag", int.class, long.class),
            MethodType.methodType(int.class, Object.class, int.class, long.class));
        light = Game.exact(lights.getMethod("getResultLight", int.class), MethodType.methodType(Object.class, Object.class, int.class));
        infoR = getter(lookup, info, "r", float.class);
        infoG = getter(lookup, info, "g", float.class);
        infoB = getter(lookup, info, "b", float.class);
        infoA = getter(lookup, info, "a", float.class);
        setAll = Game.exact(info.getMethod("set", float.class, float.class, float.class, float.class),
            MethodType.methodType(void.class, Object.class, float.class, float.class, float.class, float.class));
        newInfo = lookup.unreflectConstructor(info.getConstructor()).asType(MethodType.methodType(Object.class));
        lightX = getter(lookup, result, "x", int.class);
        lightY = getter(lookup, result, "y", int.class);
        lightRadius = getter(lookup, result, "radius", int.class);
        lightFlags = getter(lookup, result, "flags", int.class);
        lightR = getter(lookup, result, "r", float.class);
        lightG = getter(lookup, result, "g", float.class);
        lightB = getter(lookup, result, "b", float.class);
        roomLight = result.getField("RLF_ROOMLIGHT").getInt(null);
        Class<?> moving = Game.type(loader, "zombie.iso.IsoMovingObject");
        var number = MethodType.methodType(float.class, Object.class);
        xOf = Game.exact(moving.getMethod("getX"), number);
        yOf = Game.exact(moving.getMethod("getY"), number);
        zOf = Game.exact(moving.getMethod("getZ"), number);
        zombieList = Game.exact(Game.type(loader, "zombie.iso.IsoCell").getMethod("getZombieList"), MethodType.methodType(ArrayList.class, Object.class));
        Class<?> global = Game.type(loader, "zombie.Lua.LuaManager$GlobalObject");
        var toScreen = MethodType.methodType(float.class, int.class, float.class, float.class, float.class);
        screenX = Game.exact(global.getMethod("isoToScreenX", int.class, float.class, float.class, float.class), toScreen);
        screenY = Game.exact(global.getMethod("isoToScreenY", int.class, float.class, float.class, float.class), toScreen);
        Class<?> coreType = Game.type(loader, "zombie.core.Core");
        core = Game.exact(coreType.getMethod("getInstance"), MethodType.methodType(Object.class));
        screenHeight = Game.exact(coreType.getMethod("getScreenHeight"), MethodType.methodType(int.class, Object.class));
        Class<?> gl11 = Game.type(loader, "org.lwjgl.opengl.GL11"), gl13 = Game.type(loader, "org.lwjgl.opengl.GL13");
        Class<?> gl20 = Game.type(loader, "org.lwjgl.opengl.GL20");
        uniformAt = Game.exact(gl20.getMethod("glGetUniformLocation", int.class, CharSequence.class),
            MethodType.methodType(int.class, int.class, CharSequence.class));
        uniform1f = Game.exact(gl20.getMethod("glUniform1f", int.class, float.class), MethodType.methodType(void.class, int.class, float.class));
        uniform1i = Game.exact(gl20.getMethod("glUniform1i", int.class, int.class), MethodType.methodType(void.class, int.class, int.class));
        uniform3f = Game.exact(gl20.getMethod("glUniform3f", int.class, float.class, float.class, float.class),
            MethodType.methodType(void.class, int.class, float.class, float.class, float.class));
        genTexture = Game.exact(gl11.getMethod("glGenTextures"), MethodType.methodType(int.class));
        bindTexture = Game.exact(gl11.getMethod("glBindTexture", int.class, int.class), MethodType.methodType(void.class, int.class, int.class));
        textureParameter = Game.exact(gl11.getMethod("glTexParameteri", int.class, int.class, int.class),
            MethodType.methodType(void.class, int.class, int.class, int.class));
        textureImage = Game.exact(gl11.getMethod("glTexImage2D", int.class, int.class, int.class, int.class, int.class, int.class, int.class,
            int.class, ByteBuffer.class), MethodType.methodType(void.class, int.class, int.class, int.class, int.class, int.class, int.class,
            int.class, int.class, ByteBuffer.class));
        textureSubImage = Game.exact(gl11.getMethod("glTexSubImage2D", int.class, int.class, int.class, int.class, int.class, int.class, int.class,
            int.class, ByteBuffer.class), MethodType.methodType(void.class, int.class, int.class, int.class, int.class, int.class, int.class,
            int.class, int.class, ByteBuffer.class));
        getInteger = Game.exact(gl11.getMethod("glGetInteger", int.class), MethodType.methodType(int.class, int.class));
        activeTexture = Game.exact(gl13.getMethod("glActiveTexture", int.class), MethodType.methodType(void.class, int.class));
        MethodHandle make = newInfo;
        raised = ThreadLocal.withInitial(() -> {
            var made = new Raised();
            try { for (int index = 0; index < made.four.length; index++) made.four[index] = (Object)make.invokeExact(); }
            catch (Throwable failure) { throw new IllegalStateException("a ColorInfo could not be made", failure); }
            return made;
        });
    }

    @SuppressWarnings({ "unchecked", "rawtypes" })
    private static Object flag(Class<?> flags, String name) { return Enum.valueOf((Class)flags, name); }

    private static MethodHandle getter(MethodHandles.Lookup lookup, Class<?> owner, String name, Class<?> type) throws ReflectiveOperationException {
        Field field = owner.getField(name);
        return lookup.unreflectGetter(field).asType(MethodType.methodType(type, Object.class));
    }

    /**
     * Sets the least light of a square on the screen (0 to 255; 0 for none): {@code light} outside a dark place,
     * {@code dark} in one, and the share of the dark place's more shown now (0 to 1, eased every frame by the caller).
     * While the values run (one player of this machine) the squares are raised to {@code dark} and the screen pass takes
     * them down to the least light shown, {@code light} by the game's night; without them, they are raised to
     * {@code light}. Each square raised to another is read again as the game next asks for its lighting. On the game's
     * thread, every frame.
     */
    void floorLight(int light, int dark, float darkShare) throws Throwable {
        int lit = Math.max(0, Math.min(255, light)), most = Math.max(lit, Math.min(255, dark));
        boolean carried = !stopped && most > 0 && alone(players.all()) >= 0;
        night = (float)nightStrength.invokeExact((Object)climate.invokeExact());
        shade = carried ? shadeOf(lit, most, darkShare, night) : 1f;
        raise(carried ? most : lit);
    }

    /** One least light, all of it shown, in a dark place or not and by day (for the tests). */
    void floorLight(int light) {
        shade = 1f;
        raise(Math.max(0, Math.min(255, light)));
    }

    private void raise(int next) {
        if (next == floor) return;
        if (next > 0) raising = true;
        floor = next;
        valuesAt = 0;
    }

    int floorLight() { return floor; }

    /** The least light shown against the one the squares are raised to (for the tests). */
    float shade() { return shade; }

    /**
     * The least light shown against {@code dark}, the one the squares are raised to: {@code light} by the game's
     * {@code night} (0 by day to 1), with {@code share} of the way from it to {@code dark} (a dark place's, by day too).
     */
    static float shadeOf(int light, int dark, float share, float night) {
        if (dark <= 0) return 1f;
        float outside = light * Math.max(0f, Math.min(1f, night));
        return (outside + (dark - outside) * Math.max(0f, Math.min(1f, share))) / dark;
    }

    /** A value of 0 to 255 at most {@code most} from {@code from} towards {@code to}. */
    static int toward(int from, int to, int most) { return to > from ? Math.min(to, from + most) : Math.max(to, from - most); }

    /** How far the screen pass is from the last set's values to the newest's (0 to 1), {@code since} it got them, the next due in {@code period}. */
    static float blend(long since, long period) {
        if (period <= 0 || since >= period) return 1f;
        return since <= 0 ? 0f : (float)since / period;
    }

    /**
     * What {@code getSquareLighting} handed for a player's square, as the game is about to read it: the light the game
     * gives it is kept (the mean of its corners) with the least light, and its corner lights are raised to the least
     * light, each colour, for a player of this machine. A square the player has never seen (an unexplored room, which
     * the game draws black) is left as it is: night sight shows nothing the game hides; it is kept as raised all the same,
     * and is read again when the lighting says it changed (as it is seen). On whatever thread reads the lighting.
     */
    void squareLit(int playerIndex, int x, int y, int z, int[] lit) {
        if (!raising || lit == null || lit.length < CORNERS + 8) return;
        int[] floorSeen = floorSeen(playerIndex, z, true);
        if (floorSeen == null) return;
        int least = floor, sum = 0;
        for (int corner = CORNERS; corner < CORNERS + 8; corner++) {
            int light = lit[corner];
            sum += 299 * (light & 0xFF) + 587 * (light >>> 8 & 0xFF) + 114 * (light >>> 16 & 0xFF);
            if (least > 0 && (lit[0] & SEEN_BIT) != 0) lit[corner] = raise(light, least);
        }
        SEEN_INT.setOpaque(floorSeen, seenAt(x, y), seenKey(x, y) | least << 8 | Math.round(sum / 8000f));
    }

    /**
     * Whether a player's square the native lighting has not changed is to be read again: it was raised to another least
     * light, or not read since squares are raised. A square whose place another took is left alone (it cannot be told
     * from it). On whatever thread reads the lighting; the game asks it of every square it reads.
     */
    boolean squareStale(int playerIndex, int x, int y, int z) {
        if (!raising) return false;
        int[] floorSeen = floorSeen(playerIndex, z, false);
        int entry = floorSeen == null ? 0 : (int)SEEN_INT.getOpaque(floorSeen, seenAt(x, y));
        if (entry == 0) return floor > 0 && local(playerIndex);
        return (entry & ~0xFFFF) == seenKey(x, y) && (entry >>> 8 & 0xFF) != floor;
    }

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

    // The square's place, above the least light's and the light's 8 bits each: x and y over 256, 7 bits each, and a bit
    // that says it is there.
    private static int seenKey(int x, int y) { return SEEN | (x >> 8 & 0x7F) << 23 | (y >> 8 & 0x7F) << 16; }

    // The game's light of a player's square as its corners were last read (0 to 1), or -1 if not kept.
    private float seenLight(int playerIndex, int x, int y, int z) {
        int[] floorSeen = floorSeen(playerIndex, z, false);
        if (floorSeen == null) return -1f;
        int entry = (int)SEEN_INT.getOpaque(floorSeen, seenAt(x, y));
        return (entry & ~0xFFFF) == seenKey(x, y) ? (entry & 0xFF) / 255f : -1f;
    }

    // The visibility's bit that says the player has seen the square (ILighting.bSeen).
    private static final int SEEN_BIT = 1;

    // A corner light (0xAABBGGRR) with each colour at least `least`.
    static int raise(int corner, int least) {
        int r = Math.max(corner & 0xFF, least), g = Math.max(corner >>> 8 & 0xFF, least), b = Math.max(corner >>> 16 & 0xFF, least);
        return corner & 0xFF000000 | b << 16 | g << 8 | r;
    }

    /**
     * The light the game draws a square's objects with, for a player: the game's, or a copy of it raised to the least
     * light (the game's own is the square's, which it also asks for its zombies and its vision, and is never changed);
     * the game's on a square the player has never seen.
     */
    Object objectLight(Object info, int playerIndex, Object square) throws Throwable {
        int least = floor;
        if (least == 0 || info == null || !local(playerIndex)) return info;
        float lowest = least / 255f;
        float r = (float)infoR.invokeExact(info), g = (float)infoG.invokeExact(info), b = (float)infoB.invokeExact(info);
        if (r >= lowest && g >= lowest && b >= lowest) return info;
        if (square != null) {
            Object lit = lit(square, playerIndex);
            if (lit != null && !(boolean)everSeen.invokeExact(lit)) return info;
        }
        Raised mine = raised.get();
        Object copy = mine.four[mine.next++ & 3];
        setAll.invokeExact(copy, Math.max(r, lowest), Math.max(g, lowest), Math.max(b, lowest), (float)infoA.invokeExact(info));
        return copy;
    }

    /**
     * Once a frame on the game's thread, before the player's screen is drawn: where its pixels are on the floor, and
     * now and then the values around the player. Nothing while night sight is not declared.
     */
    void frame(int playerIndex, long now) throws Throwable {
        if (floor == 0) { valuesAt = 0; darkPlace = false; hasLast = false; return; }
        Object[] local = players.all();
        if (playerIndex < 0 || playerIndex >= local.length || local[playerIndex] == null || alone(local) != playerIndex) {
            onFloor = null;
            darkPlace = false;
            hasLast = false;
            return;
        }
        Object player = local[playerIndex];
        float px = (float)xOf.invokeExact(player), py = (float)yOf.invokeExact(player);
        int z = (int)Math.floor((float)zOf.invokeExact(player));
        int x = (int)Math.floor(px), y = (int)Math.floor(py);
        placeFloor(playerIndex, x, y, z);
        if (valuesAt != 0 && now - valuesAt < REFRESH_NS) return;
        if (filling == null) filling = spare.getAndSet(null);
        if (filling == null) return;
        // the next set is due as long after as this one came (at most two refreshes: a pause is not waited out)
        filling.period = valuesAt == 0 ? REFRESH_NS : Math.max(REFRESH_NS, Math.min(2 * REFRESH_NS, now - valuesAt));
        valuesAt = now;
        fill(filling, game.cell(), playerIndex, x - SIZE / 2, y - SIZE / 2, z);
        follow(filling);
        Values given = filling;
        // the ones the render thread has not taken yet are filled again next time
        filling = ready.getAndSet(given);
    }

    // The index of the one player of this machine, or -1 with none or several (split screen).
    private static int alone(Object[] local) {
        int found = -1;
        for (int index = 0; index < local.length; index++) {
            if (local[index] == null) continue;
            if (found >= 0) return -1;
            found = index;
        }
        return found;
    }

    // From where the game draws three points of the floor, the world x and y of a pixel (x, y up from the bottom).
    private void placeFloor(int playerIndex, int x, int y, int z) throws Throwable {
        float height = (int)screenHeight.invokeExact((Object)core.invokeExact());
        double f0x = (float)screenX.invokeExact(playerIndex, (float)x, (float)y, (float)z), f0y = height - (float)screenY.invokeExact(playerIndex, (float)x, (float)y, (float)z);
        double ax = (float)screenX.invokeExact(playerIndex, (float)(x + 1), (float)y, (float)z) - f0x;
        double ay = height - (float)screenY.invokeExact(playerIndex, (float)(x + 1), (float)y, (float)z) - f0y;
        double bx = (float)screenX.invokeExact(playerIndex, (float)x, (float)(y + 1), (float)z) - f0x;
        double by = height - (float)screenY.invokeExact(playerIndex, (float)x, (float)(y + 1), (float)z) - f0y;
        double det = ax * by - ay * bx;
        if (Math.abs(det) < 1e-6) { onFloor = null; return; }
        double[] next = nextFloor;
        // world x = x + (by (fx - f0x) - bx (fy - f0y)) / det; world y = y + (ax (fy - f0y) - ay (fx - f0x)) / det
        next[0] = by / det; next[1] = -bx / det; next[2] = x - (by * f0x - bx * f0y) / det;
        next[3] = -ay / det; next[4] = ax / det; next[5] = y - (ax * f0y - ay * f0x) / det;
        nextFloor = lastFloor;
        lastFloor = next;
        onFloor = next;
    }

    // Where a square's bytes start in a set: in the first half, or in the second.
    static int first(int i, int j) { return 4 * (j * 2 * SIZE + i); }
    static int second(int i, int j) { return 4 * (j * 2 * SIZE + SIZE + i); }

    // Each square's share of its colour kept and its light sources' share of its light, how much of night sight it shows
    // and the share of what is drawn that is the game's light, 0 to 255 each, rows by y (the third and fourth bytes of
    // the square in each half).
    private void fill(Values into, Object cell, int playerIndex, int x0, int y0, int z) throws Throwable {
        into.x0 = x0;
        into.y0 = y0;
        ByteBuffer data = into.data;
        float least = floor / 255f, darkBelow = darkLight.value();
        double edge = 0, keptNear = 0;
        int near = 0, dark = 0, squares = 0, inSight = 0, radius = darkRadius.whole();
        long millis = System.currentTimeMillis();
        for (int j = 0; j < SIZE; j++) {
            for (int i = 0; i < SIZE; i++) {
                Object square = cell == null ? null : game.square(cell, x0 + i, y0 + j, z);
                walls[j * SIZE + i] = square == null ? 0 : (byte)walls(square, playerIndex, millis);
                Object lit = square == null ? null : lit(square, playerIndex);
                float whole = 0f, sources = 0f;
                boolean unseen = false;
                if (lit != null) squares++;
                if (lit != null) {
                    // out of sight: out of the vision cone or behind a wall (bCouldSee; bCanSee also asks for light, so
                    // in a room with none every square would read out of sight, and night sight would show nothing)
                    unseen = !(boolean)couldSee.invokeExact(lit);
                    if (!unseen) inSight++;
                    whole = seenLight(playerIndex, x0 + i, y0 + j, z);
                    if (whole < 0f) {
                        Object info = (Object)lightInfo.invokeExact(lit);
                        whole = luma((float)infoR.invokeExact(info), (float)infoG.invokeExact(info), (float)infoB.invokeExact(info));
                    }
                    if (whole > 0.004f) sources = Math.min(sources(lit, x0 + i, y0 + j, whole), whole);
                }
                // the game's light against the light drawn: the least light raises what is below it. A square the player
                // does not see now (out of the vision cone) the game draws dimmed its own way, which the light it hands
                // does not tell (it reads none, and the pass drew such squares black by day, measured): night sight
                // leaves it as drawn, and it does not count for a dark place
                float kept = whole >= least ? 1f : whole / least;
                float lamp = whole > 0.004f ? sources / whole : 0f;
                if (i == 0 || j == 0 || i == SIZE - 1 || j == SIZE - 1) edge += kept;
                if (lit != null && !unseen && Math.abs(i - SIZE / 2) <= radius && Math.abs(j - SIZE / 2) <= radius) {
                    near++;
                    if (whole < darkBelow) dark++;
                    keptNear += kept;
                }
                data.put(first(i, j) + 2, (byte)Math.round(kept * 255f));
                data.put(first(i, j) + 3, (byte)Math.round(lamp * 255f));
                data.put(second(i, j) + 2, (byte)(unseen ? 0 : 255));
                data.put(second(i, j) + 3, (byte)(unseen ? 255 : Math.round(kept * 255f)));
            }
        }
        into.keepTo = (float)(edge / (4 * SIZE - 4));
        if (near > 0 && dark >= darkIn.value() * near) darkPlace = true;
        else if (near == 0 || dark <= darkOut.value() * near) darkPlace = false;
        counted[0] = squares;
        counted[1] = inSight;
        counted[2] = near;
        counted[3] = dark;
        keptAround = near == 0 ? 0f : (float)(keptNear / near);
        // the faces last: what stands behind a wall is hidden by it, and the wall's face is its room's
        keepOwn(data);
        standing(data, cell, x0, y0, z);
        faces(data);
    }

    // What stands on a square's edges and rises over the squares behind it, as the player's screen draws it now: 1 a wall
    // on its north edge, 2 on its west edge (a wall, a window frame, a door frame with its door closed); 4 and 8 a doorway
    // there with no closed door (the wall above it only). An edge the game cuts away for the player (drawn low, to show
    // the player behind it) is left: the squares behind it are seen.
    private int walls(Object square, int playerIndex, long millis) throws Throwable {
        int north = 0, west = 0;
        if ((boolean)hasFlag.invokeExact(square, wallNW)) { north = 1; west = 2; }
        else {
            if ((boolean)hasFlag.invokeExact(square, wallN) || (boolean)hasFlag.invokeExact(square, windowN)) north = 1;
            else if ((boolean)hasFlag.invokeExact(square, doorN)) north = (boolean)closedDoor.invokeExact(square, edgeN) ? 1 : 4;
            if ((boolean)hasFlag.invokeExact(square, wallW) || (boolean)hasFlag.invokeExact(square, windowW)) west = 2;
            else if ((boolean)hasFlag.invokeExact(square, doorW)) west = (boolean)closedDoor.invokeExact(square, edgeW) ? 2 : 8;
        }
        int walls = north | west;
        if (walls == 0) return 0;
        int cut = (int)cutaway.invokeExact(square, playerIndex, millis);
        if ((cut & 1) != 0) walls &= ~(1 | 4);
        if ((cut & 2) != 0) walls &= ~(2 | 8);
        return walls;
    }

    /**
     * A wall's face is drawn over the squares behind it ({@link #WALL} diagonal rows) and is read as them; so they take
     * the values of the square whose side it faces (the room it stands in), where they had their own room's (a dark
     * room's wall in front of a lit corridor was drawn in its colour, a wall in front of a room in sight through a doorway
     * glowed with night sight's lift, and so did a wall in front of the player over a lit corridor). A window frame and a
     * closed door are a wall's face; a doorway's squares behind are seen through it but for the wall above it
     * ({@link #DOORWAY}); a wall the game cuts away is left ({@link #walls}). Back to front, so that a nearer wall's face is
     * over a farther one's; after the standing characters, as what stands behind a wall is hidden by it.
     */
    private void faces(ByteBuffer data) {
        for (int depth = 0; depth <= 2 * SIZE - 2; depth++)
            for (int i = Math.max(0, depth - SIZE + 1); i <= Math.min(depth, SIZE - 1); i++) {
                int j = depth - i, wall = walls[j * SIZE + i];
                if (wall == 0) continue;
                for (int k = 0; k < WALL; k++) {
                    if ((wall & 1) != 0 || (wall & 4) != 0 && k >= DOORWAY) {
                        face(data, i, j, i - k, j - 1 - k);
                        face(data, i, j, i - 1 - k, j - 1 - k);
                    }
                    if ((wall & 2) != 0 || (wall & 8) != 0 && k >= DOORWAY) {
                        face(data, i, j, i - 1 - k, j - k);
                        face(data, i, j, i - 1 - k, j - 1 - k);
                    }
                }
            }
    }

    // Each square's own values, before the standing characters and the walls' faces change them.
    private void keepOwn(ByteBuffer data) {
        for (int j = 0; j < SIZE; j++)
            for (int i = 0; i < SIZE; i++) {
                int k = 4 * (j * SIZE + i);
                own[k] = data.get(first(i, j) + 2);
                own[k + 1] = data.get(first(i, j) + 3);
                own[k + 2] = data.get(second(i, j) + 2);
                own[k + 3] = data.get(second(i, j) + 3);
            }
    }

    // The square (bi, bj) behind a wall takes the values the square (i, j) the wall stands on had of its own.
    private void face(ByteBuffer data, int i, int j, int bi, int bj) {
        if (bi < 0 || bj < 0) return;
        int k = 4 * (j * SIZE + i);
        data.put(first(bi, bj) + 2, own[k]).put(first(bi, bj) + 3, own[k + 1]);
        data.put(second(bi, bj) + 2, own[k + 2]).put(second(bi, bj) + 3, own[k + 3]);
    }

    /** Whether the player is in a dark place, as the last values had it (on the game's thread). */
    boolean darkPlace() { return darkPlace; }

    /**
     * What the last values counted (on the game's thread, for a mod's or a tester's look): the squares the game lights,
     * those in the player's sight, those near the player counted for a dark place and the dark ones of them; and the
     * mean share of colour kept near the player.
     */
    int[] counted() { return counted; }
    float keptAround() { return keptAround; }
    /** How far into the night it is, as last read; whether the values run (one player, not stopped, a set shown). */
    float night() { return night; }
    boolean valuesRun() { return !stopped && onFloor != null && hasLast; }

    // The characters standing on the floor: the squares they are drawn over keep at least their squares' values.
    private void standing(ByteBuffer data, Object cell, int x0, int y0, int z) throws Throwable {
        for (Object one : players.all()) if (one != null) stand(data, one, x0, y0, z);
        if (cell == null) return;
        ArrayList<?> zombies = (ArrayList<?>)zombieList.invokeExact(cell);
        for (int index = 0, count = zombies.size(); index < count; index++) stand(data, zombies.get(index), x0, y0, z);
    }

    private void stand(ByteBuffer data, Object character, int x0, int y0, int z) throws Throwable {
        if (character == null || (int)Math.floor((float)zOf.invokeExact(character)) != z) return;
        int i = (int)Math.floor((float)xOf.invokeExact(character)) - x0, j = (int)Math.floor((float)yOf.invokeExact(character)) - y0;
        if (i < 0 || j < 0 || i >= SIZE || j >= SIZE) return;
        int kept = data.get(first(i, j) + 2) & 0xFF, lamp = data.get(first(i, j) + 3) & 0xFF, sight = data.get(second(i, j) + 2) & 0xFF;
        int behind = standingSquares.whole();
        for (int k = 0; k <= behind; k++) {
            if (k > 0) atLeast(data, i - k, j - k, kept, lamp, sight);
            // its sides, half a square either way on the screen
            atLeast(data, i - k - 1, j - k, kept, lamp, sight);
            atLeast(data, i - k, j - k - 1, kept, lamp, sight);
        }
    }

    private static void atLeast(ByteBuffer data, int i, int j, int kept, int lamp, int sight) {
        if (i < 0 || j < 0 || i >= SIZE || j >= SIZE) return;
        int at = first(i, j) + 2;
        if ((data.get(at) & 0xFF) < kept) data.put(at, (byte)kept);
        if ((data.get(at + 1) & 0xFF) < lamp) data.put(at + 1, (byte)lamp);
        if ((data.get(second(i, j) + 2) & 0xFF) < sight) data.put(second(i, j) + 2, (byte)sight);
    }

    // The last set's values of the same squares go before this set's, and this set's go from them towards the squares'
    // by at most the game's pace (nightSight.reveal) over the time the set takes (a square the last set did not have, or with
    // none, has the square's values twice; the share of what is drawn that is the game's light follows the game at once,
    // as what it draws does), and so does its colour kept beyond them; then this set is the last.
    private void follow(Values into) {
        ByteBuffer data = into.data;
        byte[] last = lastValues, next = nextValues;
        int dx = into.x0 - lastX, dy = into.y0 - lastY;
        float pace = Math.min(1f, into.period / 1e9f / Math.max(0.01f, reveal.value()));
        int most = Math.max(1, Math.round(255f * pace));
        for (int j = 0; j < SIZE; j++) {
            int lj = j + dy;
            boolean row = hasLast && lj >= 0 && lj < SIZE;
            for (int i = 0; i < SIZE; i++) {
                int k = j * SIZE + i, li = i + dx, a = first(i, j), b = second(i, j);
                int kept = data.get(a + 2) & 0xFF, lamp = data.get(a + 3) & 0xFF, sight = data.get(b + 2) & 0xFF, drawn = data.get(b + 3) & 0xFF;
                if (row && li >= 0 && li < SIZE) {
                    int before = 4 * (lj * SIZE + li);
                    int keptBefore = last[before] & 0xFF, lampBefore = last[before + 1] & 0xFF;
                    int sightBefore = last[before + 2] & 0xFF, drawnBefore = last[before + 3] & 0xFF;
                    kept = toward(keptBefore, kept, most);
                    lamp = toward(lampBefore, lamp, most);
                    sight = toward(sightBefore, sight, most);
                    data.put(a + 2, (byte)kept).put(a + 3, (byte)lamp).put(b + 2, (byte)sight);
                    data.put(a, (byte)keptBefore).put(a + 1, (byte)lampBefore).put(b, (byte)sightBefore).put(b + 1, (byte)drawnBefore);
                } else {
                    data.put(a, (byte)kept).put(a + 1, (byte)lamp).put(b, (byte)sight).put(b + 1, (byte)drawn);
                }
                next[4 * k] = (byte)kept;
                next[4 * k + 1] = (byte)lamp;
                next[4 * k + 2] = (byte)sight;
                next[4 * k + 3] = (byte)drawn;
            }
        }
        if (hasLast) into.keepTo = lastBeyond + Math.max(-pace, Math.min(pace, into.keepTo - lastBeyond));
        into.keepFrom = hasLast ? lastBeyond : into.keepTo;
        lastBeyond = into.keepTo;
        lastX = into.x0;
        lastY = into.y0;
        lastValues = next;
        nextValues = last;
        hasLast = true;
    }

    private Object lit(Object square, int playerIndex) throws Throwable {
        Object[] all = (Object[])lighting.invokeExact(square);
        return playerIndex < all.length ? all[playerIndex] : null;
    }

    // The light the light sources that reach a square give it, counted up to at most `enough` (a room's light gives it all).
    private float sources(Object lit, int x, int y, float enough) throws Throwable {
        int count = (int)lightCount.invokeExact(lit);
        float sources = 0f;
        for (int k = 0; k < count && sources < enough; k++) {
            Object one = (Object)light.invokeExact(lit, k);
            if (one == null) continue;
            if (((int)lightFlags.invokeExact(one) & roomLight) != 0) return enough;
            int radius = (int)lightRadius.invokeExact(one);
            if (radius <= 0) continue;
            float dx = x - (int)lightX.invokeExact(one), dy = y - (int)lightY.invokeExact(one);
            float falloff = 1f - (float)Math.sqrt(dx * dx + dy * dy) / radius;
            if (falloff > 0f) sources += falloff * luma((float)lightR.invokeExact(one), (float)lightG.invokeExact(one), (float)lightB.invokeExact(one));
        }
        return sources;
    }

    static float luma(float r, float g, float b) { return 0.299f * r + 0.587f * g + 0.114f * b; }

    /**
     * The values are stopped (a fault): the screen pass keeps the colour everywhere, and the least light stays (the one
     * outside a dark place, from the next frame).
     */
    void stop() { onFloor = null; stopped = true; shade = 1f; }

    /** When the screen pass compiles: its program, whose uniforms are found when it next draws. */
    void program(int id) { program = -1 - id; }

    /**
     * Each time the screen pass draws, on the render thread with its program bound: whether night sight is on, the
     * strength of its lift, the least light shown and, while it is declared, the values (how far from the last set's to
     * the newest's, by the clock) and where the pixels are on them.
     */
    void draw(int id, float strength, float lift) throws Throwable {
        if (program != id) {
            program = id;
            strengthAt = (int)uniformAt.invokeExact(id, (CharSequence)STRENGTH);
            onAt = (int)uniformAt.invokeExact(id, (CharSequence)ON);
            keepAt = (int)uniformAt.invokeExact(id, (CharSequence)KEEP);
            lampsAt = (int)uniformAt.invokeExact(id, (CharSequence)LAMPS);
            uAt = (int)uniformAt.invokeExact(id, (CharSequence)U);
            vAt = (int)uniformAt.invokeExact(id, (CharSequence)V);
            liftAt = (int)uniformAt.invokeExact(id, (CharSequence)LIFT);
            blendAt = (int)uniformAt.invokeExact(id, (CharSequence)BLEND);
            shadeAt = (int)uniformAt.invokeExact(id, (CharSequence)SHADE);
        }
        if (onAt < 0) return;
        boolean on = floor > 0;
        uniform1f.invokeExact(onAt, on ? 1f : 0f);
        if (!on) return;
        uniform1f.invokeExact(strengthAt, strength);
        uniform1f.invokeExact(liftAt, lift);
        uniform1f.invokeExact(shadeAt, shade);
        long now = System.nanoTime();
        Values next = ready.getAndSet(null);
        if (next != null || texture == 0) {
            int active = (int)getInteger.invokeExact(ACTIVE_TEXTURE);
            activeTexture.invokeExact(TEXTURE0 + UNIT);
            if (texture == 0) {
                texture = (int)genTexture.invokeExact();
                bindTexture.invokeExact(TEXTURE_2D, texture);
                textureParameter.invokeExact(TEXTURE_2D, MIN_FILTER, LINEAR);
                textureParameter.invokeExact(TEXTURE_2D, MAG_FILTER, LINEAR);
                textureParameter.invokeExact(TEXTURE_2D, WRAP_S, CLAMP_TO_EDGE);
                textureParameter.invokeExact(TEXTURE_2D, WRAP_T, CLAMP_TO_EDGE);
                textureImage.invokeExact(TEXTURE_2D, 0, RGBA8, 2 * SIZE, SIZE, 0, RGBA, UNSIGNED_BYTE, (ByteBuffer)null);
            } else {
                bindTexture.invokeExact(TEXTURE_2D, texture);
            }
            if (next != null) {
                textureSubImage.invokeExact(TEXTURE_2D, 0, 0, 0, 2 * SIZE, SIZE, RGBA, UNSIGNED_BYTE, next.data);
                shownX = next.x0;
                shownY = next.y0;
                keepFrom = next.keepFrom;
                keepTo = next.keepTo;
                shownPeriod = next.period;
                shownAt = now;
                shown = true;
                spare.set(next);
            }
            activeTexture.invokeExact(active);
        }
        float blend = blend(now - shownAt, shownPeriod);
        uniform1f.invokeExact(blendAt, blend);
        uniform1f.invokeExact(keepAt, stopped ? 1f : keepFrom + (keepTo - keepFrom) * blend);
        uniform1i.invokeExact(lampsAt, UNIT);
        double[] at = onFloor;
        if (!shown || at == null) {
            // no values: every pixel falls outside them
            uniform3f.invokeExact(uAt, 0f, 0f, -1f);
            uniform3f.invokeExact(vAt, 0f, 0f, -1f);
            return;
        }
        // the values' u and v of a pixel: (world - start) / SIZE
        uniform3f.invokeExact(uAt, (float)(at[0] / SIZE), (float)(at[1] / SIZE), (float)((at[2] - shownX) / SIZE));
        uniform3f.invokeExact(vAt, (float)(at[3] / SIZE), (float)(at[4] / SIZE), (float)((at[5] - shownY) / SIZE));
    }
}
