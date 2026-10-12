package pzext.api;

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
        // What the rest of IsoGameCharacter.TestIfSeen asks, for a zombie whose line is clear: IsoMovingObject.DistToProper(IsoObject) and
        // getCurrentSquare(); IsoGameCharacter.getDetectionRange() and getDotWithForwardDirection(float, float); IsoGridSquare.lighting;
        // IsoGridSquare.ILighting.lightInfo(); ColorInfo.r, g and b.
        static final MethodHandle DISTANCE, SQUARE, RANGE, DOT, LIGHTING, LIGHT, RED, GREEN, BLUE;

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
                Class<?> square = Game.type(LOADER, "zombie.iso.IsoGridSquare"), lighting = Game.type(LOADER, "zombie.iso.IsoGridSquare$ILighting");
                Class<?> color = Game.type(LOADER, "zombie.core.textures.ColorInfo");
                DISTANCE = Game.exact(moving.getMethod("DistToProper", object), MethodType.methodType(float.class, Object.class, Object.class));
                SQUARE = Game.exact(moving.getMethod("getCurrentSquare"), MethodType.methodType(Object.class, Object.class));
                RANGE = Game.exact(character.getMethod("getDetectionRange"), number);
                DOT = Game.exact(character.getMethod("getDotWithForwardDirection", float.class, float.class),
                    MethodType.methodType(float.class, Object.class, float.class, float.class));
                LIGHTING = MethodHandles.publicLookup().unreflectGetter(square.getField("lighting")).asType(MethodType.methodType(Object[].class, Object.class));
                LIGHT = Game.exact(lighting.getMethod("lightInfo"), MethodType.methodType(Object.class, Object.class));
                RED = MethodHandles.publicLookup().unreflectGetter(color.getField("r")).asType(number);
                GREEN = MethodHandles.publicLookup().unreflectGetter(color.getField("g")).asType(number);
                BLUE = MethodHandles.publicLookup().unreflectGetter(color.getField("b")).asType(number);
            } catch (ReflectiveOperationException failure) {
                throw new ExceptionInInitializerError(failure);
            }
        }
    }

    /**
     * What a query with options asks of each zombie besides its place, as handles that are constants like {@link Handles}: made by
     * the first call that has options, so that a game that lacks one of them loses those options alone.
     */
    static final class Filters {
        // IsoGameCharacter.getCurrentState(); IsoZombie.target; IsoZombie.isCrawling().
        static final MethodHandle STATE, TARGET, CRAWLING;

        static {
            try {
                Class<?> character = Game.type(Handles.LOADER, "zombie.characters.IsoGameCharacter");
                Class<?> zombie = Game.type(Handles.LOADER, "zombie.characters.IsoZombie");
                STATE = Game.exact(character.getMethod("getCurrentState"), MethodType.methodType(Object.class, Object.class));
                TARGET = MethodHandles.publicLookup().unreflectGetter(zombie.getField("target")).asType(MethodType.methodType(Object.class, Object.class));
                CRAWLING = Game.exact(zombie.getMethod("isCrawling"), MethodType.methodType(boolean.class, Object.class));
            } catch (ReflectiveOperationException failure) {
                throw new ExceptionInInitializerError(failure);
            }
        }

        private Filters() { }

        /** Makes the handles, or fails with why this game cannot answer a query with options. */
        static void use() {
            try { MethodHandle ignored = STATE; }
            catch (ExceptionInInitializerError | NoClassDefFoundError missing) {
                throw new IllegalStateException("this game cannot answer zombies.near with options: " + missing);
            }
        }
    }
}
