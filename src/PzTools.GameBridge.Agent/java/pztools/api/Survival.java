package pztools.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodType;
import java.lang.reflect.Method;
import java.util.List;
import java.util.concurrent.ConcurrentLinkedQueue;

/**
 * What the walking, falling and biting formulas read of the game: the states a player moves in, the speed a fall is
 * lethal at, and a body part's infection flags. Built once; the questions below allocate nothing (a bite, which is rare,
 * reflects).
 */
final class Survival {
    /** The Lua event raised, on a later frame, after a bite the shield took the infection out of. */
    static final String EVENT = "OnPZToolsBiteSurvived";

    // IsoGameCharacter.isCurrentState(State) as (Object, Object)boolean, and the states that move the player: walking and strafing.
    private final MethodHandle isState;
    private final Object movement, strafe;
    // FallingConstants: the acceleration the speed of a fall comes from (speed squared = 2 x acceleration x height), and the
    // speed from which a fall is lethal.
    private final double gravity;
    private final float lethal;
    // BodyDamage.getParentChar(), getBodyParts(); BodyPart.IsInfected(), IsFakeInfected(), SetInfected(boolean), SetFakeInfected(boolean).
    private final Method parentOf, partsOf, infected, fake, setInfected, setFake;
    private final Players players;
    // The shield: whether a mod declares it, and whether it is still to be used (it is taken once for each time it is declared).
    private boolean declared;
    private volatile boolean armed;
    // The part a bite is being put on while the game's call runs, and what its flags were before.
    private Object part;
    private boolean wasInfected, wasFake;
    // The parts a bite was survived on, not yet told to Lua.
    private final ConcurrentLinkedQueue<Integer> survived = new ConcurrentLinkedQueue<>();

    Survival(ClassLoader loader, Players players) throws ReflectiveOperationException, IllegalAccessException {
        this.players = players;
        Class<?> character = Game.type(loader, "zombie.characters.IsoGameCharacter"), state = Game.type(loader, "zombie.ai.State");
        isState = Game.exact(character.getMethod("isCurrentState", state), MethodType.methodType(boolean.class, Object.class, Object.class));
        movement = Game.type(loader, "zombie.ai.states.player.PlayerMovementState").getMethod("instance").invoke(null);
        strafe = Game.type(loader, "zombie.ai.states.PlayerStrafeState").getMethod("instance").invoke(null);
        Class<?> constants = Game.type(loader, "zombie.characters.FallingConstants");
        gravity = constants.getField("IsoFallAcceleration").getFloat(null);
        lethal = constants.getField("lethalFallThreshold").getFloat(null);
        Class<?> body = Game.type(loader, "zombie.characters.BodyDamage.BodyDamage"), partType = Game.type(loader, "zombie.characters.BodyDamage.BodyPart");
        parentOf = body.getMethod("getParentChar");
        partsOf = body.getMethod("getBodyParts");
        infected = partType.getMethod("IsInfected");
        fake = partType.getMethod("IsFakeInfected");
        setInfected = partType.getMethod("SetInfected", boolean.class);
        setFake = partType.getMethod("SetFakeInfected", boolean.class);
    }

    /** Whether the character is moving as the player does when walking, running or strafing (and so crouching and aiming too). */
    boolean moving(Object character) throws Throwable {
        return (boolean)isState.invokeExact(character, movement) || (boolean)isState.invokeExact(character, strafe);
    }

    /**
     * The speed a landing is worked out from when {@code floors} of the fall are forgiven: the height the speed comes from
     * is that many floors lower, and none at all when it is not as high as that. A fall from the height that is lethal,
     * or higher, is left as it is, so that the shift never turns a lethal fall into a survivable one.
     */
    float landing(float speed, float floors) {
        if (!(speed > 0f) || speed >= lethal) return speed;
        double squared = (double)speed * speed - 2.0 * gravity * floors;
        return squared <= 0.0 ? 0f : (float)Math.sqrt(squared);
    }

    // ---- the bite shield ----

    /** The combined declaration of the shield changed: it is armed once for each time it becomes declared. */
    void declare(boolean on) {
        if (!on) { declared = false; armed = false; }
        else if (!declared) { declared = true; armed = true; }
    }

    /**
     * A bite is put on the part ({@code after} false: just before the game's call, true: just after). When the shield is armed
     * and the body is a local player's, the infection flags the bite set are taken off, the shield is used up and the
     * part is queued for the Lua event.
     */
    void bite(Object bodyDamage, int index, boolean after) throws ReflectiveOperationException {
        if (!after) {
            part = null;
            if (!armed || !players.local(parentOf.invoke(bodyDamage))) return;
            part = ((List<?>)partsOf.invoke(bodyDamage)).get(index);
            wasInfected = (boolean)infected.invoke(part);
            wasFake = (boolean)fake.invoke(part);
            return;
        }
        Object bitten = part;
        part = null;
        if (bitten == null) return;
        // What the bite set, and what the part had before it, stays.
        if (!wasInfected && (boolean)infected.invoke(bitten)) setInfected.invoke(bitten, false);
        if (!wasFake && (boolean)fake.invoke(bitten)) setFake.invoke(bitten, false);
        armed = false;
        survived.add(index);
    }

    /** The next part a bite was survived on, or null. */
    Integer nextSurvived() { return survived.poll(); }
}
