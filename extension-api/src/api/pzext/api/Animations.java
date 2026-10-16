package pzext.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodType;
import java.util.Arrays;

/**
 * The animations attached to objects that mods have stepped (see {@code anim.stepKey}). The game draws an object's attached
 * animations ({@code IsoObject.renderAttachedSprites}) and calls each instance's {@code update()}, which does nothing; only a
 * fire steps its own. For an object whose mod data holds a number other than 0 under a declared key, each instance is stepped
 * there by the game's own {@code IsoSprite.update(instance)}, which moves its frame by its speed and the time since the last
 * update, loops it, and leaves it while the game is paused.
 *
 * <p>The chunk renderer draws an ordinary object into the chunk's texture and again only when the chunk changes, so such an
 * object also answers yes to {@code isAnimating()}: the renderer then draws it every frame, as it draws a fire.
 *
 * <p>The render path may draw an object more than once a frame (split screen), so each instance is stepped once a frame: the
 * instances stepped are kept in an identity table that the frame empties. Only the game's thread, which runs the frames, steps;
 * the table grows (the only allocation) to the most instances stepped in a frame.
 *
 * <p>Threads. {@link #stepped} is asked on whatever thread bakes a chunk level (PZ Optimization records the level's objects on worker
 * threads): it only reads, the object's mod data, and keeps and changes nothing here, so it is safe to ask from any thread. The mod
 * data is a Lua table that Lua on the game's thread may write at the same time: a read that races such a write answers with the
 * value from before it or after (never a changed table), a fault in the read is the hook's to report and answer the game's no for,
 * and an object whose answer was missed is drawn into the chunk's texture until the level is baked again, as the game does. {@link
 * #drawn} and {@link #frame} change the identity table and are the game's thread's alone ({@link #drawn} returns at once on any other).
 */
final class Animations {
    // IsoSpriteInstance.getParentSprite(); IsoSprite.update(IsoSpriteInstance); IsoObject.hasAttachedAnimSprites().
    private final MethodHandle parentOf, update, hasAttached;
    // The numbers the objects' mod data holds under the step keys.
    private final ObjectData data;
    // The thread that runs the frames, and the instances it stepped in this frame (open addressing, by identity; a power of 2 long).
    private volatile Thread thread;
    private Object[] stepped = new Object[64];
    private int count;

    Animations(ClassLoader loader, Game game) throws ReflectiveOperationException {
        Class<?> instance = Game.type(loader, "zombie.iso.sprite.IsoSpriteInstance"), sprite = Game.type(loader, "zombie.iso.sprite.IsoSprite");
        parentOf = Game.exact(instance.getMethod("getParentSprite"), MethodType.methodType(Object.class, Object.class));
        update = Game.exact(sprite.getMethod("update", instance), MethodType.methodType(void.class, Object.class, Object.class));
        hasAttached = Game.exact(game.objectType.getMethod("hasAttachedAnimSprites"), MethodType.methodType(boolean.class, Object.class));
        data = new ObjectData(loader, game.objectType);
    }

    /** Whether the object has attached animations that are stepped: the renderer is to draw it every frame. Any thread; reads only. */
    boolean stepped(String[] keys, Object object) throws Throwable {
        return (boolean)hasAttached.invokeExact(object) && data.holds(keys, object);
    }

    /** Each frame, on the game's thread: what was stepped is forgotten. */
    void frame() {
        thread = Thread.currentThread();
        if (count == 0) return;
        Arrays.fill(stepped, null);
        count = 0;
    }

    /** An animation attached to the object was drawn: stepped once this frame when the object holds one of the keys. */
    void drawn(String[] keys, Object instance, Object object) throws Throwable {
        if (Thread.currentThread() != thread || !data.holds(keys, object) || !first(instance)) return;
        Object sprite = (Object)parentOf.invokeExact(instance);
        if (sprite != null) update.invokeExact(sprite, instance);
    }

    /** Whether the instance was not stepped yet in this frame; it is marked. */
    private boolean first(Object instance) {
        int mask = stepped.length - 1;
        for (int at = slot(instance, mask);; at = (at + 1) & mask) {
            Object there = stepped[at];
            if (there == instance) return false;
            if (there != null) continue;
            stepped[at] = instance;
            if (++count * 2 > stepped.length) grow();
            return true;
        }
    }

    private void grow() {
        Object[] old = stepped;
        stepped = new Object[old.length * 2];
        int mask = stepped.length - 1;
        for (Object instance : old) {
            if (instance == null) continue;
            int at = slot(instance, mask);
            while (stepped[at] != null) at = (at + 1) & mask;
            stepped[at] = instance;
        }
    }

    private static int slot(Object instance, int mask) {
        int hash = System.identityHashCode(instance);
        return (hash ^ (hash >>> 16)) & mask;
    }
}
