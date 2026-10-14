package pzext.api;

import pzext.boot.Hooks;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.Map;

/**
 * The extension API for Lua mods (docs/design.md): the global table {@code PZExtAPI}, set into each Lua
 * environment the game makes, in a game the API's loader started. It is part of that install, not an extension the
 * player switches: once started it stays until the game exits, and a newer API takes it over.
 */
public final class GameApi {
    /** Raised on any incompatible change to what a mod sees. */
    public static final int VERSION = 1;
    /** In the install folder: which of the API's hooks this game has, for whoever installed the API (see {@link #writeStatus}). */
    public static final String STATUS = "api.tsv";
    static final String GLOBAL = "PZExtAPI";
    private static final String AREA = "PZExtAPI.";
    // In the table's metatable: marks it as this API's, so that a newer API updates it in place and the tables mods
    // hold stay valid; and keeps the mods' handles.
    private static final String MARK = "pzext", HANDLES = "clients", HANDLE_METHODS = "clientMethods",
        HANDLE_META = "clientMeta";
    // Set when this API has not reached the Lua environment the game has now.
    private static volatile boolean pending;
    // The networks of the Lua environment the game has now; null without one, or when the game cannot run them.
    private static volatile Networks networks;
    // The formulas of the Lua environment the game has now; null without one, or when the game cannot run them.
    private static volatile Formulas formulas;
    // The helicopter of the Lua environment the game has now; null without one, or when the game cannot read it.
    private static volatile Helicopters helicopters;
    // The moodles of the Lua environment the game has now; null without one, or when the game cannot run them.
    private static volatile Moodles moodles;
    // The text of the Lua environment the game has now; null without one, or when the game cannot draw it.
    private static volatile Texts texts;
    // The zombies' sounds of the Lua environment the game has now; null without one, when the game cannot hook them, or after a fault.
    private static volatile ZombieSounds sounds;
    // The hits zombies take, of the Lua environment the game has now; null without one, when the game cannot hook them, or after a fault.
    private static volatile ZombieHits hits;
    // The zombies mods hold in areas, of the Lua environment the game has now; null without one, when the game cannot hook them, or after a fault.
    private static volatile ZombieHolds holds;
    // The timers and the chunk watches of the Lua environment the game has now; null without one, or when the game cannot run them.
    private static volatile Timers timers;
    private static volatile ChunkWatches chunks;
    // The floor decals of the Lua environment the game has now; null without one, or when the game cannot draw them.
    private static volatile FloorDecals floor;
    // The square watches of the Lua environment the game has now; null without one, or when the game cannot tell them.
    private static volatile SquareWatches squares;
    // The buildings of the Lua environment the game has now, watched each frame for what changes them (Buildings.observe).
    private static volatile Buildings buildings;
    private static boolean buildingsReported;
    // What writeStatus last wrote; on the boot layer's host thread only.
    private static String written;

    private GameApi() { }

    /** The formulas of the Lua environment the game has now, or null (for the tests of this package). */
    static Formulas formulas() { return formulas; }

    static Buildings buildings() { return buildings; }

    /** The text of the Lua environment the game has now, or null (for the tests of this package). */
    static Texts texts() { return texts; }

    /** The zombies' sounds of the Lua environment the game has now, or null (for the tests of this package). */
    static ZombieSounds sounds() { return sounds; }

    /** The hits zombies take, of the Lua environment the game has now, or null (for the tests of this package). */
    static ZombieHits hits() { return hits; }

    /** The zombies mods hold, of the Lua environment the game has now, or null (for the tests of this package). */
    static ZombieHolds holds() { return holds; }

    /** The timers of the Lua environment the game has now, or null (for the tests of this package). */
    static Timers timers() { return timers; }

    /** The chunk watches of the Lua environment the game has now, or null (for the tests of this package). */
    static ChunkWatches chunks() { return chunks; }

    /** The floor decals of the Lua environment the game has now, or null (for the tests of this package). */
    static FloorDecals floor() { return floor; }

    /** The square watches of the Lua environment the game has now, or null (for the tests of this package). */
    static SquareWatches squares() { return squares; }

    /**
     * In a game the API's loader started, once each time its jar is loaded (the boot layer's Host): the game's Lua
     * environments get the API from now on.
     */
    public static void start() {
        // Before the handler is published: the game's Lua may start at once, and its start sets the API and clears this.
        pending = true;
        try { Hooks.set(GameApi::luaStarted); }
        catch (LinkageError olderBootstrap) {
            // The game was started by an install from before the API: it comes with the next start.
            pending = false;
            System.err.println("[PZExt] Not in this game; restart it to use the API: " + olderBootstrap);
        }
    }

    /**
     * Each frame, on the game's thread. Sets the API into the environment the game already had when this API
     * started: one that replaced an older one, or one that came after the game's Lua had started.
     */
    public static void frame(ClassLoader game) {
        if (pending) {
            pending = false;
            try { register(Class.forName("zombie.Lua.LuaManager", false, game)); }
            catch (Throwable failure) { report(failure); }
        }
        Buildings watched = buildings;
        if (watched != null) {
            try { watched.observe(); }
            catch (Throwable failure) {
                // Once: the calls that read buildings observe too, and fail on their own.
                if (!buildingsReported) System.err.println("[PZExt] buildings: " + failure);
                buildingsReported = true;
            }
        }
        Networks current = networks;
        if (current != null) current.frame();
        Formulas declared = formulas;
        if (declared != null) declared.frame();
        Moodles defined = moodles;
        if (defined != null) defined.frame();
        Texts shown = texts;
        if (shown != null) shown.frame();
        ZombieSounds heard = sounds;
        if (heard != null) {
            try { heard.frame(); }
            catch (Throwable failure) {
                // Once, as the helicopter's: the hooks are given back and the rest of the API goes on.
                sounds = null;
                heard.stop();
                System.err.println("[PZExt] zombie sounds stopped: " + failure);
            }
        }
        ZombieHits struck = hits;
        if (struck != null) {
            try { struck.frame(); }
            catch (Throwable failure) {
                // Once, as the sounds' are: the hook is given back and the rest of the API goes on.
                hits = null;
                struck.stop();
                System.err.println("[PZExt] zombie hits stopped: " + failure);
            }
        }
        ZombieHolds holding = holds;
        if (holding != null) {
            try { holding.frame(); }
            catch (Throwable failure) {
                // Once, as the hits': the hooks are given back and the rest of the API goes on.
                holds = null;
                holding.stop();
                System.err.println("[PZExt] zombie holds stopped: " + failure);
            }
        }
        Timers counting = timers;
        if (counting != null) counting.frame();
        ChunkWatches watching = chunks;
        if (watching != null) watching.frame();
        FloorDecals decals = floor;
        if (decals != null) decals.frame();
        SquareWatches told = squares;
        if (told != null) told.frame();
        Helicopters flying = helicopters;
        if (flying != null) {
            try { flying.frame(); }
            catch (Throwable failure) {
                // Once: a fault that recurs each frame must not flood the game's log. The state can still be read.
                helicopters = null;
                System.err.println("[PZExt] helicopter events stopped: " + failure);
            }
        }
    }

    private static void luaStarted(Class<?> luaManager) {
        pending = false;
        try { register(luaManager); }
        catch (Throwable failure) { report(failure); }
    }

    /**
     * Sets the API into the game's Lua environment, taking over from an earlier API. Should that fail, the game
     * answers every power and water question alone: the earlier API's networks no longer run, so they must not
     * answer from what they last knew.
     */
    static void register(Class<?> luaManager) throws ReflectiveOperationException {
        try { install(luaManager); }
        catch (Throwable failure) {
            buildings = null;
            networks = null;
            formulas = null;
            helicopters = null;
            moodles = null;
            texts = null;
            sounds = null;
            hits = null;
            holds = null;
            timers = null;
            chunks = null;
            floor = null;
            squares = null;
            Networks.unhook();
            Formulas.unhook();
            Moodles.unhook();
            Texts.unhook();
            ZombieSounds.unhook();
            ZombieHits.unhook();
            ZombieHolds.unhook();
            Outlines.unhook();
            WorldItems.unhook();
            FloorDecals.unhook();
            SquareWatches.unhook();
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
        try {
            lua.set(api, "version", (double)VERSION);
            lua.set(api, "hooks", lua.function(AREA + "hooks", arguments -> {
                Object table = lua.table();
                for (var hook : hooks().entrySet()) lua.set(table, hook.getKey(), hook.getValue());
                return new Object[] { table };
            }));
            Object handles = clients(lua, api, meta);
            var game = new Game(luaManager.getClassLoader());
            var read = new Buildings(lua, game, luaManager.getClassLoader());
            Object buildingsTable = table(lua, api, "buildings");
            read.register(buildingsTable);
            buildings = read;
            containers(lua, read, game, buildingsTable, luaManager.getClassLoader());
            networks(lua, api, meta, handles, game, read, luaManager.getClassLoader());
            formulas(lua, api, meta, handles, game, luaManager.getClassLoader());
            moodles(lua, api, meta, handles, game, luaManager.getClassLoader());
            texts(lua, api, meta, handles, game, luaManager.getClassLoader());
            systems(lua, api, meta, handles, game, luaManager.getClassLoader());
            scheduled(lua, api, meta, handles, game, luaManager.getClassLoader());
            lua.set(env, GLOBAL, api);
        } catch (Throwable failure) {
            // The functions mods kept refuse to be called rather than change networks and formulas that no longer run.
            Networks.retire(lua, meta);
            Formulas.retire(lua, meta);
            Moodles.retire(lua, meta);
            Texts.retire(lua, meta);
            ZombieSounds.retire(lua, meta);
            ZombieHits.retire(lua, meta);
            ZombieHolds.retire(lua, meta);
            Timers.retire(lua, meta);
            ChunkWatches.retire(lua, meta);
            FloorDecals.retire(lua, meta);
            SquareWatches.retire(lua, meta);
            throw failure;
        }
    }

    /**
     * {@code PZExtAPI.networks}, with the definitions an earlier API kept in this environment. Without it (a game
     * started by an install from before the networks, or a game this API cannot read), mods find no
     * {@code networks} and the game answers every power and water question alone.
     */
    private static void networks(Kahlua lua, Object api, Object meta, Object handles, Game game, Buildings buildings,
            ClassLoader loader) throws ReflectiveOperationException {
        Networks next;
        try {
            next = new Networks(lua, game, buildings, loader, meta, handle -> owner(lua, handles, handle));
            next.hook();
        } catch (LinkageError olderBootstrap) {
            System.err.println("[PZExt] Networks are not in this game; restart it to use them: " + olderBootstrap);
            next = null;
        } catch (ReflectiveOperationException | RuntimeException unreadable) {
            report(unreadable);
            Networks.unhook();
            next = null;
        }
        networks = next;
        if (next != null) next.register(table(lua, api, "networks"));
        else {
            Networks.retire(lua, meta);
            lua.set(api, "networks", null);
        }
    }

    /**
     * {@code PZExtAPI.formulas}, with the declarations an earlier API kept in this environment. Without it (a game
     * started by an install from before the formulas, or a game this API cannot read), mods find no {@code formulas}
     * and the game answers every formula question alone.
     */
    private static void formulas(Kahlua lua, Object api, Object meta, Object handles, Game game, ClassLoader loader)
            throws ReflectiveOperationException {
        Formulas next;
        try {
            next = new Formulas(lua, game, loader, meta, handle -> owner(lua, handles, handle));
            next.hook();
        } catch (LinkageError olderBootstrap) {
            System.err.println("[PZExt] Formulas are not in this game; restart it to use them: " + olderBootstrap);
            next = null;
        } catch (ReflectiveOperationException | RuntimeException unreadable) {
            report(unreadable);
            Formulas.unhook();
            next = null;
        }
        formulas = next;
        if (next != null) {
            next.register(table(lua, api, "formulas"));
            next.registerItems(table(lua, api, "items"));
        } else {
            Formulas.retire(lua, meta);
            lua.set(api, "formulas", null);
            lua.set(api, "items", null);
        }
    }

    /**
     * {@code PZExtAPI.moodles}, with the definitions an earlier API kept in this environment. Without it (a game started by an
     * install from before the moodles, or a game this API cannot read), mods find no {@code moodles} and the game's moodles are
     * its own.
     */
    private static void moodles(Kahlua lua, Object api, Object meta, Object handles, Game game, ClassLoader loader)
            throws ReflectiveOperationException {
        Moodles next;
        try {
            next = new Moodles(lua, game, loader, meta, handle -> owner(lua, handles, handle));
            next.hook();
        } catch (LinkageError olderBootstrap) {
            System.err.println("[PZExt] Moodles are not in this game; restart it to use them: " + olderBootstrap);
            next = null;
        } catch (ReflectiveOperationException | RuntimeException unreadable) {
            report(unreadable);
            Moodles.unhook();
            next = null;
        }
        moodles = next;
        if (next != null) next.register(table(lua, api, "moodles"));
        else {
            Moodles.retire(lua, meta);
            lua.set(api, "moodles", null);
        }
    }

    /**
     * {@code PZExtAPI.text}, with what an earlier API showed. Without it (a game started by an install from before the text, or
     * a game whose drawing this API cannot reach), mods find no {@code text}.
     */
    private static void texts(Kahlua lua, Object api, Object meta, Object handles, Game game, ClassLoader loader)
            throws ReflectiveOperationException {
        Texts next;
        try {
            next = new Texts(lua, game, loader, meta, handle -> owner(lua, handles, handle));
            next.hook();
        } catch (LinkageError olderBootstrap) {
            System.err.println("[PZExt] Text is not in this game; restart it to use it: " + olderBootstrap);
            next = null;
        } catch (ReflectiveOperationException | RuntimeException unreadable) {
            report(unreadable);
            Texts.unhook();
            next = null;
        }
        texts = next;
        if (next != null) next.register(table(lua, api, "text"));
        else {
            Texts.retire(lua, meta);
            lua.set(api, "text", null);
        }
    }

    /**
     * {@code PZExtAPI.zombies} (with {@code listen} for the zombies' sounds) and {@code PZExtAPI.helicopter}. Each is left
     * out, with a line in the game's log, in a game that does not have what it reads: the others go on.
     */
    private static void systems(Kahlua lua, Object api, Object meta, Object handles, Game game, ClassLoader loader)
            throws ReflectiveOperationException {
        Object zombies = null;
        try {
            zombies = table(lua, api, "zombies");
            new Zombies(lua, game, loader).register(zombies);
        } catch (ReflectiveOperationException | RuntimeException | LinkageError unreadable) {
            report(unreadable);
            lua.set(api, "zombies", null);
            zombies = null;
        }
        ZombieSounds heard = null;
        if (zombies != null) {
            try {
                heard = new ZombieSounds(lua, game, loader, meta, handle -> owner(lua, handles, handle));
                heard.hook();
            } catch (LinkageError olderBootstrap) {
                System.err.println("[PZExt] Zombie sounds are not in this game; restart it to use them: " + olderBootstrap);
                heard = null;
            } catch (ReflectiveOperationException | RuntimeException unreadable) {
                report(unreadable);
                ZombieSounds.unhook();
                heard = null;
            }
        }
        sounds = heard;
        if (heard != null) heard.register(zombies);
        else {
            ZombieSounds.retire(lua, meta);
            if (zombies != null) lua.set(zombies, "listen", null);
        }
        ZombieHits struck = null;
        if (zombies != null) {
            try {
                struck = new ZombieHits(lua, game, loader, meta, handle -> owner(lua, handles, handle));
                struck.hook();
            } catch (LinkageError olderBootstrap) {
                System.err.println("[PZExt] Zombie hits are not in this game; restart it to use them: " + olderBootstrap);
                struck = null;
            } catch (ReflectiveOperationException | RuntimeException unreadable) {
                report(unreadable);
                ZombieHits.unhook();
                struck = null;
            }
        }
        hits = struck;
        if (struck != null) struck.register(zombies);
        else {
            ZombieHits.retire(lua, meta);
            if (zombies != null) lua.set(zombies, "watchHits", null);
        }
        ZombieHolds holding = null;
        if (zombies != null) {
            try {
                holding = new ZombieHolds(lua, game, loader, meta, handle -> owner(lua, handles, handle));
                holding.hook();
            } catch (LinkageError olderBootstrap) {
                System.err.println("[PZExt] Zombie holds are not in this game; restart it to use them: " + olderBootstrap);
                holding = null;
            } catch (ReflectiveOperationException | RuntimeException unreadable) {
                report(unreadable);
                ZombieHolds.unhook();
                holding = null;
            }
        }
        holds = holding;
        if (holding != null) holding.register(zombies);
        else {
            ZombieHolds.retire(lua, meta);
            if (zombies != null) { lua.set(zombies, "hold", null); lua.set(zombies, "release", null); }
        }
        // The game's outline on models and vehicles: nothing to declare, so always on.
        try { new Outlines(loader).hook(); }
        catch (LinkageError olderBootstrap) {
            System.err.println("[PZExt] Model and vehicle outlines are not in this game; restart it to have them: " + olderBootstrap);
        } catch (ReflectiveOperationException | RuntimeException unreadable) {
            report(unreadable);
            Outlines.unhook();
        }
        // What the game takes of the world's items (a fire, the sandbox's removal): nothing to declare, so always on.
        try { new WorldItems(game, loader).hook(); }
        catch (LinkageError olderBootstrap) {
            System.err.println("[PZExt] Burning containers and kept floor items are not in this game; restart it to have them: "
                + olderBootstrap);
        } catch (ReflectiveOperationException | RuntimeException unreadable) {
            report(unreadable);
            WorldItems.unhook();
        }
        Helicopters next;
        try {
            next = new Helicopters(lua, game, loader);
            next.register(table(lua, api, "helicopter"));
        } catch (ReflectiveOperationException | RuntimeException | LinkageError unreadable) {
            report(unreadable);
            lua.set(api, "helicopter", null);
            next = null;
        }
        helicopters = next;
    }

    /**
     * {@code buildings.containers} and {@code containersNear}. Left out, with a line in the game's log, in a game that lacks what they
     * read: the rest of the buildings go on.
     */
    private static void containers(Kahlua lua, Buildings read, Game game, Object table, ClassLoader loader) throws ReflectiveOperationException {
        try { new Containers(lua, game, read, loader).register(table); }
        catch (ReflectiveOperationException | RuntimeException | LinkageError unreadable) {
            report(unreadable);
            lua.set(table, "containers", null);
            lua.set(table, "containersNear", null);
        }
    }

    /**
     * {@code PZExtAPI.timers}, {@code PZExtAPI.chunks}, {@code PZExtAPI.draw} and {@code PZExtAPI.floor}: Lua functions called at a
     * cadence or when a chunk loads, many shapes drawn by one call, and pictures drawn on the floor of squares. Each is left out, with a line in the game's log, in a game that lacks what it
     * reads: the others go on.
     */
    private static void scheduled(Kahlua lua, Object api, Object meta, Object handles, Game game, ClassLoader loader)
            throws ReflectiveOperationException {
        Timers counting;
        try {
            counting = new Timers(lua, game, loader, meta, handle -> owner(lua, handles, handle));
            counting.register(table(lua, api, "timers"));
        } catch (ReflectiveOperationException | RuntimeException | LinkageError unreadable) {
            report(unreadable);
            Timers.retire(lua, meta);
            lua.set(api, "timers", null);
            counting = null;
        }
        timers = counting;
        ChunkWatches watching;
        try {
            watching = new ChunkWatches(lua, game, loader, meta, handle -> owner(lua, handles, handle));
            watching.register(table(lua, api, "chunks"));
        } catch (ReflectiveOperationException | RuntimeException | LinkageError unreadable) {
            report(unreadable);
            ChunkWatches.retire(lua, meta);
            lua.set(api, "chunks", null);
            watching = null;
        }
        chunks = watching;
        try { new Quads(lua, loader).register(table(lua, api, "draw")); }
        catch (ReflectiveOperationException | RuntimeException | LinkageError unreadable) {
            report(unreadable);
            lua.set(api, "draw", null);
        }
        FloorDecals decals;
        try {
            decals = new FloorDecals(lua, game, loader, meta, handle -> owner(lua, handles, handle));
            decals.register(table(lua, api, "floor"));
        } catch (LinkageError olderBootstrap) {
            System.err.println("[PZExt] Floor decals are not in this game; restart it to use them: " + olderBootstrap);
            FloorDecals.retire(lua, meta);
            lua.set(api, "floor", null);
            decals = null;
        } catch (ReflectiveOperationException | RuntimeException unreadable) {
            report(unreadable);
            FloorDecals.unhook();
            FloorDecals.retire(lua, meta);
            lua.set(api, "floor", null);
            decals = null;
        }
        floor = decals;
        SquareWatches watched;
        try {
            watched = new SquareWatches(lua, game, meta, handle -> owner(lua, handles, handle));
            watched.register(table(lua, api, "squares"));
        } catch (LinkageError olderBootstrap) {
            System.err.println("[PZExt] Square watches are not in this game; restart it to use them: " + olderBootstrap);
            SquareWatches.retire(lua, meta);
            lua.set(api, "squares", null);
            watched = null;
        } catch (ReflectiveOperationException | RuntimeException unreadable) {
            report(unreadable);
            SquareWatches.unhook();
            SquareWatches.retire(lua, meta);
            lua.set(api, "squares", null);
            watched = null;
        }
        squares = watched;
    }

    /** The mod a handle belongs to, or null when the value is not one of this environment's handles. */
    private static String owner(Kahlua lua, Object handles, Object handle) throws ReflectiveOperationException {
        Object name = lua.isTable(handle) ? lua.get(handle, "name") : null;
        return name instanceof String text && lua.get(handles, text) == handle ? text : null;
    }

    /** {@code PZExtAPI.client(name)}: one handle per name, which everything the mod defines belongs to. The handles. */
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
            if (current != null) current.clear(name, AREA + "client:clear");
            Formulas declared = formulas;
            if (declared != null) declared.clear(name, AREA + "client:clear");
            Moodles defined = moodles;
            if (defined != null) defined.clear(name, AREA + "client:clear");
            Texts shown = texts;
            if (shown != null) shown.clear(name, AREA + "client:clear");
            ZombieSounds heard = sounds;
            if (heard != null) heard.clear(name, AREA + "client:clear");
            ZombieHits struck = hits;
            if (struck != null) struck.clear(name, AREA + "client:clear");
            ZombieHolds holding = holds;
            if (holding != null) holding.clear(name, AREA + "client:clear");
            Timers counting = timers;
            if (counting != null) counting.clear(name, AREA + "client:clear");
            ChunkWatches watching = chunks;
            if (watching != null) watching.clear(name, AREA + "client:clear");
            SquareWatches watched = squares;
            if (watched != null) watched.clear(name, AREA + "client:clear");
            FloorDecals decals = floor;
            if (decals != null) {
                try { decals.clear(name, AREA + "client:clear"); }
                catch (RuntimeException | Error mine) { throw mine; }
                catch (Throwable failure) { throw Game.thrown(failure); }
            }
            return new Object[0];
        }));
        return handles;
    }

    /** {@link Hooks#hookStatus}; empty from a bootstrap that does not keep it (a game started before it did). */
    private static Map<String, String> hooks() {
        var all = new java.util.TreeMap<String, String>();
        try { all.putAll(Hooks.hookStatus()); }
        catch (LinkageError olderBootstrap) { /* none kept */ }
        // The areas told by hooks instead of looking each frame: applied, or why they look every frame.
        all.putAll(Watches.status());
        return all;
    }

    /**
     * Writes which hooks this game has to the install folder, for whoever installed the API, when that changed. Called by the boot layer's Host
     * about once a second; a hook's state changes as its class loads, most of them with the first world.
     * The file names this process, so that an earlier game's is not read as this one's.
     */
    public static void writeStatus(Path folder) {
        var text = new StringBuilder("PZEXT-API\t1\npid\t").append(ProcessHandle.current().pid()).append('\n');
        for (var hook : hooks().entrySet())
            text.append("hook\t").append(hook.getKey()).append('\t').append(hook.getValue().replaceAll("[\\t\\r\\n]+", " ")).append('\n');
        String next = text.toString();
        if (next.equals(written)) return;
        try {
            Path temporary = folder.resolve(STATUS + ".tmp");
            Files.writeString(temporary, next, StandardCharsets.UTF_8);
            Files.move(temporary, folder.resolve(STATUS), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
            written = next;
        } catch (IOException | RuntimeException unwritable) { } // Tried again on the next pass; no file reads as unknown.
    }

    private static Object table(Kahlua lua, Object owner, String key) throws ReflectiveOperationException {
        Object table = lua.get(owner, key);
        if (!lua.isTable(table)) { table = lua.table(); lua.set(owner, key, table); }
        return table;
    }

    private static void report(Throwable failure) { System.err.println("[PZExt] " + failure); }
}
