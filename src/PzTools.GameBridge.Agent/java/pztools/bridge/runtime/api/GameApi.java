package pztools.bridge.runtime.api;

import pztools.bridge.ApiHooks;

/**
 * The extension API for Lua mods (docs/design/extension-api.md): the global table {@code PZToolsAPI}, set into each Lua
 * environment the game makes, in a game the startup loader started. It is part of that install, not an extension the
 * player switches: once started it stays until the game exits, and a newer payload takes it over.
 */
public final class GameApi {
    /** Raised on any incompatible change to what a mod sees. */
    public static final int VERSION = 1;
    static final String GLOBAL = "PZToolsAPI";
    private static final String AREA = "PZToolsAPI.";
    // In the table's metatable: marks it as this API's, so that a newer payload updates it in place and the tables mods
    // hold stay valid; and keeps the mods' handles.
    private static final String MARK = "pztools", HANDLES = "clients", HANDLE_METHODS = "clientMethods",
        HANDLE_META = "clientMeta";
    private static final String NAME = "[A-Za-z0-9_.-]{1,64}";
    // Set when this payload's API has not reached the Lua environment the game has now.
    private static volatile boolean pending;
    // The networks of the Lua environment the game has now; null without one, or when the game cannot run them.
    private static volatile Networks networks;

    private GameApi() { }

    /** In a game the startup loader started, once per payload: the game's Lua environments get the API from now on. */
    public static void start() {
        try { ApiHooks.set(GameApi::luaStarted); }
        catch (LinkageError olderBootstrap) {
            // The game was started by an install from before the API: it comes with the next start.
            System.err.println("[PzTools API] Not in this game; restart it to use the API: " + olderBootstrap);
            return;
        }
        pending = true;
    }

    /**
     * Each frame, on the game's thread. Sets the API into the environment the game already had when this payload
     * started: a payload that replaced an older one, or one that came after the game's Lua had started.
     */
    public static void frame(ClassLoader game) {
        if (pending) {
            pending = false;
            try { register(Class.forName("zombie.Lua.LuaManager", false, game)); }
            catch (Throwable failure) { report(failure); }
        }
        Networks current = networks;
        if (current != null) current.frame();
    }

    private static void luaStarted(Class<?> luaManager) {
        pending = false;
        try { register(luaManager); }
        catch (Throwable failure) { report(failure); }
    }

    static void register(Class<?> luaManager) throws ReflectiveOperationException {
        var lua = new Kahlua(luaManager);
        Object env = lua.environment();
        if (env == null) return; // The game's Lua has not started; its start sets the API.
        Object api = lua.get(env, GLOBAL);
        Object meta = lua.isTable(api) ? lua.metatable(api) : null;
        if (meta == null || !Boolean.TRUE.equals(lua.get(meta, MARK))) {
            api = lua.table();
            meta = lua.table();
            lua.set(meta, MARK, true);
            lua.setMetatable(api, meta);
        }
        lua.set(api, "version", (double)VERSION);
        Object handles = clients(lua, api, meta);
        var buildings = new Buildings(lua, luaManager.getClassLoader());
        buildings.register(table(lua, api, "buildings"));
        networks(lua, api, meta, handles, buildings, luaManager.getClassLoader());
        lua.set(env, GLOBAL, api);
    }

    /**
     * {@code PZToolsAPI.networks}, with the definitions an earlier payload kept in this environment. Without it (a game
     * started by an install from before the networks, or a game this payload cannot read), mods find no
     * {@code networks} and the game answers every power and water question alone.
     */
    private static void networks(Kahlua lua, Object api, Object meta, Object handles, Buildings buildings, ClassLoader game)
            throws ReflectiveOperationException {
        Networks next;
        try {
            next = new Networks(lua, buildings, game, meta, handle -> owner(lua, handles, handle));
            next.hook();
        } catch (LinkageError olderBootstrap) {
            System.err.println("[PzTools API] Networks are not in this game; restart it to use them: " + olderBootstrap);
            next = null;
        } catch (ReflectiveOperationException | RuntimeException unreadable) {
            report(unreadable);
            Networks.unhook();
            next = null;
        }
        networks = next;
        if (next != null) next.register(table(lua, api, "networks"));
        else lua.set(api, "networks", null);
    }

    /** The mod a handle belongs to, or null when the value is not one of this environment's handles. */
    private static String owner(Kahlua lua, Object handles, Object handle) throws ReflectiveOperationException {
        Object name = lua.isTable(handle) ? lua.get(handle, "name") : null;
        return name instanceof String text && lua.get(handles, text) == handle ? text : null;
    }

    /** {@code PZToolsAPI.client(name)}: one handle per name, which everything the mod defines belongs to. The handles. */
    private static Object clients(Kahlua lua, Object api, Object meta) throws ReflectiveOperationException {
        Object handles = table(lua, meta, HANDLES), methods = table(lua, meta, HANDLE_METHODS);
        Object handleMeta = lua.get(meta, HANDLE_META);
        if (!lua.isTable(handleMeta)) {
            handleMeta = lua.table();
            lua.set(handleMeta, "__index", methods);
            lua.set(meta, HANDLE_META, handleMeta);
        }
        Object handleMetatable = handleMeta;
        lua.set(api, "client", lua.function(AREA + "client", arguments -> {
            String name = Arguments.string(arguments, 0, AREA + "client", "name");
            if (!name.matches(NAME))
                throw new IllegalArgumentException(AREA + "client: name must be 1 to 64 letters, digits, '_', '.' or '-'");
            Object handle = lua.get(handles, name);
            if (handle == null) {
                handle = lua.table();
                lua.set(handle, "name", name);
                lua.setMetatable(handle, handleMetatable);
                lua.set(handles, name, handle);
            }
            return new Object[] { handle };
        }));
        lua.set(methods, "clear", lua.function(AREA + "client:clear", arguments -> {
            String name = owner(lua, handles, arguments.length > 0 ? arguments[0] : null);
            if (name == null) throw new IllegalArgumentException(AREA + "client:clear: call it on a handle, with a colon");
            Networks current = networks;
            if (current != null) current.clear(name);
            return new Object[0];
        }));
        return handles;
    }

    private static Object table(Kahlua lua, Object owner, String key) throws ReflectiveOperationException {
        Object table = lua.get(owner, key);
        if (!lua.isTable(table)) { table = lua.table(); lua.set(owner, key, table); }
        return table;
    }

    private static void report(Throwable failure) { System.err.println("[PzTools API] " + failure); }
}
