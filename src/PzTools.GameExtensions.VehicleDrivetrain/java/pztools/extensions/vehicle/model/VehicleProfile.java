package pztools.extensions.vehicle.model;

/**
 * Conservative engine-family candidates, not real vehicle specifications or measured wheel RPM.
 * Resolve/cache once per vehicle configuration. Unknown families deliberately have no fallback.
 */
public final class VehicleProfile {
    private final double[] ratios;
    public final String engineRpmType;
    public final int gearCount;
    public final double maxSpeedKph;
    public final double idleRpm;
    public final double redlineRpm;
    public final double launchRpm;
    private final double peakFraction;
    private final double idleTorqueFraction;
    private final double forwardTorqueBoostFraction;

    private VehicleProfile(String type, int gears, double maxSpeed, double redline, double peak, DrivetrainConfig config) {
        engineRpmType = type;
        gearCount = gears;
        maxSpeedKph = maxSpeed;
        idleRpm = config.idleRpm;
        redlineRpm = redline;
        launchRpm = config.launchRpm;
        peakFraction = peak;
        idleTorqueFraction = config.idleTorqueFraction;
        forwardTorqueBoostFraction = config.forwardTorqueBoostFraction;
        ratios = new double[gears];
        // Bounded, tunable geometric spacing. No claim that this is the car's physical gearbox.
        for (int i = 0; i < gears; i++) ratios[i] = Math.pow(config.gearRatioSpan, (gears - i - 1.0) / (gears - 1.0));
    }

    public static VehicleProfile resolve(String engineRpmType, int gearCount, double maxSpeedKph) {
        return resolve(engineRpmType, gearCount, maxSpeedKph, DrivetrainConfig.defaults());
    }

    public static VehicleProfile resolve(String engineRpmType, int gearCount, double maxSpeedKph, DrivetrainConfig config) {
        if (config == null) throw new IllegalArgumentException("Validated profile tuning is required");
        if (engineRpmType == null || gearCount < 3 || gearCount > 5 || !Double.isFinite(maxSpeedKph)
            || maxSpeedKph < 20.0 || maxSpeedKph > 300.0) return null;
        return switch (engineRpmType) {
            case "generic" -> new VehicleProfile(engineRpmType, gearCount, maxSpeedKph, config.genericRedlineRpm, config.genericTorquePeakFraction, config);
            case "van", "jeep" -> new VehicleProfile(engineRpmType, gearCount, maxSpeedKph, config.utilityRedlineRpm, config.utilityTorquePeakFraction, config);
            case "firebird" -> new VehicleProfile(engineRpmType, gearCount, maxSpeedKph, config.sportRedlineRpm, config.sportTorquePeakFraction, config);
            default -> null;
        };
    }

    public double ratio(int gear) {
        if (gear < 1 || gear > gearCount) throw new IllegalArgumentException("Gear is outside this profile");
        return ratios[gear - 1];
    }

    /** RPM proxy calibrated to the script's reference speed, not a wheel angular-speed observation. */
    public double coupledRpm(double absoluteSpeedMps, int gear) {
        return absoluteSpeedMps * 3.6 / maxSpeedKph * redlineRpm * ratio(gear);
    }

    /**
     * Reverse uses its independently tuned speed range, not the forward first-gear speed proxy.
     * This is a bounded display/control candidate, not a measured physical reverse gear ratio.
     */
    public double reverseCoupledRpm(double absoluteSpeedMps, double reverseLimitKph) {
        return Math.min(1.0, absoluteSpeedMps * 3.6 / reverseLimitKph) * redlineRpm * 0.90;
    }

    /** Add at most ten percent to the base force envelope; do not turn proxy redline into another speed cap. */
    public double forwardTorqueModulation(double rpm) {
        return 1.0 + forwardTorqueBoostFraction * torqueShape(rpm);
    }

    /** Bounded curve with useful idle torque, an engine-family peak and a redline fade. */
    public double torqueShape(double rpm) {
        if (!Double.isFinite(rpm) || rpm < 0.0) return 0.0;
        double n = rpm / redlineRpm;
        if (n >= 1.05) return 0.0;
        if (n <= peakFraction) return idleTorqueFraction + (1.0 - idleTorqueFraction) * Math.max(0.0, n / peakFraction);
        if (n <= 0.90) return 1.0 - 0.20 * (n - peakFraction) / (0.90 - peakFraction);
        return 0.80 * Math.max(0.0, (1.05 - n) / 0.15);
    }
}
