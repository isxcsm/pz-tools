package pztools.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.lang.reflect.Field;
import java.nio.ByteBuffer;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Night sight's screen pass: its uniforms, and how much of the light on each square around the player is a light
 * source's (a lamp, a lit room, a torch, a car's lights) rather than the night's ambient light.
 *
 * <p>Night sight brightens the night (the ambient and the tint, before the world is drawn, and a lift of the dark tones in
 * the screen shader). What the eye saw without it keeps its colour, and what night sight adds is grey. The light a
 * square gets is the larger of the ambient and the light sources' (measured: a sealed room's squares read 0 to 0.16 with
 * the game's ambient at night and some 0.4 to 0.6 more with night sight's floor in a room; a lamp's squares read the
 * same with either). The ambient is one for the whole screen, so the floor a room gets lights the squares outdoors too
 * (measured: 0.08 to 0.32 to 0.47). A pixel keeps its colour by its square's value:
 * <ul>
 * <li>with the player outdoors, where the floor is a little, the larger of the light sources' share and {@code keep},
 * the share of the brightness of what stands there that the game's tint gives;</li>
 * <li>with the player in a room, in a room the light sources' share (the game's room is black at night: the rest is the
 * floor's); outdoors the larger of that and the game's own light outdoors against the square's, times {@code keep}. The
 * game's light outdoors is the mean light of the squares outdoors, less their light sources', the last time the player
 * was outdoors (until then, none).</li>
 * </ul>
 * Beyond the squares worked out, the same by the mean light of the squares outdoors among them. A wall or a thing
 * standing on a square is drawn above it and read as the squares behind.
 *
 * <p>A square's light sources' share is the light they give it ({@code IsoGridSquare.lighting}: the lights the game
 * finds reach it, each falling off from its colour at its square to nothing at its radius, measured; a room's light
 * fills it) against the square's whole light: a square no light source reaches is 0; the light sources' light is not
 * lifted either. The values of the {@link #SIZE}
 * squares on a side around the player, on the player's floor, are worked out on the game's thread every
 * {@link #REFRESH_NS} nanoseconds while night sight is on, and handed to the render thread, which puts them into a small
 * texture the shader reads, smoothly between squares. Where a pixel is on the floor is worked out from where the game
 * draws three points of it ({@code isoToScreenX}, {@code isoToScreenY}), every frame. Split screen gets no values (the
 * pass does not say whose screen it draws).
 *
 * <p>Two buffers go between the threads: the render thread takes the one ready, copies it to the texture and gives it
 * back; nothing is allocated after the first frame. The texture is bound on its own unit ({@link #UNIT}), and the unit
 * that was active is made active again.
 */
final class NightLamps {
    /** Squares on a side of the shares, and how often they are worked out. */
    static final int SIZE = 64;
    static final long REFRESH_NS = 100_000_000L;
    /** The texture unit the shares are bound on: one the game's screen pass does not use. */
    static final int UNIT = 12;
    static final String STRENGTH = "PZT_NightSight", KEEP = "PZT_SightKeep", LAMPS = "PZT_SightLamps", U = "PZT_SightU", V = "PZT_SightV";

    private static final int TEXTURE_2D = 0x0DE1, TEXTURE0 = 0x84C0, ACTIVE_TEXTURE = 0x84E0, RG8 = 0x822B, RG = 0x8227, UNSIGNED_BYTE = 0x1401,
        MIN_FILTER = 0x2801, MAG_FILTER = 0x2800, LINEAR = 0x2601, WRAP_S = 0x2802, WRAP_T = 0x2803, CLAMP_TO_EDGE = 0x812F;

    private final Game game;
    private final Players players;
    // IsoGridSquare.lighting; ILighting.lightInfo(), resultLightCount(), getResultLight(int); ColorInfo.r, g, b;
    // ResultLight.x, y, radius, flags and r, g, b; IsoMovingObject.getX(), getY(), getZ(); IsoGridSquare.isInARoom().
    private final MethodHandle inRoom, lighting, lightInfo, lightCount, light, infoR, infoG, infoB, lightX, lightY, lightRadius, lightFlags,
        lightR, lightG, lightB, xOf, yOf, zOf;
    private final int roomLight;
    // LuaManager.GlobalObject.isoToScreenX and Y (player, x, y, z); Core.getInstance().getScreenHeight().
    private final MethodHandle screenX, screenY, core, screenHeight;
    // GL: glGetUniformLocation, glUniform1f, glUniform1i, glUniform3f, glGenTextures, glBindTexture, glTexParameteri,
    // glTexImage2D, glTexSubImage2D, glGetInteger, glActiveTexture.
    private final MethodHandle uniformAt, uniform1f, uniform1i, uniform3f, genTexture, bindTexture, textureParameter, textureImage,
        textureSubImage, getInteger, activeTexture;

    private static final class Shares {
        final ByteBuffer data = ByteBuffer.allocateDirect(SIZE * SIZE * 2);
        int x0, y0;
    }

    // The shares ready for the render thread, and the one it gave back; the game thread's own, which it fills.
    private final AtomicReference<Shares> ready = new AtomicReference<>(), spare = new AtomicReference<>(new Shares());
    private Shares filling = new Shares();
    private long sharesAt;
    // The game's own light outdoors (the game thread's): the mean light of the squares outdoors less their light sources',
    // the last time the player was outdoors; -1 until then.
    private float outdoors = -1f;
    // The colour kept beyond the squares worked out, as the last ones had it; NaN until then (the formulas' keep).
    private volatile float beyond = Float.NaN;
    // Where a pixel of the screen (x, y up from the bottom, 1) is on the floor: world x and y, as the game thread last
    // worked it out (written whole, then published).
    private volatile double[] floor;
    private double[] nextFloor = new double[6], lastFloor = new double[6];

    // The render thread's: the program the locations are of, the locations, the texture and where its shares start.
    private int program = -1, strengthAt = -1, keepAt = -1, lampsAt = -1, uAt = -1, vAt = -1, texture;
    private int shownX, shownY;
    private boolean shown;

    NightLamps(ClassLoader loader, Game game, Players players) throws ReflectiveOperationException {
        this.game = game;
        this.players = players;
        var lookup = MethodHandles.publicLookup();
        Class<?> square = Game.type(loader, "zombie.iso.IsoGridSquare"), lights = Game.type(loader, "zombie.iso.IsoGridSquare$ILighting");
        Class<?> result = Game.type(loader, "zombie.iso.IsoGridSquare$ResultLight"), info = Game.type(loader, "zombie.core.textures.ColorInfo");
        inRoom = Game.exact(square.getMethod("isInARoom"), MethodType.methodType(boolean.class, Object.class));
        lighting = lookup.unreflectGetter(square.getField("lighting")).asType(MethodType.methodType(Object[].class, Object.class));
        lightInfo = Game.exact(lights.getMethod("lightInfo"), MethodType.methodType(Object.class, Object.class));
        lightCount = Game.exact(lights.getMethod("resultLightCount"), MethodType.methodType(int.class, Object.class));
        light = Game.exact(lights.getMethod("getResultLight", int.class), MethodType.methodType(Object.class, Object.class, int.class));
        infoR = getter(lookup, info, "r", float.class);
        infoG = getter(lookup, info, "g", float.class);
        infoB = getter(lookup, info, "b", float.class);
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
    }

    private static MethodHandle getter(MethodHandles.Lookup lookup, Class<?> owner, String name, Class<?> type) throws ReflectiveOperationException {
        Field field = owner.getField(name);
        return lookup.unreflectGetter(field).asType(MethodType.methodType(type, Object.class));
    }

    /**
     * Once a frame on the game's thread, before the player's screen is drawn: where its pixels are on the floor, and
     * now and then the shares around the player. Nothing while night sight is off.
     */
    void frame(int playerIndex, boolean on, float keep, long now) throws Throwable {
        if (!on) { sharesAt = 0; return; }
        Object[] local = players.all();
        if (playerIndex < 0 || playerIndex >= local.length || local[playerIndex] == null || alone(local) != playerIndex) { floor = null; return; }
        Object player = local[playerIndex];
        float px = (float)xOf.invokeExact(player), py = (float)yOf.invokeExact(player);
        int z = (int)Math.floor((float)zOf.invokeExact(player));
        int x = (int)Math.floor(px), y = (int)Math.floor(py);
        placeFloor(playerIndex, x, y, z);
        if (sharesAt != 0 && now - sharesAt < REFRESH_NS) return;
        if (filling == null) filling = spare.getAndSet(null);
        if (filling == null) return;
        sharesAt = now;
        Object cell = game.cell();
        Object standing = cell == null ? null : game.square(cell, x, y, z);
        boolean inside = standing != null && (boolean)inRoom.invokeExact(standing);
        fill(filling, cell, playerIndex, x - SIZE / 2, y - SIZE / 2, z, inside, keep);
        Shares given = filling;
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
        if (Math.abs(det) < 1e-6) { floor = null; return; }
        double[] next = nextFloor;
        // world x = x + (by (fx - f0x) - bx (fy - f0y)) / det; world y = y + (ax (fy - f0y) - ay (fx - f0x)) / det
        next[0] = by / det; next[1] = -bx / det; next[2] = x - (by * f0x - bx * f0y) / det;
        next[3] = -ay / det; next[4] = ax / det; next[5] = y - (ax * f0y - ay * f0x) / det;
        nextFloor = lastFloor;
        lastFloor = next;
        floor = next;
    }

    // Each square's share of its colour kept and its light sources' share of its light, 0 to 255 each, rows by y.
    private void fill(Shares into, Object cell, int playerIndex, int x0, int y0, int z, boolean inside, float keep) throws Throwable {
        into.x0 = x0;
        into.y0 = y0;
        ByteBuffer data = into.data;
        // the squares outdoors with light: their light, and their light less their light sources'
        double outdoorLight = 0, outdoorOwn = 0;
        int outdoorSquares = 0;
        float known = outdoors;
        for (int j = 0; j < SIZE; j++) {
            for (int i = 0; i < SIZE; i++) {
                Object square = cell == null ? null : game.square(cell, x0 + i, y0 + j, z);
                Object lit = square == null ? null : lit(square, playerIndex);
                float whole = 0f, sources = 0f;
                if (lit != null) {
                    Object info = (Object)lightInfo.invokeExact(lit);
                    whole = luma((float)infoR.invokeExact(info), (float)infoG.invokeExact(info), (float)infoB.invokeExact(info));
                    if (whole > 0.004f) sources = Math.min(sources(lit, x0 + i, y0 + j, whole), whole);
                }
                float lamp = whole > 0.004f ? sources / whole : 0f;
                float kept;
                if (square != null && (boolean)inRoom.invokeExact(square)) {
                    kept = inside ? lamp : Math.max(lamp, keep);
                } else {
                    if (whole > 0.004f) { outdoorLight += whole; outdoorOwn += whole - sources; outdoorSquares++; }
                    kept = !inside ? Math.max(lamp, keep) : known < 0f || whole <= 0.004f ? lamp : Math.max(lamp, Math.min(1f, known / whole) * keep);
                }
                data.put(2 * (j * SIZE + i), (byte)Math.round(kept * 255f));
                data.put(2 * (j * SIZE + i) + 1, (byte)Math.round(lamp * 255f));
            }
        }
        if (!inside) {
            if (outdoorSquares > 0) outdoors = (float)(outdoorOwn / outdoorSquares);
            beyond = keep;
        } else {
            beyond = known < 0f || outdoorSquares == 0 ? 0f : Math.min(1f, known / (float)(outdoorLight / outdoorSquares)) * keep;
        }
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

    /**
     * How dark the player's square is by its light sources alone (1 with none, 0 under a lamp), as the game thread asks
     * it; 1 off any square. Night sight's own light does not change it.
     */
    float sourceDark(int playerIndex) throws Throwable {
        Object[] local = players.all();
        if (playerIndex < 0 || playerIndex >= local.length || local[playerIndex] == null) return 1f;
        Object player = local[playerIndex];
        int x = (int)Math.floor((float)xOf.invokeExact(player)), y = (int)Math.floor((float)yOf.invokeExact(player));
        int z = (int)Math.floor((float)zOf.invokeExact(player));
        Object cell = game.cell();
        Object square = cell == null ? null : game.square(cell, x, y, z);
        Object lit = square == null ? null : lit(square, playerIndex);
        return lit == null ? 1f : 1f - Math.min(1f, sources(lit, x, y, 1f));
    }

    static float luma(float r, float g, float b) { return 0.299f * r + 0.587f * g + 0.114f * b; }

    /** The shares are stopped (a fault): the screen pass keeps its strength and the game's share of the ambient alone. */
    void stop() { floor = null; beyond = Float.NaN; }

    /** When the screen pass compiles: its program, whose uniforms are found when it next draws. */
    void program(int id) { program = -1 - id; }

    /**
     * Each time the screen pass draws, on the render thread with its program bound: the strength, and while it is on the
     * game's share of the ambient light, the shares and where the pixels are on them.
     */
    void draw(int id, float strength, float keep) throws Throwable {
        if (program != id) {
            program = id;
            strengthAt = (int)uniformAt.invokeExact(id, (CharSequence)STRENGTH);
            keepAt = (int)uniformAt.invokeExact(id, (CharSequence)KEEP);
            lampsAt = (int)uniformAt.invokeExact(id, (CharSequence)LAMPS);
            uAt = (int)uniformAt.invokeExact(id, (CharSequence)U);
            vAt = (int)uniformAt.invokeExact(id, (CharSequence)V);
        }
        if (strengthAt < 0) return;
        uniform1f.invokeExact(strengthAt, strength);
        if (strength <= 0f) return;
        float outside = beyond;
        uniform1f.invokeExact(keepAt, outside == outside ? outside : keep);
        Shares next = ready.getAndSet(null);
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
                textureImage.invokeExact(TEXTURE_2D, 0, RG8, SIZE, SIZE, 0, RG, UNSIGNED_BYTE, (ByteBuffer)null);
            } else {
                bindTexture.invokeExact(TEXTURE_2D, texture);
            }
            if (next != null) {
                textureSubImage.invokeExact(TEXTURE_2D, 0, 0, 0, SIZE, SIZE, RG, UNSIGNED_BYTE, next.data);
                shownX = next.x0;
                shownY = next.y0;
                shown = true;
                spare.set(next);
            }
            activeTexture.invokeExact(active);
        }
        uniform1i.invokeExact(lampsAt, UNIT);
        double[] at = floor;
        if (!shown || at == null) {
            // no shares: every pixel falls outside them
            uniform3f.invokeExact(uAt, 0f, 0f, -1f);
            uniform3f.invokeExact(vAt, 0f, 0f, -1f);
            return;
        }
        // the shares' u and v of a pixel: (world - start) / SIZE
        uniform3f.invokeExact(uAt, (float)(at[0] / SIZE), (float)(at[1] / SIZE), (float)((at[2] - shownX) / SIZE));
        uniform3f.invokeExact(vAt, (float)(at[3] / SIZE), (float)(at[4] / SIZE), (float)((at[5] - shownY) / SIZE));
    }
}
