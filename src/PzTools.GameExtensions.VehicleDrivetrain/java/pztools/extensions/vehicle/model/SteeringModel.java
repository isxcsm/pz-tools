package pztools.extensions.vehicle.model;

/**
 * The game's own keyboard steering, generalised from "a whole frame" to "the part of the frame the
 * key was really held". No game dependencies and no state.
 *
 * <p>Per update the game does, with {@code m = GameTime.getMultiplier() / 0.8} and
 * {@code f = max(0.1, 1 - speed / maxSpeed)}:
 * <pre>
 *   held:     steering -= (input + steering) * 0.06 * m * f
 *   released: steering moves toward 0 by 0.04 * m, and snaps to 0 within 0.04
 * </pre>
 * A held fraction of 1 reproduces the first line and 0 the second. Anything between applies each
 * for its share of the frame, composed so that two half frames equal one whole frame.
 */
public final class SteeringModel {
    /** Preserve the game's float boundary when steering input is promoted to double. */
    public static final double INPUT_DEAD_ZONE=0.1f;
    public static final double APPROACH=0.06f, RETURN=0.04f, MINIMUM_SPEED_FACTOR=0.1f;
    /** A press can be confirmed by the game one update late; more carried time than this is not a tap. */
    public static final double MAXIMUM_HELD_FRACTION=4;
    private SteeringModel() { }

    public static boolean accepts(double input,double angle,double multiplier,double speedKph,double maximumSpeedKph,double heldFraction) {
        return Double.isFinite(input) && Math.abs(input)<=1.0001 && Double.isFinite(angle) && Math.abs(angle)<=Math.PI
            && Double.isFinite(multiplier) && multiplier>0 && Double.isFinite(speedKph)
            && Double.isFinite(maximumSpeedKph) && maximumSpeedKph>0
            && Double.isFinite(heldFraction) && heldFraction>=0 && heldFraction<=MAXIMUM_HELD_FRACTION
            // The game's own step overshoots its target beyond this; leave such frames to the game.
            && APPROACH*multiplier*speedFactor(speedKph,maximumSpeedKph)<1;
    }

    /** The game uses the signed speed: reversing steers faster than standing still, as in the original. */
    public static double speedFactor(double speedKph,double maximumSpeedKph) {
        return Math.max(MINIMUM_SPEED_FACTOR,1-speedKph/maximumSpeedKph);
    }

    /**
     * NaN means decline without a game write. {@code input} is the game's steering input (its sign
     * and magnitude are kept), {@code heldFraction} how much of this update the key was down, and
     * {@code heldAtEnd} whether it still is, which decides the order of the two parts.
     */
    public static double step(double input,double angle,double multiplier,double speedKph,double maximumSpeedKph,
            double heldFraction,boolean heldAtEnd) {
        if(!accepts(input,angle,multiplier,speedKph,maximumSpeedKph,heldFraction)) return Double.NaN;
        double held=Math.abs(input)>INPUT_DEAD_ZONE?heldFraction:0, released=Math.max(0,1-held);
        return heldAtEnd?advance(input,angle,multiplier,speedKph,maximumSpeedKph,released,held,0)
            :advance(input,angle,multiplier,speedKph,maximumSpeedKph,0,held,released);
    }

    /** The longest return a single call may carry: one update of its own plus one deferred. */
    public static final double MAXIMUM_RELEASE=2;

    /**
     * The general step: return for {@code releaseBefore} updates, steer for {@code held}, return for
     * {@code releaseAfter}. The caller decides where the unheld time goes; see {@code VehicleControl}
     * for why the time after a release is carried into the next update instead of spent in this one.
     */
    public static double advance(double input,double angle,double multiplier,double speedKph,double maximumSpeedKph,
            double releaseBefore,double held,double releaseAfter) {
        if(!accepts(input,angle,multiplier,speedKph,maximumSpeedKph,held)
                || !(releaseBefore>=0 && releaseBefore<=MAXIMUM_RELEASE) || !(releaseAfter>=0 && releaseAfter<=MAXIMUM_RELEASE))
            return Double.NaN;
        double share=Math.abs(input)>INPUT_DEAD_ZONE?held:0;
        double perUpdate=APPROACH*multiplier*speedFactor(speedKph,maximumSpeedKph);
        return release(approach(release(angle,multiplier,releaseBefore),input,perUpdate,share),multiplier,releaseAfter);
    }

    private static double approach(double angle,double input,double perUpdate,double held) {
        if(held<=0) return angle;
        // One update closes `perUpdate` of the remaining distance; a share of it closes 1-(1-p)^share.
        double closed=held==1?perUpdate:1-Math.pow(1-perUpdate,held);
        return angle-(input+angle)*closed;
    }

    private static double release(double angle,double multiplier,double released) {
        if(released<=0) return angle;
        // The game compares against the double 0.04 but moves by the float 0.04f.
        if(Math.abs(angle)<=0.04*released) return 0;
        double distance=RETURN*multiplier*released;
        return angle>0?Math.max(0,angle-distance):Math.min(0,angle+distance);
    }
}
