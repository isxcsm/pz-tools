package pzext.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.util.*;
import java.util.function.Supplier;
import pzext.boot.Hooks;

/**
 * {@code PZExtAPI.moodles}: moodles a mod defines, which the game's own moodle column draws (docs/design.md,
 * "Moodles"). A definition registers a moodle type in the game's registry ({@code MoodleType.register}), under the handle's
 * name as its namespace, so the game's characters and moodle columns made after it have it as they have their own types; the
 * characters and columns already made get it added. A mod sets the level each local player shows; the hook in
 * {@code Moodle.Update} hands it to the game's own level update, so the column places, tints, wiggles and explains the moodle
 * as it does the game's. The level hook is asked once a tick for every moodle of every player: a type that is not the API's
 * costs one identity-map lookup, an API type a few array reads; neither allocates.
 *
 * <p>The definitions belong to the Lua environment (the registry keeps the types until the game resets it, going back to the
 * main menu); the levels are runtime only, set to 0 when a world is left. Like the formulas they are kept in the API table's
 * metatable for a newer API to take over.
 */
final class Moodles implements Hooks.Moodles {
    private static final String AREA = "PZExtAPI.moodles.";
    private static final String MIRROR = "moodles", FORMAT = "pzext-moodles 1", GENERATION = "moodlesGeneration",
        HANDOVER = "moodlesHandover";
    /** The sizes of the game's moodle pictures (MoodlesUI.textureSizes), which the player's moodle size option picks from. */
    static final int[] SIZES = { 32, 48, 64, 80, 96, 128 };
    /** In a picture's path, the size of the column it is drawn in. */
    static final String SIZE = "{size}";
    /** The hooks the moodles need, as {@code PZExtAPI.hooks()} names them. */
    static final List<String> HOOKS = List.of("Moodle.Update:level", "Moodles.GoodBadNeutral", "Moodles.<init>", "MoodlesUI.render");
    static final int MAX_LEVEL = 4, PLAYERS = 4, MAX_PATH = 256;
    // The flags MoodleTextureSet loads the game's pictures with (mipmapped).
    private static final int TEXTURE_FLAGS = 64;
    private static final Object MISSING = new Object();
    private static final Map<String, Integer> KINDS = Map.of("neutral", 0, "good", 1, "bad", 2);
    private static final String[] KIND_NAMES = { "neutral", "good", "bad" };
    private static final char SEPARATOR = '\u001f';
    // The namespace of the game's own moodle types (ResourceLocation.DEFAULT_NAMESPACE).
    private static final String GAME_NAMESPACE = "base";

    /** One mod's moodle. Changed on the game's thread; the hooks read it there. */
    private static final class Definition {
        final String owner, location;
        String id;
        int kind;
        String[] pictures;
        Object type;
        // By player index: the level each local player shows.
        final int[] levels = new int[PLAYERS];
        // By picture, then size: the texture drawn, MISSING when there is none; null until first drawn.
        Object[] textures;
        boolean reported;
        // False once its mod took it back (handle:clear()): it shows no level, but keeps its type, so that its mod (and only its
        // mod) can define it again, and its picture, which a column not updated since still draws.
        boolean active = true;

        Definition(String owner, String location) { this.owner = owner; this.location = location; }
    }

    private final Kahlua lua;
    private final Game game;
    private final Object meta;
    private final Networks.Owners owners;
    private final Players players;
    // The game's registry of moodle types, its get(ResourceLocation), ResourceLocation.of and MoodleType.register(String).
    private final Object registry;
    private final Method registryGet, location, register, translationName;
    // A character's moodles (Moodles.moodles), a moodle's character, the constructor of a moodle.
    private final Field moodleMap, moodleCharacter;
    private final Constructor<?> newMoodle;
    // IsoGameCharacter.getMoodles(), isDead(); Moodles.getMoodleLevel(type), as (Object...) handles.
    private final MethodHandle moodlesOf, dead, moodleLevel;
    // The moodle columns (UIManager.MoodleUI), a column's moodles and character, and what it keeps of a moodle.
    private final Object[] columns;
    private final Field columnState;
    private final MethodHandle columnCharacter;
    private final Constructor<?> newColumnData;
    // MoodleTextureSet.getSize(), getBorder(); Texture.getSharedTexture(path, flags), the copy, its size and whether it is read.
    private final MethodHandle setSize, setBorder, sharedTexture, textureReady, textureFailed, textureWidth, textureHeight, setWidth, setHeight,
        offsetX, offsetY, setOffsetX, setOffsetY;
    // GameLoadingState.loader: the thread that loads a world (and makes its player) while it runs; null without one. Null when the
    // game has no such field: the registry is then changed whenever a world changes.
    private final Field loadingThread;
    private final Constructor<?> copyTexture;
    // By location (the game's name, lower case): every mod's moodles.
    private final TreeMap<String, Definition> definitions = new TreeMap<>();
    // The definitions the mods looked up, by mod and id as written (see own).
    private final Map<String, Map<String, Definition>> looked = new HashMap<>();
    // What the hooks read: the definitions by their type, rebuilt as one changes.
    private volatile Map<Object, Definition> byType = new IdentityHashMap<>();
    private Object world;
    private final Watches.Seen moves = Watches.WORLD_CELL.user();
    private boolean dirty, reported;
    // A world changed since the definitions were last found in the registry: looked at once no world is loading.
    private boolean unchecked;
    private long generation;

    Moodles(Kahlua lua, Game game, ClassLoader loader, Object meta, Networks.Owners owners) throws ReflectiveOperationException {
        this.lua = lua;
        this.game = game;
        this.meta = meta;
        this.owners = owners;
        players = new Players(loader);
        Class<?> typeClass = Game.type(loader, "zombie.scripting.objects.MoodleType"), registries = Game.type(loader, "zombie.scripting.objects.Registries");
        Class<?> locationClass = Game.type(loader, "zombie.scripting.objects.ResourceLocation");
        registry = registries.getField("MOODLE_TYPE").get(null);
        registryGet = registry.getClass().getMethod("get", locationClass);
        location = locationClass.getMethod("of", String.class);
        register = typeClass.getMethod("register", String.class);
        translationName = typeClass.getMethod("getTranslationName");
        Class<?> character = Game.type(loader, "zombie.characters.IsoGameCharacter"), moodles = Game.type(loader, "zombie.characters.Moodles.Moodles");
        Class<?> moodle = Game.type(loader, "zombie.characters.Moodles.Moodle");
        moodleMap = Game.accessible(moodles.getDeclaredField("moodles"));
        moodleCharacter = Game.accessible(moodle.getDeclaredField("isoGameCharacter"));
        newMoodle = moodle.getConstructor(typeClass, character);
        moodlesOf = Game.exact(character.getMethod("getMoodles"), MethodType.methodType(Object.class, Object.class));
        dead = Game.exact(character.getMethod("isDead"), MethodType.methodType(boolean.class, Object.class));
        moodleLevel = Game.exact(moodles.getMethod("getMoodleLevel", typeClass), MethodType.methodType(int.class, Object.class, Object.class));
        Class<?> column = Game.type(loader, "zombie.ui.MoodlesUI"), set = Game.type(loader, "zombie.ui.MoodleTextureSet");
        columns = (Object[])Game.type(loader, "zombie.ui.UIManager").getField("MoodleUI").get(null);
        columnState = Game.accessible(column.getDeclaredField("moodleUiState"));
        columnCharacter = MethodHandles.lookup().unreflectGetter(Game.accessible(column.getDeclaredField("isoGameCharacter")))
            .asType(MethodType.methodType(Object.class, Object.class));
        newColumnData = Game.type(loader, "zombie.ui.MoodlesUI$MoodleUIData").getConstructor();
        setSize = Game.exact(set.getMethod("getSize"), MethodType.methodType(int.class, Object.class));
        setBorder = Game.exact(set.getMethod("getBorder"), MethodType.methodType(Object.class, Object.class));
        Class<?> texture = Game.type(loader, "zombie.core.textures.Texture");
        sharedTexture = Game.exact(texture.getMethod("getSharedTexture", String.class, int.class), MethodType.methodType(Object.class, String.class, int.class));
        textureReady = Game.exact(texture.getMethod("isReady"), MethodType.methodType(boolean.class, Object.class));
        textureFailed = Game.exact(texture.getMethod("isFailure"), MethodType.methodType(boolean.class, Object.class));
        offsetX = MethodHandles.publicLookup().unreflectGetter(texture.getField("offsetX")).asType(MethodType.methodType(float.class, Object.class));
        offsetY = MethodHandles.publicLookup().unreflectGetter(texture.getField("offsetY")).asType(MethodType.methodType(float.class, Object.class));
        setOffsetX = MethodHandles.publicLookup().unreflectSetter(texture.getField("offsetX")).asType(MethodType.methodType(void.class, Object.class, float.class));
        setOffsetY = MethodHandles.publicLookup().unreflectSetter(texture.getField("offsetY")).asType(MethodType.methodType(void.class, Object.class, float.class));
        textureWidth = Game.exact(texture.getMethod("getWidth"), MethodType.methodType(int.class, Object.class));
        textureHeight = Game.exact(texture.getMethod("getHeight"), MethodType.methodType(int.class, Object.class));
        setWidth = Game.exact(texture.getMethod("setWidth", int.class), MethodType.methodType(void.class, Object.class, int.class));
        setHeight = Game.exact(texture.getMethod("setHeight", int.class), MethodType.methodType(void.class, Object.class, int.class));
        copyTexture = texture.getConstructor(texture);
        Field loading;
        try { loading = Game.type(loader, "zombie.gameStates.GameLoadingState").getField("loader"); }
        catch (ReflectiveOperationException absent) { loading = null; }
        loadingThread = loading;
        // The API this one replaces writes its definitions where this one finds them.
        if (lua.get(meta, HANDOVER) instanceof Supplier<?> earlier) {
            try { earlier.get(); }
            catch (RuntimeException | LinkageError failure) {
                System.err.println("[PZExt] moodles: the earlier API did not hand them over: " + failure);
            }
        }
        load(lua.get(meta, MIRROR));
        dirty = false;
    }

    /** Gives the game's moodle questions to these moodles. Throws a LinkageError in a game whose bootstrap has no moodle hooks. */
    void hook() { Hooks.setMoodles(this); }

    /** Gives every moodle question back to the game alone. */
    static void unhook() {
        try { Hooks.setMoodles(null); } catch (LinkageError olderBootstrap) { }
    }

    /** No moodles run in the environment any more: the functions mods kept refuse to be called; the definitions stay for a later API. */
    static void retire(Kahlua lua, Object meta) {
        try { lua.set(meta, GENERATION, (double)(generation(lua, meta) + 1)); }
        catch (ReflectiveOperationException | RuntimeException unwritable) { }
    }

    private static long generation(Kahlua lua, Object meta) throws ReflectiveOperationException {
        return lua.get(meta, GENERATION) instanceof Double number ? number.longValue() : 0;
    }

    // ---- the Lua surface ----

    @FunctionalInterface private interface Body { Object[] call(String call, Object[] arguments) throws Exception; }

    private void function(Object table, String name, Body body) throws ReflectiveOperationException {
        String call = AREA + name;
        lua.set(table, name, lua.function(call, arguments -> {
            current(call);
            return body.call(call, arguments);
        }));
    }

    /** Refuses a call into moodles that a newer API took over, or that stopped: the mod kept the function. */
    private void current(String call) throws ReflectiveOperationException {
        if (generation == 0 || generation(lua, meta) != generation)
            throw new IllegalArgumentException(call + ": the API was updated since this function was read; read it again from PZExtAPI");
    }

    /** Sets this area's functions into its table, replacing those of an earlier API, whose functions then refuse to be called. */
    void register(Object table) throws ReflectiveOperationException {
        generation = generation(lua, meta) + 1;
        lua.set(meta, GENERATION, (double)generation);
        lua.set(meta, HANDOVER, (Supplier<String>)this::handover);
        // A definition taken over whose type the game lost is registered again.
        registered();
        function(table, "define", (call, arguments) -> {
            String owner = owner(arguments, call);
            String id = Arguments.name(arguments, 1, call, "id");
            Object spec = arguments.length > 2 ? arguments[2] : null;
            if (!lua.isTable(spec)) throw new IllegalArgumentException(call + ": spec must be a table, such as { kind = \"bad\", picture = \"media/ui/MyMoodle_{size}.png\" }");
            Integer kind = null;
            String[] pictures = null;
            for (var entry : lua.entries(spec)) {
                if ("kind".equals(entry.getKey())) {
                    kind = entry.getValue() instanceof String text ? KINDS.get(text) : null;
                    if (kind == null) throw new IllegalArgumentException(call + ": spec.kind must be \"good\", \"bad\" or \"neutral\"");
                } else if ("picture".equals(entry.getKey())) pictures = pictures(entry.getValue(), call);
                else throw new IllegalArgumentException(call + ": spec has no field " + entry.getKey() + "; it takes kind and picture");
            }
            if (kind == null) throw new IllegalArgumentException(call + ": spec.kind must be \"good\", \"bad\" or \"neutral\"");
            if (pictures == null) throw new IllegalArgumentException(call + ": spec.picture must be a path, or a list of 1 to 4 paths (one a level)");
            Definition definition = define(owner, id, kind, pictures, call);
            return new Object[] { definition.type, translationName.invoke(definition.type) };
        });
        function(table, "set", (call, arguments) -> {
            Definition definition = own(arguments, call);
            int level = Arguments.integer(arguments, 2, call, "level", 0, MAX_LEVEL);
            if (arguments.length > 3 && arguments[3] != null) {
                int index = Arguments.integer(arguments, 3, call, "playerIndex", 0, PLAYERS - 1);
                if (definition.levels[index] != level) { definition.levels[index] = level; dirty = true; }
            } else for (int index = 0; index < PLAYERS; index++)
                if (definition.levels[index] != level) { definition.levels[index] = level; dirty = true; }
            return new Object[0];
        });
        function(table, "level", (call, arguments) -> {
            Definition definition = own(arguments, call);
            int index = arguments.length > 2 && arguments[2] != null ? Arguments.integer(arguments, 2, call, "playerIndex", 0, PLAYERS - 1) : 0;
            return new Object[] { (double)definition.levels[index] };
        });
    }

    private String owner(Object[] arguments, String call) throws ReflectiveOperationException {
        String owner = owners.of(arguments.length > 0 ? arguments[0] : null);
        if (owner == null) throw new IllegalArgumentException(call + ": the first argument must be a handle from PZExtAPI.client");
        return owner;
    }

    /** The mod's own moodle the call names (its handle, then the id). */
    private Definition own(Object[] arguments, String call) throws ReflectiveOperationException {
        String owner = owner(arguments, call);
        // A moodle looked up before (by the mod and the id as written): its name is not checked or made again. A definition is never
        // replaced or taken away, only cleared, which is looked at each time.
        Map<String, Definition> mine = looked.get(owner);
        if (mine != null && arguments.length > 1 && arguments[1] instanceof String written) {
            Definition known = mine.get(written);
            if (known != null && known.active) return known;
        }
        String id = Arguments.name(arguments, 1, call, "id");
        Definition definition = definitions.get(locationOf(owner, id));
        if (definition == null || !definition.owner.equals(owner) || !definition.active)
            throw new IllegalArgumentException(call + ": the mod has no moodle " + id + "; define it first");
        looked.computeIfAbsent(owner, key -> new HashMap<>()).put(id, definition);
        return definition;
    }

    private static String locationOf(String owner, String id) { return (owner + ":" + id).toLowerCase(Locale.ENGLISH); }

    /** A picture's path, or a list of 1 to 4 (one a level, the last for the levels above). */
    private String[] pictures(Object value, String call) throws ReflectiveOperationException {
        var result = new ArrayList<String>();
        if (value instanceof String text) result.add(text);
        else if (lua.isTable(value)) {
            for (int index = 1;; index++) {
                Object item = lua.get(value, (double)index);
                if (item == null) break;
                if (!(item instanceof String text)) throw new IllegalArgumentException(call + ": spec.picture[" + index + "] must be a path");
                result.add(text);
            }
        }
        if (result.isEmpty() || result.size() > MAX_LEVEL)
            throw new IllegalArgumentException(call + ": spec.picture must be a path, or a list of 1 to 4 paths (one a level)");
        for (String path : result)
            if (path.isEmpty() || path.length() > MAX_PATH || path.chars().anyMatch(Character::isISOControl))
                throw new IllegalArgumentException(call + ": spec.picture must be paths of 1 to " + MAX_PATH + " characters without control characters");
        return result.toArray(String[]::new);
    }

    /**
     * Defines the mod's moodle, or changes its kind and pictures: the type is registered once, and found again in the registry
     * by its name (defined again, or by a newer API).
     */
    private Definition define(String owner, String id, int kind, String[] pictures, String call) throws ReflectiveOperationException {
        // The game's own moodles are in the namespace base: a handle of that name would name one of them.
        if (owner.toLowerCase(Locale.ENGLISH).equals(GAME_NAMESPACE))
            throw new IllegalArgumentException(call + ": a handle named " + owner + " cannot define moodles: the game's own are named base:...");
        String name = locationOf(owner, id);
        Definition definition = definitions.get(name);
        if (definition != null && !definition.owner.equals(owner))
            throw new IllegalArgumentException(call + ": the moodle " + name + " is the mod " + definition.owner + "'s (the game's names of moodles are not case sensitive)");
        Object type = registeredType(name);
        // A type of that name the API did not register (another mod's, through MoodleType.register) is not taken over.
        if (type != null && (definition == null || definition.type != type))
            throw new IllegalArgumentException(call + ": the game already has a moodle " + name + " that this API did not define");
        if (type == null) {
            // The id as first defined is the type's translation name (the keys of the mod's text), also when registered again.
            String first = definition == null ? id : definition.id;
            try { type = register.invoke(null, owner + ":" + first); }
            catch (InvocationTargetException refused) {
                throw new IllegalArgumentException(call + ": the game refused the moodle " + owner + ":" + first + ": " + refused.getCause().getMessage());
            }
        }
        if (definition == null) { definition = new Definition(owner, name); definition.id = id; definitions.put(name, definition); }
        definition.active = true;
        definition.kind = kind;
        if (!Arrays.equals(definition.pictures, pictures)) {
            definition.pictures = pictures;
            definition.textures = new Object[pictures.length * SIZES.length];
            definition.reported = false;
        }
        definition.type = type;
        publish();
        add(type);
        dirty = true;
        return definition;
    }

    /** The type the game's registry has under the name, or null. */
    private Object registeredType(String name) throws ReflectiveOperationException {
        return registryGet.invoke(registry, location.invoke(null, name));
    }

    /** {@code handle:clear()}: removes the mod's moodles. Their types stay in the game's registry, at level 0, until it is reset. */
    void clear(String owner, String call) throws ReflectiveOperationException {
        current(call);
        for (Definition definition : definitions.values()) if (definition.owner.equals(owner) && definition.active) {
            definition.active = false;
            Arrays.fill(definition.levels, 0);
            dirty = true;
        }
    }

    private void publish() {
        var next = new IdentityHashMap<Object, Definition>();
        for (Definition definition : definitions.values()) if (definition.type != null) next.put(definition.type, definition);
        byType = next;
    }

    /**
     * Adds the type to every character's moodles and every moodle column that was made without it (made before it was
     * registered): the game asks them about every registered type, as mods iterating the registry do, and a type a character's
     * moodles do not have fails there. Characters and columns made later have it from the registry.
     */
    private void add(Object type) throws ReflectiveOperationException {
        var seen = Collections.newSetFromMap(new IdentityHashMap<Object, Boolean>());
        for (Object moodles : Hooks.madeMoodles()) add(moodles, type, seen);
        // Without the hook that sees them made, the local players' are the ones the API knows.
        for (Object player : players.all()) if (player != null) {
            try { add((Object)moodlesOf.invokeExact(player), type, seen); }
            catch (Throwable failure) { throw Game.thrown(failure); }
        }
        for (Object column : columns) if (column != null) {
            @SuppressWarnings("unchecked")
            var state = (Map<Object, Object>)columnState.get(column);
            if (!state.containsKey(type)) state.put(type, newColumnData.newInstance());
        }
    }

    private void add(Object moodles, Object type, Set<Object> seen) throws ReflectiveOperationException {
        if (moodles == null || !seen.add(moodles)) return;
        @SuppressWarnings("unchecked")
        var map = (Map<Object, Object>)moodleMap.get(moodles);
        if (map.containsKey(type)) return;
        // A character's moodles do not know their character; each moodle does.
        Object character = null;
        for (Object moodle : map.values()) if ((character = moodleCharacter.get(moodle)) != null) break;
        if (character != null) map.put(type, newMoodle.newInstance(type, character));
    }

    /** Each frame, on the game's thread. */
    void frame() {
        try {
            Object cell;
            if (moves.moved() && (cell = game.cell()) != world) {
                // A world was left: its levels go; the mods set them again in the next.
                if (world != null) for (Definition definition : definitions.values())
                    if (Arrays.stream(definition.levels).anyMatch(level -> level != 0)) { Arrays.fill(definition.levels, 0); dirty = true; }
                world = cell;
                unchecked = true;
            }
            // The game resets its registries as it leaves a world: a definition kept since is registered again, but not while a
            // world loads: its thread makes the player's moodles from the registry meanwhile.
            if (unchecked && (loadingThread == null || loadingThread.get(null) == null)) {
                unchecked = false;
                registered();
            }
            if (dirty) write();
        } catch (Throwable failure) {
            // Once: a fault that recurs each frame must not flood the game's log. The hooks keep answering.
            if (!reported) System.err.println("[PZExt] moodles: " + failure);
            reported = true;
        }
    }

    /** Registers again each definition whose type the game's registry no longer has, and adds it where it is missing. */
    private void registered() throws ReflectiveOperationException {
        boolean changed = false;
        for (Definition definition : definitions.values()) {
            if (!definition.active) continue;
            Object now = registeredType(definition.location);
            if (now == definition.type && now != null) continue;
            if (now != null) {
                // Registered meanwhile by someone else: not the API's to answer for.
                System.err.println("[PZExt] moodles: the game has another moodle " + definition.location + " now; the mod's is not shown");
                definition.active = false;
                definition.type = null;
                changed = true;
                continue;
            }
            try { now = register.invoke(null, definition.owner + ":" + definition.id); }
            catch (InvocationTargetException refused) {
                System.err.println("[PZExt] moodles: the game refused " + definition.location + " again: " + refused.getCause());
                continue;
            }
            definition.type = now;
            changed = true;
        }
        if (!changed) return;
        publish();
        for (Definition definition : definitions.values()) if (definition.active && definition.type != null) add(definition.type);
    }

    // ---- kept for a newer API ----

    /** Writes the definitions and levels into the metatable, where a newer API reads them. */
    private void write() throws ReflectiveOperationException {
        var text = new StringBuilder(FORMAT);
        for (Definition definition : definitions.values()) {
            text.append("\nM\t").append(definition.owner).append('\t').append(definition.id).append('\t').append(KIND_NAMES[definition.kind]).append('\t');
            for (int index = 0; index < PLAYERS; index++) text.append(index == 0 ? "" : ",").append(definition.levels[index]);
            text.append('\t').append(String.join(String.valueOf(SEPARATOR), definition.pictures));
            if (!definition.active) text.append("\tcleared");
        }
        lua.set(meta, MIRROR, text.toString());
        dirty = false;
    }

    private String handover() {
        try {
            write();
            return (String)lua.get(meta, MIRROR);
        } catch (ReflectiveOperationException failure) { throw Game.failed(failure); }
    }

    /** The definitions an earlier API kept, if any; their types are found in the registry by name. */
    private void load(Object kept) throws ReflectiveOperationException {
        if (!(kept instanceof String text)) return;
        String[] lines = text.split("\n");
        if (!FORMAT.equals(lines[0])) {
            System.err.println("[PZExt] moodles: the definitions kept are in another format; the mods define them again");
            return;
        }
        for (int index = 1; index < lines.length; index++) {
            String[] fields = lines[index].split("\t", 7);
            if (fields.length < 6 || !"M".equals(fields[0])) throw new IllegalStateException("Unknown line in the kept moodles: " + lines[index]);
            var definition = new Definition(fields[1], locationOf(fields[1], fields[2]));
            definition.id = fields[2];
            definition.kind = KINDS.get(fields[3]);
            String[] levels = fields[4].split(",");
            for (int player = 0; player < PLAYERS && player < levels.length; player++) definition.levels[player] = Integer.parseInt(levels[player]);
            definition.pictures = fields[5].split(String.valueOf(SEPARATOR), -1);
            definition.textures = new Object[definition.pictures.length * SIZES.length];
            definition.active = fields.length < 7 || !"cleared".equals(fields[6]);
            // The API kept it, so the type of its name is the one an earlier API registered; its translation name gives the id's case.
            definition.type = registeredType(definition.location);
            if (definition.type != null) {
                String translation = (String)translationName.invoke(definition.type);
                definition.id = translation.substring(translation.indexOf(':') + 1);
            }
            definitions.put(definition.location, definition);
        }
        publish();
    }

    // ---- the hooks ----

    @Override public int level(Object type, Object character) {
        Definition definition = byType.get(type);
        // Not the API's, or taken back: the game's update (level 0 for a type it does not know).
        if (definition == null || !definition.active) return -1;
        Object[] local = players.all();
        for (int index = 0; index < local.length && index < PLAYERS; index++) {
            if (local[index] != character || character == null) continue;
            int level = definition.levels[index];
            // Without its picture the game's column could not draw it; a dead player shows none, as the game's update says.
            if (level == 0 || !Hooks.moodlePicturesHooked()) return 0;
            try { return (boolean)dead.invokeExact(character) ? 0 : level; }
            catch (Throwable failure) { throw Moodles.<RuntimeException>sneaky(failure); }
        }
        return 0;
    }

    @Override public int kind(int vanilla, Object type) {
        Definition definition = byType.get(type);
        return definition == null ? vanilla : definition.kind;
    }

    @Override public Object picture(Object set, Object type, Object column) {
        Definition definition = byType.get(type);
        if (definition == null) return null;
        try {
            int size = (int)setSize.invokeExact(set), level = 1;
            Object character = (Object)columnCharacter.invokeExact(column);
            if (character != null) level = (int)moodleLevel.invokeExact((Object)moodlesOf.invokeExact(character), type);
            int picture = Math.min(Math.max(level, 1), definition.pictures.length) - 1;
            Object texture = texture(definition, picture, size);
            return texture != null ? texture : (Object)setBorder.invokeExact(set);
        } catch (Throwable failure) { throw Moodles.<RuntimeException>sneaky(failure); }
    }

    /**
     * The picture of the definition for a column of the size: the file for that size when the path has {@code {size}}, or else
     * the largest given (or the one path) scaled to the size, as a copy of the game's texture with that width and height (the
     * column draws a picture at its own size). Kept once worked out; null when there is no such file.
     */
    private Object texture(Definition definition, int picture, int size) throws Throwable {
        int slot = Arrays.binarySearch(SIZES, size);
        int key = picture * SIZES.length + slot;
        Object kept = slot < 0 ? null : definition.textures[key];
        if (kept != null) return kept == MISSING ? null : kept;
        String path = definition.pictures[picture];
        Object found = null;
        if (path.contains(SIZE)) {
            found = shared(path.replace(SIZE, Integer.toString(size)));
            if (found != null) return keep(definition, key, slot, found);
            for (int index = SIZES.length - 1; index >= 0 && found == null; index--) found = shared(path.replace(SIZE, Integer.toString(SIZES[index])));
        } else found = shared(path);
        if (found == null) {
            if (!definition.reported) System.err.println("[PZExt] moodles: " + definition.location + " has no picture " + path + "; it is drawn empty");
            definition.reported = true;
            keep(definition, key, slot, MISSING);
            return null;
        }
        // A file the game could not read never becomes ready: drawn as the empty frame, and not looked for again.
        if ((boolean)textureFailed.invokeExact(found)) {
            if (!definition.reported) System.err.println("[PZExt] moodles: " + definition.location + " has a picture the game could not read: " + path);
            definition.reported = true;
            keep(definition, key, slot, MISSING);
            return null;
        }
        // Until the game has read it, its size is not known: drawn as it is, and worked out again next time.
        if (!(boolean)textureReady.invokeExact(found)) return found;
        int width = (int)textureWidth.invokeExact(found), height = (int)textureHeight.invokeExact(found);
        if (width == size && height == size || width <= 0 || height <= 0) return keep(definition, key, slot, found);
        double scale = (double)size / Math.max(width, height);
        int drawnWidth = (int)Math.round(width * scale), drawnHeight = (int)Math.round(height * scale);
        Object scaled = copyTexture.newInstance(found);
        setWidth.invokeExact(scaled, drawnWidth);
        setHeight.invokeExact(scaled, drawnHeight);
        // The column draws a picture from the slot's top left (plus the texture's offset): one that is not square is centred.
        setOffsetX.invokeExact(scaled, (float)((float)offsetX.invokeExact(found) * scale + (size - drawnWidth) / 2.0));
        setOffsetY.invokeExact(scaled, (float)((float)offsetY.invokeExact(found) * scale + (size - drawnHeight) / 2.0));
        return keep(definition, key, slot, scaled);
    }

    private static Object keep(Definition definition, int key, int slot, Object texture) {
        if (slot >= 0) definition.textures[key] = texture;
        return texture == MISSING ? null : texture;
    }

    private Object shared(String path) throws Throwable { return (Object)sharedTexture.invokeExact(path, TEXTURE_FLAGS); }

    @SuppressWarnings("unchecked")
    private static <T extends Throwable> T sneaky(Throwable failure) throws T { throw (T)failure; }
}
