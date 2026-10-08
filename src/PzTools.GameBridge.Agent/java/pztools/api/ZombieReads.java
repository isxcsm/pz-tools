package pztools.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.util.ArrayList;

/**
 * What the passes over the cell's zombies ask of each one, as handles that are constants: a call through one is built into
 * the loop (the same call through a handle in a field is not, and costs several times as much). They are made once for the
 * game's loader, by the first pass that asks; a pass made for another loader does not work, which does not happen in a game.
 */
final class ZombieReads {
    // The loader the handles are made for: set before they are first used.
    private static ClassLoader loading;

    private ZombieReads() { }

    /** Makes the handles for the loader, or checks that they were made for it. */
    static void use(ClassLoader loader) {
        synchronized (ZombieReads.class) { if (loading == null) loading = loader; }
        if (Handles.LOADER != loader) throw new IllegalStateException("the zombie reads were built for another game loader");
    }

    static final class Handles {
        static final ClassLoader LOADER = loading;
        // IsoCell.getZombieList(); IsoMovingObject.getX(), getY(), getZ(); IsoGameCharacter.isVisibleToPlayer and isDead();
        // IsoObject.setTargetAlpha(int, float).
        static final MethodHandle LIST, X, Y, Z, VISIBLE, DEAD, ALPHA;

        static {
            try {
                Class<?> moving = Game.type(LOADER, "zombie.iso.IsoMovingObject"), object = Game.type(LOADER, "zombie.iso.IsoObject");
                Class<?> character = Game.type(LOADER, "zombie.characters.IsoGameCharacter");
                LIST = Game.exact(Game.type(LOADER, "zombie.iso.IsoCell").getMethod("getZombieList"), MethodType.methodType(ArrayList.class, Object.class));
                var number = MethodType.methodType(float.class, Object.class);
                X = Game.exact(moving.getMethod("getX"), number);
                Y = Game.exact(moving.getMethod("getY"), number);
                Z = Game.exact(moving.getMethod("getZ"), number);
                VISIBLE = MethodHandles.publicLookup().unreflectGetter(character.getField("isVisibleToPlayer"))
                    .asType(MethodType.methodType(boolean[].class, Object.class));
                DEAD = Game.exact(character.getMethod("isDead"), MethodType.methodType(boolean.class, Object.class));
                ALPHA = Game.exact(object.getMethod("setTargetAlpha", int.class, float.class),
                    MethodType.methodType(void.class, Object.class, int.class, float.class));
            } catch (ReflectiveOperationException failure) {
                throw new ExceptionInInitializerError(failure);
            }
        }
    }
}
