package pztools.extensions.vehicle.model;

/**
 * Game-independent, allocation-free step. One instance belongs to one local controller and epoch.
 * Force is in game input units. There is no mass, cargo, tire, collision, or extra braking model here.
 */
public final class DrivetrainModel {
    public enum Decision { VANILLA, APPLIED, DIRECTION_HOLD }

    public static final class Input {
        public double dtSeconds;
        public double speedMps;
        public double enginePower;
        public double engineRpm;
        public double throttle;
        public double offroadEfficiency = 1.0;
        public int direction = 1;
        public int currentGear = 1;
        public boolean lowMode;
        public boolean offroad;
        public boolean towing;
        public boolean sundayDriver;
        public boolean speedDemon;
        public VehicleProfile profile;
    }

    public static final class Output {
        public Decision decision = Decision.VANILLA;
        public double engineForce;
        public double engineRpm;
        public double throttle;
        public int gear;
        public boolean ownOffroad;

        public void clear() {
            decision = Decision.VANILLA;
            engineForce = engineRpm = throttle = 0.0;
            gear = 0;
            ownOffroad = false;
        }
    }

    private static final double NOMINAL_GAME_FORCE = 0.65;
    private final DrivetrainConfig config;
    private VehicleProfile profile;
    private boolean initialized;
    private int direction;
    private int holdTarget;
    private int gear = 1;
    private double holdSeconds;
    private double shiftSeconds;
    private double rpm;
    private double throttle;
    private double deliveredMagnitude;

    public DrivetrainModel(DrivetrainConfig config) {
        if (config == null) throw new IllegalArgumentException("Configuration is required");
        this.config = config;
    }

    /** Required on every vanilla/unsupported interval, vehicle change, and provider retirement. */
    public void reset() {
        profile = null;
        initialized = false;
        direction = holdTarget = 0;
        gear = 1;
        holdSeconds = shiftSeconds = rpm = throttle = deliveredMagnitude = 0.0;
    }

    public void step(Input in, Output out) {
        if (out == null) throw new IllegalArgumentException("Reusable output is required");
        out.clear();
        if (!valid(in)) { reset(); return; }
        if (!initialized || profile != in.profile) initialize(in);

        double dt = in.dtSeconds;
        if (in.direction != direction && holdTarget != in.direction) {
            holdTarget = in.direction;
            holdSeconds = 0.0;
            throttle = deliveredMagnitude = 0.0;
            rpm = profile.idleRpm;
            gear = 1;
        } else if (holdTarget != 0 && holdTarget != in.direction) {
            holdTarget = 0;
            holdSeconds = 0.0;
        }

        // A selected propulsion mode may still be opposed by residual motion in the game's dead zone.
        if (in.speedMps * in.direction < -config.directionSpeedMps) {
            holdTarget = in.direction;
            holdSeconds = 0.0;
            throttle = deliveredMagnitude = 0.0;
            rpm = profile.idleRpm;
            out.decision = Decision.DIRECTION_HOLD;
            return;
        }
        if (holdTarget != 0) {
            holdSeconds += dt;
            if (holdSeconds + 1.0e-12 < config.directionHoldSeconds) {
                out.decision = Decision.DIRECTION_HOLD;
                return;
            }
            direction = holdTarget;
            holdTarget = 0;
            holdSeconds = 0.0;
            shiftSeconds = config.shiftHoldSeconds;
            // Approval itself is a zero-force sample. The next sample begins the new ramp.
            out.decision = Decision.DIRECTION_HOLD;
            return;
        }

        double speed = Math.abs(in.speedMps);
        shiftSeconds = Math.max(0.0, shiftSeconds - dt);
        if (direction > 0) selectGear(in, speed);
        else gear = 1;

        double ramp = direction < 0 ? config.reverseRampSeconds : config.forwardRampSeconds;
        double beforeThrottle = throttle;
        throttle = approach(throttle, in.throttle, dt / ramp);
        double reverseLimit = config.reverseMaxSpeedKph * (in.sundayDriver ? 0.75 : 1.0);
        double coupledRpm = direction < 0 ? profile.reverseCoupledRpm(speed, reverseLimit)
            : profile.coupledRpm(couplingSpeed(in, speed), gear);
        double targetRpm = Math.max(coupledRpm, profile.idleRpm + throttle * (profile.launchRpm - profile.idleRpm));
        double maximumRpm = profile.redlineRpm * (direction < 0 ? 0.90 : 1.05);
        targetRpm = clamp(targetRpm, profile.idleRpm, maximumRpm);
        rpm += (targetRpm - rpm) * -Math.expm1(-dt / config.rpmResponseSeconds);
        rpm = clamp(rpm, profile.idleRpm, maximumRpm);

        double forceBase = in.enginePower * NOMINAL_GAME_FORCE * config.forceScale;
        double trait = in.sundayDriver ? (direction > 0 ? 0.75 : 0.70) : 1.0;
        double roadFactor = in.offroad ? in.offroadEfficiency * (in.towing ? 0.8 : 0.6) : 1.0;
        double cap;
        double curve;
        double governor;
        if (direction < 0) {
            // Reverse launch force and slew remain independent from forward calibration.
            cap = forceBase * config.reverseForceRatio * trait * roadFactor;
            curve = profile.torqueShape(rpm);
            governor = speedGovernor(speed * 3.6, reverseLimit * config.reverseGovernorStartFraction, reverseLimit);
        } else {
            // Anchor to the inspected control_ForwardNew force envelope. The first prototype's
            // ratio/first multiplier reduced every higher gear before its torque curve/governor.
            // This is game-force calibration, not horsepower-to-SI or measured wheel torque.
            double firstGear = gear == 1 ? 1.5 * config.lowGearBoost : 1.0;
            double originalEnvelope = in.enginePower * firstGear * (0.30 + rpm / 30000.0)
                * clamp(1.0 - speed * 3.6 / 200.0, 0.0, 1.0);
            cap = originalEnvelope * config.forceScale * trait * roadFactor;
            curve = profile.forwardTorqueModulation(rpm);
            double limit = in.sundayDriver ? profile.maxSpeedKph * 0.75
                : (profile.maxSpeedKph + 20.0) * (in.speedDemon ? 1.15 : 1.0);
            double start = in.sundayDriver ? Math.min(profile.maxSpeedKph * 0.60, limit * config.forwardGovernorStartFraction)
                : profile.maxSpeedKph * (in.speedDemon ? 1.15 : 1.0) * config.forwardGovernorStartFraction;
            governor = speedGovernor(speed * 3.6, start, limit);
        }
        double requested = cap * curve * throttle * governor;
        // Rise and release slew operate on delivered force, so inherited RPM cannot bypass the pedal ramp.
        double forceRate = forceBase * (direction < 0 ? config.reverseForceRatio : config.lowGearBoost) * trait / ramp;
        deliveredMagnitude = approach(deliveredMagnitude, requested, forceRate * dt);
        // A speed/trait/surface cap must take effect immediately even if the ordinary release is smoothed.
        deliveredMagnitude = Math.min(deliveredMagnitude, cap * (direction < 0 ? 1.0 : 1.10) * governor);
        if (throttle == 0.0 && beforeThrottle == 0.0) deliveredMagnitude = 0.0;
        if (!Double.isFinite(deliveredMagnitude) || !Double.isFinite(rpm)) { reset(); return; }

        out.engineForce = direction * Math.max(0.0, deliveredMagnitude);
        out.engineRpm = rpm;
        out.throttle = throttle;
        out.gear = direction < 0 ? -1 : gear;
        out.ownOffroad = in.offroad;
        out.decision = Decision.APPLIED;
    }

    private void initialize(Input in) {
        reset();
        profile = in.profile;
        initialized = true;
        direction = Math.abs(in.speedMps) > config.directionSpeedMps ? (in.speedMps > 0.0 ? 1 : -1)
            : in.currentGear == -1 ? -1 : 1;
        // Vanilla coast/braking can leave N at road speed. Reconstruct a safe gear from the
        // current speed, never resurrect prior sidecar force or climb 1->2->3 through shift holds.
        gear = direction > 0 ? reentryGear(in, Math.abs(in.speedMps)) : 1;
        rpm = direction < 0 ? profile.idleRpm : clamp(in.engineRpm, profile.idleRpm, profile.redlineRpm);
        shiftSeconds = config.shiftHoldSeconds;
    }

    private int reentryGear(Input in, double speed) {
        double coupledSpeed = couplingSpeed(in, speed);
        double upper = profile.redlineRpm * (config.lowMode || in.lowMode ? 0.96 : config.upshiftRpmFraction);
        int selected = 1;
        while (selected < profile.gearCount && profile.coupledRpm(coupledSpeed, selected) > upper) selected++;
        return selected;
    }

    private void selectGear(Input in, double speed) {
        if (shiftSeconds > 0.0) return;
        double couplingSpeed = couplingSpeed(in, speed);
        double wheelRpm = profile.coupledRpm(couplingSpeed, gear);
        boolean low = config.lowMode || in.lowMode;
        double upFraction = low ? 0.96 : config.upshiftRpmFraction;
        // Low mode retains first where safe, but never orders a downshift into an over-rev.
        if (gear > 1) {
            double lowerRpm = profile.coupledRpm(couplingSpeed, gear - 1);
            boolean demandDown = wheelRpm < profile.redlineRpm * config.downshiftRpmFraction
                || low || (in.throttle > 0.8 && wheelRpm < profile.redlineRpm * config.demandDownshiftFraction);
            // Compare at the lower gear too: wide-spaced three-speed boxes must not immediately
            // undo an upshift merely because their resulting RPM falls in the kick-down band.
            double lowerLimit = Math.min(0.90, upFraction - config.shiftHysteresisFraction);
            if (demandDown && lowerRpm < profile.redlineRpm * lowerLimit) {
                gear--;
                shiftSeconds = config.shiftHoldSeconds;
                return;
            }
        }
        if (gear < profile.gearCount && speed > 0.5 && wheelRpm > profile.redlineRpm * upFraction) {
            double nextRpm = profile.coupledRpm(couplingSpeed, gear + 1);
            // The destination must remain above launch RPM, while the lower-gear check above
            // owns hysteresis. A fixed destination fraction can prohibit all useful upshifts
            // in a wide-spaced box with otherwise valid threshold settings.
            if (nextRpm >= profile.launchRpm) {
                gear++;
                shiftSeconds = config.shiftHoldSeconds;
            }
        }
    }

    private boolean valid(Input in) {
        return in != null && in.profile != null && (in.direction == 1 || in.direction == -1)
            && in.currentGear >= -1 && in.currentGear <= in.profile.gearCount
            && finiteBetween(in.dtSeconds, Double.MIN_VALUE, config.maxDtSeconds)
            && finiteBetween(in.speedMps, -200.0, 200.0)
            && finiteBetween(in.enginePower, Double.MIN_VALUE, 1.0e7)
            && finiteBetween(in.engineRpm, 0.0, 20000.0)
            && finiteBetween(in.throttle, 0.0, 1.0)
            && (!in.offroad || finiteBetween(in.offroadEfficiency, 0.05, 2.0));
    }

    private double couplingSpeed(Input in, double speed) {
        // The existing Speed Demon speed benefit must not be silently erased by the RPM proxy's redline.
        // This is a game-trait mapping, not a claim that the trait physically changes the gearbox.
        return direction > 0 && in.speedDemon && !in.sundayDriver ? speed / 1.15 : speed;
    }

    public static double speedGovernor(double speedKph, double startKph, double limitKph) {
        if (!Double.isFinite(speedKph) || !Double.isFinite(startKph) || !Double.isFinite(limitKph)
            || startKph < 0.0 || limitKph <= startKph) return 0.0;
        double t = clamp((speedKph - startKph) / (limitKph - startKph), 0.0, 1.0);
        return 1.0 - t * t * (3.0 - 2.0 * t);
    }

    private static boolean finiteBetween(double value, double min, double max) {
        return Double.isFinite(value) && value >= min && value <= max;
    }
    private static double approach(double value, double target, double step) {
        return value + clamp(target - value, -step, step);
    }
    private static double clamp(double value, double min, double max) { return Math.max(min, Math.min(max, value)); }
}
