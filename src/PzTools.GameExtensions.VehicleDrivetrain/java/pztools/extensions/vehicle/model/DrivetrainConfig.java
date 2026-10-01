package pztools.extensions.vehicle.model;

import java.util.Map;
import java.util.Set;

/** Immutable, validated configuration. Parsing belongs to activation, never the game callback. */
public final class DrivetrainConfig {
    private static final Set<String> KEYS = Set.of("schema_version", "force_scale", "low_gear_boost",
        "reverse_force_ratio", "reverse_max_speed_kph", "reverse_ramp_seconds", "forward_ramp_seconds",
        "direction_hold_seconds", "max_dt_seconds", "shift_hold_seconds", "upshift_rpm_fraction",
        "downshift_rpm_fraction", "low_mode", "gear_ratio_span", "idle_rpm", "launch_rpm",
        "generic_redline_rpm", "utility_redline_rpm", "sport_redline_rpm",
        "generic_torque_peak_fraction", "utility_torque_peak_fraction", "sport_torque_peak_fraction",
        "idle_torque_fraction", "forward_torque_boost_fraction", "rpm_response_seconds", "direction_speed_mps",
        "forward_governor_start_fraction", "reverse_governor_start_fraction", "shift_hysteresis_fraction",
        "demand_downshift_fraction", "torque_enabled", "reverse_enabled", "steering_enabled",
        "steering_precise_input", "area_light_enabled", "area_light_radius", "area_light_brightness");

    public final double forceScale;
    public final double lowGearBoost;
    public final double reverseForceRatio;
    public final double reverseMaxSpeedKph;
    public final double reverseRampSeconds;
    public final double forwardRampSeconds;
    public final double directionHoldSeconds;
    public final double maxDtSeconds;
    public final double shiftHoldSeconds;
    public final double upshiftRpmFraction;
    public final double downshiftRpmFraction;
    public final double gearRatioSpan;
    public final double idleRpm;
    public final double launchRpm;
    public final double genericRedlineRpm;
    public final double utilityRedlineRpm;
    public final double sportRedlineRpm;
    public final double genericTorquePeakFraction;
    public final double utilityTorquePeakFraction;
    public final double sportTorquePeakFraction;
    public final double idleTorqueFraction;
    public final double forwardTorqueBoostFraction;
    public final double rpmResponseSeconds;
    public final double directionSpeedMps;
    public final double forwardGovernorStartFraction;
    public final double reverseGovernorStartFraction;
    public final double shiftHysteresisFraction;
    public final double demandDownshiftFraction;
    public final boolean torqueEnabled;
    public final boolean reverseEnabled;
    public final boolean steeringEnabled;
    /** Time the steering keys off the game thread instead of once per frame; off gives the game's own timing. */
    public final boolean steeringPreciseInput;
    public final boolean lowMode;
    /** Light the ground around the occupied vehicle while its headlights are lit. */
    public final boolean areaLightEnabled;
    /** Reach of that light in tiles. */
    public final int areaLightRadius;
    /** 0..1; how strongly that light lifts the darkness at its centre. */
    public final double areaLightBrightness;

    private DrivetrainConfig(Map<String, String> values) {
        for (String key : values.keySet()) {
            if (!KEYS.contains(key)) throw new IllegalArgumentException("Unknown drivetrain setting: " + key);
        }
        String schema = values.getOrDefault("schema_version", "1");
        if (!"1".equals(schema)) throw new IllegalArgumentException("schema_version must be 1");
        forceScale = number(values, "force_scale", 1.0, 0.25, 1.5);
        lowGearBoost = number(values, "low_gear_boost", 1.0, 1.0, 1.6);
        reverseForceRatio = number(values, "reverse_force_ratio", 1.0, 0.4, 1.0);
        reverseMaxSpeedKph = number(values, "reverse_max_speed_kph", 0.0, 0.0, 35.0);
        if (reverseMaxSpeedKph > 0.0 && reverseMaxSpeedKph < 4.0)
            throw new IllegalArgumentException("reverse_max_speed_kph must be 0 (vehicle default) or 4..35");
        reverseRampSeconds = number(values, "reverse_ramp_seconds", 0.8, 0.3, 2.0);
        forwardRampSeconds = number(values, "forward_ramp_seconds", 0.3, 0.1, 2.0);
        directionHoldSeconds = number(values, "direction_hold_seconds", 0.15, 0.05, 0.75);
        maxDtSeconds = number(values, "max_dt_seconds", 0.1, 0.02, 0.25);
        shiftHoldSeconds = number(values, "shift_hold_seconds", 0.35, 0.1, 2.0);
        upshiftRpmFraction = number(values, "upshift_rpm_fraction", 0.82, 0.65, 0.95);
        downshiftRpmFraction = number(values, "downshift_rpm_fraction", 0.32, 0.15, 0.55);
        gearRatioSpan = number(values, "gear_ratio_span", 3.6, 2.5, 5.0);
        idleRpm = number(values, "idle_rpm", 800.0, 500.0, 1200.0);
        launchRpm = number(values, "launch_rpm", 1500.0, 1000.0, 2500.0);
        genericRedlineRpm = number(values, "generic_redline_rpm", 5500.0, 3000.0, 6500.0);
        utilityRedlineRpm = number(values, "utility_redline_rpm", 4500.0, 3000.0, 6500.0);
        sportRedlineRpm = number(values, "sport_redline_rpm", 6500.0, 3000.0, 6500.0);
        genericTorquePeakFraction = number(values, "generic_torque_peak_fraction", 0.50, 0.25, 0.80);
        utilityTorquePeakFraction = number(values, "utility_torque_peak_fraction", 0.40, 0.25, 0.80);
        sportTorquePeakFraction = number(values, "sport_torque_peak_fraction", 0.65, 0.25, 0.80);
        idleTorqueFraction = number(values, "idle_torque_fraction", 0.60, 0.30, 0.80);
        forwardTorqueBoostFraction = number(values, "forward_torque_boost_fraction", 0.10, 0.0, 0.10);
        rpmResponseSeconds = number(values, "rpm_response_seconds", 0.12, 0.04, 0.50);
        directionSpeedMps = number(values, "direction_speed_mps", 0.15, 0.05, 0.30);
        forwardGovernorStartFraction = number(values, "forward_governor_start_fraction", 1.0, 0.75, 1.0);
        reverseGovernorStartFraction = number(values, "reverse_governor_start_fraction", 1.0, 0.50, 1.0);
        shiftHysteresisFraction = number(values, "shift_hysteresis_fraction", 0.08, 0.04, 0.15);
        demandDownshiftFraction = number(values, "demand_downshift_fraction", 0.48, 0.25, 0.60);
        torqueEnabled = flag(values, "torque_enabled", true);
        reverseEnabled = flag(values, "reverse_enabled", true);
        steeringEnabled = flag(values, "steering_enabled", true);
        steeringPreciseInput = flag(values, "steering_precise_input", true);
        if (upshiftRpmFraction - downshiftRpmFraction + 1.0e-12 < 0.15) {
            throw new IllegalArgumentException("upshift_rpm_fraction must exceed downshift_rpm_fraction by at least 0.15");
        }
        double minimumRedline = Math.min(genericRedlineRpm, Math.min(utilityRedlineRpm, sportRedlineRpm));
        if (idleRpm >= launchRpm || launchRpm >= minimumRedline)
            throw new IllegalArgumentException("RPM tuning requires idle_rpm < launch_rpm < every redline");
        // Three gears have the widest adjacent spacing of our supported profiles. Ensure all
        // supported families can upshift above launch RPM even at the configured threshold.
        if (launchRpm > minimumRedline * upshiftRpmFraction / Math.sqrt(gearRatioSpan) + 1.0e-9)
            throw new IllegalArgumentException("launch_rpm exceeds the lowest post-upshift RPM of the supported profiles");
        lowMode = flag(values, "low_mode", false);
        areaLightEnabled = flag(values, "area_light_enabled", true);
        areaLightRadius = (int) Math.round(number(values, "area_light_radius", 8.0, 3.0, 20.0));
        areaLightBrightness = number(values, "area_light_brightness", 0.6, 0.1, 1.0);
    }

    public static DrivetrainConfig defaults() { return new DrivetrainConfig(Map.of()); }
    public static DrivetrainConfig parse(Map<String, String> values) {
        if (values == null) throw new IllegalArgumentException("Drivetrain settings are required");
        return new DrivetrainConfig(values);
    }
    public static DrivetrainConfig fromMap(Map<String, String> values) { return parse(values); }

    private static boolean flag(Map<String, String> values, String key, boolean fallback) {
        String value = values.getOrDefault(key, fallback ? "true" : "false");
        if (!"true".equals(value) && !"false".equals(value)) throw new IllegalArgumentException(key + " must be true or false");
        return "true".equals(value);
    }

    private static double number(Map<String, String> values, String key, double fallback, double min, double max) {
        String text = values.get(key);
        if (text == null && !values.containsKey(key)) return fallback;
        double value;
        try { value = Double.parseDouble(text); }
        catch (RuntimeException invalid) { throw new IllegalArgumentException("Invalid drivetrain setting: " + key, invalid); }
        if (!Double.isFinite(value) || value < min || value > max) {
            throw new IllegalArgumentException(key + " must be finite and between " + min + " and " + max);
        }
        return value;
    }
}
