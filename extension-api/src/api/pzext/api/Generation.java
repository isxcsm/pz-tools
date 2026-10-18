package pzext.api;

/**
 * Which API runs an area's functions now (docs/design.md, "Reaching the API from Lua"). Each API that registers an area takes the
 * next number, kept in the API table's metatable, where a newer API finds it; a function a mod copied out of the table checks its
 * own number first and refuses to run once a newer API (or a failed install, {@link #retire}) has moved it on.
 */
final class Generation {
    private final Kahlua lua;
    private final Object meta;
    private final String key;
    // This API's number for the area; 0 until start.
    private long mine;

    Generation(Kahlua lua, Object meta, String key) {
        this.lua = lua;
        this.meta = meta;
        this.key = key;
    }

    /** This API takes the area over: the functions of an earlier API refuse to run from now on. */
    void start() throws ReflectiveOperationException {
        mine = current(lua, meta, key) + 1;
        lua.set(meta, key, (double)mine);
    }

    /** Throws the mod's error unless this API still runs the area. */
    void check(String call) throws ReflectiveOperationException {
        if (mine == 0 || current(lua, meta, key) != mine)
            throw new IllegalArgumentException(call + ": the API was updated since this function was read; read it again from PZExtAPI");
    }

    /** No function of the area runs any more: those a mod kept refuse to be called. */
    static void retire(Kahlua lua, Object meta, String key) {
        try { lua.set(meta, key, (double)(current(lua, meta, key) + 1)); }
        catch (ReflectiveOperationException | RuntimeException unwritable) { }
    }

    private static long current(Kahlua lua, Object meta, String key) throws ReflectiveOperationException {
        return lua.get(meta, key) instanceof Double number ? number.longValue() : 0;
    }
}
