package pzext.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.lang.reflect.AccessibleObject;
import java.lang.reflect.Field;
import java.lang.reflect.Method;

/**
 * The game's methods and fields that the hooks' paths and the grids' frames read many times a second, as method handles
 * that are constants of the compiled code: called exactly ({@code invokeExact}), the compiler inlines them, and a call
 * takes no argument array and boxes nothing. A {@link Method#invoke} or {@link Field#get} does both. The API is built
 * without the game, so they are made once from the game's classes (the loader of the first {@link Game}): all the game's
 * classes of one process are one loader's. The squares, chunks and objects are here; the generators and the power
 * questions are {@link PowerReach}'s, which only the power networks need.
 */
final class Reach {
    /** The game's class loader the handles are made from, set (by the first Game) before this class is first used. */
    static final class Seed {
        private static ClassLoader loader;

        private Seed() { }

        static synchronized void set(ClassLoader value) { if (loader == null) loader = value; }

        static synchronized ClassLoader get() { return loader; }
    }

    private static final ClassLoader LOADER = Seed.get();
    private static final MethodType OBJECT_OF_OBJECT = MethodType.methodType(Object.class, Object.class);

    // IsoObject.getSquare and the position of an IsoGridSquare.
    static final MethodHandle SQUARE_OF, SQUARE_X, SQUARE_Y, SQUARE_Z;
    // IsoCell.getGridSquare(x, y, z), getChunk(wx, wy) and IsoChunk.loaded.
    static final MethodHandle GRID_SQUARE, CHUNK_AT, CHUNK_LOADED;
    // IsoObject.getSprite.
    static final MethodHandle SPRITE_OF;
    // GameClient.client: whether this game is a multiplayer client.
    static final MethodHandle CLIENT;

    static {
        try {
            var lookup = MethodHandles.lookup();
            Class<?> object = type("zombie.iso.IsoObject"), square = type("zombie.iso.IsoGridSquare");
            Class<?> cell = type("zombie.iso.IsoCell"), chunk = type("zombie.iso.IsoChunk");
            SQUARE_OF = handle(lookup, object.getMethod("getSquare"), OBJECT_OF_OBJECT);
            SQUARE_X = field(lookup, square.getField("x"), MethodType.methodType(int.class, Object.class));
            SQUARE_Y = field(lookup, square.getField("y"), MethodType.methodType(int.class, Object.class));
            SQUARE_Z = field(lookup, square.getField("z"), MethodType.methodType(int.class, Object.class));
            GRID_SQUARE = handle(lookup, cell.getMethod("getGridSquare", int.class, int.class, int.class),
                MethodType.methodType(Object.class, Object.class, int.class, int.class, int.class));
            CHUNK_AT = handle(lookup, cell.getMethod("getChunk", int.class, int.class),
                MethodType.methodType(Object.class, Object.class, int.class, int.class));
            CHUNK_LOADED = field(lookup, chunk.getField("loaded"), MethodType.methodType(boolean.class, Object.class));
            SPRITE_OF = handle(lookup, object.getMethod("getSprite"), OBJECT_OF_OBJECT);
            CLIENT = lookup.unreflectGetter(type("zombie.network.GameClient").getField("client"))
                .asType(MethodType.methodType(boolean.class));
        } catch (ReflectiveOperationException failure) {
            throw new ExceptionInInitializerError(failure);
        }
    }

    private Reach() { }

    static boolean client() throws ReflectiveOperationException {
        try { return (boolean)CLIENT.invokeExact(); }
        catch (Throwable failure) { throw Game.thrown(failure); }
    }

    /**
     * Makes the handles from the game's classes, once (the first time this class is used, which must come after {@link
     * Seed#set}, for the class is initialised by the first call of any of its members, this included): a game
     * this cannot read gets a ReflectiveOperationException (as the grids' own lookups give) rather than an error from the
     * class's initializer.
     */
    static void verify(ClassLoader loader) throws ReflectiveOperationException {
        try {
            if (LOADER != loader) throw new ReflectiveOperationException("the game's methods cannot be called: another game's classes are already in use");
        } catch (ExceptionInInitializerError | NoClassDefFoundError unreadable) {
            throw new ReflectiveOperationException("the game's methods cannot be called: " + unreadable,
                unreadable.getCause() != null ? unreadable.getCause() : unreadable);
        }
    }

    static Class<?> type(String name) throws ClassNotFoundException { return Class.forName(name, false, LOADER); }

    static <T extends AccessibleObject> T open(T member) { member.setAccessible(true); return member; }

    /** A method of the game (public, or opened) as a handle of the given type: its receiver and references as Object. */
    static MethodHandle handle(MethodHandles.Lookup lookup, Method method, MethodType type) throws IllegalAccessException {
        return lookup.unreflect(method).asType(type);
    }

    static MethodHandle field(MethodHandles.Lookup lookup, Field field, MethodType type) throws IllegalAccessException {
        return lookup.unreflectGetter(field).asType(type);
    }
}
