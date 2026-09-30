package pztools.extensions.runtime;

/**
 * Optional capability of an active continuous provider: one call per game-loop iteration, on the
 * game thread, for work that must go on whether or not any game hook fires (a hook inside vehicle
 * physics stops being called when the vehicle sleeps or the driver leaves).
 *
 * <p>Called only between a successful activation and revocation. The call must be cheap when the
 * provider has nothing to do, and must contain its own faults: an exception here retires the
 * whole provider.
 */
public interface FrameListener {
    void gameFrame();
}
