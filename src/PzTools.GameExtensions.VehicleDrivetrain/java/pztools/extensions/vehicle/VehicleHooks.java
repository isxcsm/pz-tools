package pztools.extensions.vehicle;

import java.util.Objects;
import pztools.extensions.api.ControlPoints;
import pztools.extensions.api.Lease;

/**
 * The vehicle's control point in the patched {@code CarController.update()} (see {@link VehicleBytecode}):
 * the modes the game resolved, the outcomes the patch acts on, and the check that a callback returned one
 * of them. An exception or an outcome the patch does not know faults the point; the game's code runs.
 */
final class VehicleHooks {
    /** The point's name. The host reports a fault in it as {@code vehicle-callback-failed}. */
    static final String POINT = "vehicle";
    /** Outcome bits. 0 runs the game's code. */
    static final int VANILLA = 0, APPLIED = 1, DIRECTION_HOLD = 2, OWN_OFFROAD = 4;
    /** The mode the game resolved before the control branch. */
    static final int FORWARD = 1, REVERSE = 2, BRAKING = 3, NO_CONTROL = 4;
    /** Before the steering block: a second call per update, separate from the mode dispatch. */
    static final int STEERING = 5;

    @FunctionalInterface interface Controller {
        /** Exceptions and VANILLA are permitted only before committing any game field. */
        int tryControl(Object controller, int mode, float speed) throws Exception;
        /** Observation only: final arguments immediately before the native call; never write game fields. */
        default void observeNative(Object controller, float engine, float brake, float steering) { }
    }
    private VehicleHooks() { }

    /** The owner is the provider, so the host can tell which module a fault belongs to. */
    static void register(Object owner, Controller controller) {
        Objects.requireNonNull(controller);
        ControlPoints.register(POINT, owner, new ControlPoints.Handler() {
            @Override public int call(Object target, int mode, float speed) throws Exception {
                int outcome = controller.tryControl(target, mode, speed);
                // VehicleControl picks its outcome from these constants before it writes a field; this catches a
                // programming error, which then faults the module instead of reaching the patched code.
                if (outcome != VANILLA && outcome != APPLIED && outcome != DIRECTION_HOLD && outcome != (APPLIED | OWN_OFFROAD))
                    throw new IllegalStateException("Invalid vehicle outcome");
                return outcome;
            }
            @Override public void observe(Object target, float engine, float brake, float steering) {
                controller.observeNative(target, engine, brake, steering);
            }
        });
    }
    static Lease unregister(Object owner) { return ControlPoints.unregister(POINT, owner); }
    static Throwable failure(Object owner) { return ControlPoints.failure(POINT, owner); }
}
