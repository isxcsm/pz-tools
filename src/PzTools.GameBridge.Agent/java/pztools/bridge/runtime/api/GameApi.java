package pztools.bridge.runtime.api;

import pztools.bridge.ApiHooks;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.Map;

/**
 * The extension API for Lua mods (docs/design/extension-api.md): the global table {@code PZToolsAPI}, set into each Lua
 * environment the game makes, in a game the startup loader started. It is part of that install, not an extension the
 * player switches: once started it stays until the game exits, and a newer payload takes it over.
 */
public final class GameApi {
    /** Raised on any incompatible change to what a mod sees. */
    public static final int VERSION = 1;
    /** In the install folder: which of the API's hooks this game has, for the app (see {@link #writeStatus}). */
    public static final String STATUS = "api.tsv";
    static final String GLOBAL = "PZToolsAPI";
    private static final String AREA = "PZToolsAPI.";
    // In the table's metatable: marks it as this API's, so that a newer payload updates it in place and the tables mods
    // hold stay valid; and keeps the mods' handles.
    private static final String MARK = "pztools", HANDLES = "clients", HANDLE_METHODS = "clientMethods",
        HANDLE_META = "clientMeta";
    // Set when this payload's API has not reached the Lua environment the game has now.
    private static volatile boolean pending;
    // The networks of the Lua environment the game has now; null without one, or when the game cannot run them.
    private static volatile Networks networks;
    // What writeStatus last wrote; on the resident controller's thread only.
    private static String written;

    private GameApi() { }

    /** In a game the startup loader started, once per payload: the game's Lua environments get the API from now on. */
    public static void start() {
        // Before the handler is published: the game's Lua may start at once, and its start sets the API and clears this.
        pending = true;
        try { ApiHooks.set(GameApi::luaStarted); }
        catch (LinkageError olderBootstrap) {
            // The game was started by an install from before the API: it comes with the next start.
            pending = false;
            System.err.println("[PzTools API] Not in this game; restart it to use the API: " + olderBootstrap);
        }
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

    /**
     * Sets the API into the game's Lua environment, taking over from an earlier payload. Should that fail, the game
     * answers every power and water question alone: the earlier payload's networks no longer run, so they must not
     * answer from what they last knew.
     */
    static void register(Class<?> luaManager) throws ReflectiveOperationException {
        try { install(luaManager); }
        catch (Throwable failure) {
            networks = null;
            Networks.unhook();
            throw failure;
        }
    }

    private static void install(Class<?> luaManager) throws ReflectiveOperationException {
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
        lua.set(api, "hooks", lua.function(AREA + "hooks", arguments -> {
            Object table = lua.table();
            for (var hook : hooks().entrySet()) lua.set(table, hook.getKey(), hook.getValue());
            return new Object[] { table };
        }));
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
            String name = Arguments.name(arguments, 0, AREA + "client", "name");
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

    /** {@link ApiHooks#hookStatus}; empty from a bootstrap that does not keep it (a game started before it did). */
    private static Map<String, String> hooks() {
        try { return ApiHooks.hookStatus(); }
        catch (LinkageError olderBootstrap) { return Map.of(); }
    }

    /**
     * Writes which hooks this game has to the install folder, for the app, when that changed. Called by the resident
     * controller about once a second; a hook's state changes as its class loads, most of them with the first world.
     * The file names this process, so that the app does not read an earlier game's.
     */
    public static void writeStatus(Path folder) {
        var text = new StringBuilder("PZTOOLS-API\t1\npid\t").append(ProcessHandle.current().pid()).append('\n');
        for (var hook : hooks().entrySet())
            text.append("hook\t").append(hook.getKey()).append('\t').append(hook.getValue().replaceAll("[\\t\\r\\n]+", " ")).append('\n');
        String next = text.toString();
        if (next.equals(written)) return;
        try {
            Path temporary = folder.resolve(STATUS + ".tmp");
            Files.writeString(temporary, next, StandardCharsets.UTF_8);
            Files.move(temporary, folder.resolve(STATUS), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
            written = next;
        } catch (IOException | RuntimeException unwritable) { } // Tried again on the next pass; the app reads no file as unknown.
    }

    private static Object table(Kahlua lua, Object owner, String key) throws ReflectiveOperationException {
        Object table = lua.get(owner, key);
        if (!lua.isTable(table)) { table = lua.table(); lua.set(owner, key, table); }
        return table;
    }

    private static void report(Throwable failure) { System.err.println("[PzTools API] " + failure); }
}
