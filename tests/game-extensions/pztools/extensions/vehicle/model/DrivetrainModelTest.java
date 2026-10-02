package pztools.extensions.vehicle.model;

import java.util.Map;

/** Pure JVM contract tests. Passing these does not establish native-force units or in-game handling. */
public final class DrivetrainModelTest {
    private static int checks;
    private static final VehicleProfile CAR = VehicleProfile.resolve("generic", 4, 120.0);

    public static void main(String[] args) {
        configurationAndProfiles();
        boundedProfileTuning();
        forwardTorqueBoostTuning();
        finiteInputsAndRecovery();
        reverseRampAndGovernor();
        reverseVehicleLimitsAndTraitFade();
        reverseLimitValidationIsDirectional();
        directionTransitionAndReset();
        automaticGearsAndLowMode();
        allGearSpacingsAvoidHunting();
        equalCouplingForceAndOffroadRecovery();
        forwardBaseEnvelopeAtProxyRpm();
        forwardTraitAndLimitParity();
        rollingReentryAndReverseOverrev();
        commonCurveAndSurfaceOwnership();
        traitsAndIndependentVehicles();
        timePartitionAndLongRunning();
        System.out.println("PASS: " + checks + " vehicle drivetrain model assertions (game-free; experimental calibration)");
    }

    private static void configurationAndProfiles() {
        DrivetrainConfig c = DrivetrainConfig.defaults();
        near(c.lowGearBoost, 1.0, 0.0, "no default extra launch boost");
        near(c.reverseForceRatio, 1.0, 0.0, "reverse retains the baseline force envelope");
        near(c.reverseMaxSpeedKph, 0.0, 0.0, "zero selects the vehicle-derived reverse limit");
        near(c.reverseGovernorStartFraction, 1.0, 0.0, "default reverse governor does not reduce force before the limit");
        near(c.forwardGovernorStartFraction, 1.0, 0.0, "forward governor does not preempt the reference speed");
        check(c.torqueEnabled && c.reverseEnabled && c.steeringEnabled, "independent options default on within the disabled module");
        check(c.steeringPreciseInput, "precise key timing defaults on; off gives the game's per-frame timing");
        near(c.maxDtSeconds, 0.1, 0.0, "bounded timestep");
        check(!c.lowMode, "low mode opt in");
        reject(Map.of("force_scale", "NaN"));
        reject(Map.of("force_scale", "Infinity"));
        reject(Map.of("force_scale", "0"));
        reject(Map.of("reverse_force_ratio", "0.3"));
        reject(Map.of("reverse_max_speed_kph", "36"));
        for (String invalid : new String[]{"-1", "0.01", "3.99", "NaN", "Infinity"})
            reject(Map.of("reverse_max_speed_kph", invalid));
        for (String valid : new String[]{"0", "4", "20", "35"})
            near(DrivetrainConfig.parse(Map.of("reverse_max_speed_kph", valid)).reverseMaxSpeedKph,
                Double.parseDouble(valid), 0, "reverse sentinel and explicit override boundaries");
        reject(Map.of("torque_enabled", "yes"));
        reject(Map.of("reverse_enabled", "1"));
        reject(Map.of("steering_enabled", "TRUE"));
        reject(Map.of("steering_precise_input", "1"));
        check(!DrivetrainConfig.parse(Map.of("steering_precise_input", "false")).steeringPreciseInput, "precise key timing can be switched off");
        // The old rate settings are gone: steering follows the game, so there is nothing left to tune.
        for (String removed : new String[]{"steering_initial_rate", "steering_full_rate", "steering_ramp_seconds", "steering_return_rate", "steering_countersteer_rate", "steering_high_speed_rate_factor"})
            reject(Map.of(removed, "1"));
        DrivetrainConfig independent = DrivetrainConfig.parse(Map.of("torque_enabled", "false", "reverse_enabled", "true", "steering_enabled", "false"));
        check(!independent.torqueEnabled && independent.reverseEnabled && !independent.steeringEnabled, "settings do not couple independent adapter gates");
        reject(Map.of("schema_version", "2"));
        reject(Map.of("unknown", "1"));
        reject(Map.of("low_mode", "yes"));
        reject(Map.of("upshift_rpm_fraction", "0.65", "downshift_rpm_fraction", "0.55"));
        check(DrivetrainConfig.fromMap(Map.of("low_mode", "true")).lowMode, "factory alias");
        check(VehicleProfile.resolve("unknown", 4, 120) == null, "unknown engine falls through");
        check(VehicleProfile.resolve("generic", 8, 120) == null, "unvalidated gear count falls through");
        check(VehicleProfile.resolve("generic", 4, Double.NaN) == null, "invalid script speed rejected");
        for (String engine : new String[]{"generic", "van", "jeep", "firebird"}) {
            for (int count = 3; count <= 5; count++) {
                VehicleProfile p = VehicleProfile.resolve(engine, count, 100.0);
                check(p != null && p.redlineRpm <= 7000, "bounded known profile");
                for (int gear = 2; gear <= count; gear++) check(p.ratio(gear - 1) > p.ratio(gear), "gear reductions descend");
                for (int rpm = 0; rpm <= 20000; rpm += 37) {
                    check(p.torqueShape(rpm) >= 0 && p.torqueShape(rpm) <= 1, "curve remains bounded");
                }
            }
        }
    }

    private static void forwardTorqueBoostTuning() {
        near(DrivetrainConfig.defaults().forwardTorqueBoostFraction, 0.10, 0, "default preserves ten-percent boost");
        near(DrivetrainConfig.parse(Map.of("force_scale", "1")).forwardTorqueBoostFraction, 0.10, 0,
            "missing boost setting preserves old configuration behavior");
        for (String invalid : new String[]{"-0.0001", "0.100000001", "NaN", "Infinity", "-Infinity"})
            reject(Map.of("forward_torque_boost_fraction", invalid));
        DrivetrainConfig zero = DrivetrainConfig.parse(Map.of("forward_torque_boost_fraction", "0"));
        for (double boost : new double[]{0, 0.04, 0.10}) {
            DrivetrainConfig tuned = DrivetrainConfig.parse(Map.of("forward_torque_boost_fraction", Double.toString(boost)));
            near(tuned.forwardTorqueBoostFraction, boost, 0, "zero/custom/maximum boost accepted");
            for (String family : new String[]{"generic", "van", "jeep", "firebird"}) {
                VehicleProfile p = VehicleProfile.resolve(family, 4, 120, tuned);
                VehicleProfile original = VehicleProfile.resolve(family, 4, 120);
                for (int rpm = 0; rpm <= 20000; rpm += 37) {
                    double curve = p.forwardTorqueModulation(rpm);
                    near(curve, 1 + boost * p.torqueShape(rpm), 0, "configured boost scales only the bounded curve");
                    check(curve >= 1 && curve <= 1 + boost && curve <= 1.10, "curve stays within configured and hard maximum");
                    near(original.forwardTorqueModulation(rpm), 1 + 0.10 * original.torqueShape(rpm), 0,
                        "default curve exactly preserves previous formula");
                }
                for (int direction : new int[]{-1, 1}) {
                    for (double speed : new double[]{0, 8, 80}) {
                        DrivetrainModel.Input baseInput = input(), tunedInput = input();
                        baseInput.profile = VehicleProfile.resolve(family, 4, 120, zero); tunedInput.profile = p;
                        baseInput.direction = tunedInput.direction = direction;
                        baseInput.currentGear = tunedInput.currentGear = direction;
                        baseInput.speedMps = tunedInput.speedMps = direction * speed / 3.6;
                        DrivetrainModel.Output base = new DrivetrainModel.Output(), actual = new DrivetrainModel.Output();
                        step(new DrivetrainModel(zero), baseInput, base, 3);
                        step(new DrivetrainModel(tuned), tunedInput, actual, 3);
                        check(actual.decision == DrivetrainModel.Decision.APPLIED && actual.gear == base.gear,
                            "boost changes no model decision or gear");
                        near(actual.engineRpm, base.engineRpm, 0, "boost changes no RPM response");
                        near(actual.throttle, base.throttle, 0, "boost changes no throttle ramp");
                        double multiplier = direction < 0 ? 1 : 1 + boost * p.torqueShape(actual.engineRpm);
                        near(actual.engineForce, base.engineForce * multiplier, direction < 0 ? 0 : 1e-8,
                            "forward boost scales settled force; reverse remains exactly unchanged");
                        if (direction > 0 && speed == 0 && boost > 0)
                            check(actual.engineForce > base.engineForce, "nonzero boost has a real forward effect");
                    }
                }
            }
            DrivetrainModel.Input in = input(); in.profile = VehicleProfile.resolve("generic", 4, 120, tuned);
            DrivetrainModel.Output out = new DrivetrainModel.Output(); DrivetrainModel model = new DrivetrainModel(tuned);
            step(model, in, out, 3);
            in.offroad = true; in.offroadEfficiency = 0.05;
            model.step(in, out);
            double reducedCap = forwardBaseEnvelope(in, out.engineRpm, out.gear) * 0.05 * 0.6;
            near(out.engineForce, reducedCap * (1 + boost), 1e-8,
                "abrupt surface cap applies configured boost ceiling immediately");
        }
    }

    private static void finiteInputsAndRecovery() {
        DrivetrainModel m = model();
        DrivetrainModel.Input in = input();
        DrivetrainModel.Output out = new DrivetrainModel.Output();
        step(m, in, out, 2.0);
        check(out.engineForce > 0.0, "valid input drives");
        for (double invalid : new double[]{0.0, -0.01, Double.NaN, Double.POSITIVE_INFINITY, 0.5}) {
            in.dtSeconds = invalid;
            out.ownOffroad = true;
            m.step(in, out);
            check(out.decision == DrivetrainModel.Decision.VANILLA, "invalid dt yields original behavior");
            near(out.engineForce, 0, 0, "invalid dt clears reusable result");
            check(!out.ownOffroad, "invalid dt clears same-step surface ownership");
        }
        in.dtSeconds = 0.02;
        for (double invalid : new double[]{Double.NaN, Double.NEGATIVE_INFINITY, 201.0}) {
            in.speedMps = invalid;
            m.step(in, out);
            check(out.decision == DrivetrainModel.Decision.VANILLA, "invalid speed falls through");
        }
        in.speedMps = 0;
        in.throttle = 2;
        m.step(in, out);
        check(out.decision == DrivetrainModel.Decision.VANILLA, "invalid pedal falls through");
        in.throttle = 1;
        in.enginePower = 0;
        m.step(in, out);
        check(out.decision == DrivetrainModel.Decision.VANILLA, "no positive engine power falls through");
        in.enginePower = 4000;
        in.profile = null;
        m.step(in, out);
        check(out.decision == DrivetrainModel.Decision.VANILLA, "unknown profile falls through");
        in.profile = CAR;
        m.step(in, out);
        DrivetrainModel.Output fresh = new DrivetrainModel.Output();
        model().step(in, fresh);
        near(out.engineForce, fresh.engineForce, 1e-9, "invalid interval discards old force state");
    }

    private static void boundedProfileTuning() {
        for (String[] setting : new String[][]{
                {"gear_ratio_span", "5.1"}, {"idle_rpm", "499"}, {"launch_rpm", "2501"},
                {"generic_redline_rpm", "6501"}, {"utility_redline_rpm", "NaN"}, {"sport_redline_rpm", "2999"},
                {"generic_torque_peak_fraction", "0.9"}, {"utility_torque_peak_fraction", "0.1"}, {"sport_torque_peak_fraction", "Infinity"},
                {"idle_torque_fraction", "1.0"}, {"rpm_response_seconds", "0"}, {"direction_speed_mps", "0"},
                {"forward_governor_start_fraction", "1.01"}, {"reverse_governor_start_fraction", "1.01"},
                {"reverse_governor_start_fraction", "0.49"},
                {"shift_hysteresis_fraction", "0"}, {"demand_downshift_fraction", "0.9"}})
            reject(Map.of(setting[0], setting[1]));
        reject(Map.of("idle_rpm", "1200", "launch_rpm", "1000"));
        reject(Map.of("launch_rpm", "2500", "utility_redline_rpm", "3000"));
        DrivetrainConfig c = DrivetrainConfig.parse(Map.ofEntries(
            Map.entry("gear_ratio_span", "4.0"), Map.entry("idle_rpm", "700"), Map.entry("launch_rpm", "1200"),
            Map.entry("generic_redline_rpm", "6000"), Map.entry("utility_redline_rpm", "5000"), Map.entry("sport_redline_rpm", "6200"),
            Map.entry("generic_torque_peak_fraction", "0.6"), Map.entry("utility_torque_peak_fraction", "0.45"), Map.entry("sport_torque_peak_fraction", "0.7"),
            Map.entry("idle_torque_fraction", "0.4"), Map.entry("rpm_response_seconds", "0.2"), Map.entry("direction_speed_mps", "0.2"),
            Map.entry("forward_governor_start_fraction", "0.85"), Map.entry("reverse_governor_start_fraction", "0.6"),
            Map.entry("shift_hysteresis_fraction", "0.1"), Map.entry("demand_downshift_fraction", "0.5")));
        VehicleProfile p = VehicleProfile.resolve("generic", 3, 120, c);
        near(p.ratio(1) / p.ratio(3), 4, 0, "configured gear span builds the profile");
        near(p.idleRpm, 700, 0, "configured idle RPM");
        near(p.launchRpm, 1200, 0, "configured launch RPM");
        near(p.redlineRpm, 6000, 0, "configured generic redline");
        near(p.torqueShape(0), 0.4, 0, "configured curve baseline");
        near(p.torqueShape(3600), 1, 0, "configured curve peak");
        near(VehicleProfile.resolve("van", 4, 120, c).redlineRpm, 5000, 0, "configured utility redline");
        near(VehicleProfile.resolve("firebird", 5, 120, c).redlineRpm, 6200, 0, "configured sport redline");
        check(VehicleProfile.resolve("custom-unverified", 4, 120, c) == null, "tuning cannot authorize unknown engine types");
        DrivetrainModel.Input in = input(); in.profile = p;
        DrivetrainModel.Output out = new DrivetrainModel.Output();
        step(new DrivetrainModel(c), in, out, 3);
        near(out.engineRpm, 1200, 0.001, "model uses configured launch and RPM response");

        DrivetrainModel.Output standard = new DrivetrainModel.Output();
        in = input(); in.direction = in.currentGear = -1; in.speedMps = -17.6 / 3.6;
        step(model(), in, standard, 3);
        DrivetrainConfig early = DrivetrainConfig.parse(Map.of("reverse_governor_start_fraction", "0.5"));
        in.profile = VehicleProfile.resolve("generic", 4, 120, early);
        step(new DrivetrainModel(early), in, out, 3);
        near(out.engineForce / standard.engineForce,
            DrivetrainModel.speedGovernor(17.6, in.reverseMaxSpeedKph * 0.5, in.reverseMaxSpeedKph), 1e-9,
            "configured reverse governor onset is used exactly once");
    }

    private static void reverseRampAndGovernor() {
        DrivetrainModel m = model();
        DrivetrainModel.Input in = input();
        DrivetrainModel.Output out = new DrivetrainModel.Output();
        in.direction = in.currentGear = -1;
        in.engineRpm = 6500;
        double cap = in.enginePower;
        double previous = 0;
        for (int i = 0; i < 100; i++) {
            m.step(in, out);
            check(out.decision == DrivetrainModel.Decision.APPLIED && out.gear == -1, "reverse applies consistent gear");
            check(out.engineForce <= 0 && -out.engineForce <= cap + 1e-9, "reverse bounded and signed");
            check(-out.engineForce - previous <= reverseEnvelope(in, out.engineRpm) / 0.8 * in.dtSeconds + 1e-8,
                "delivered reverse rise uses the current baseline force envelope");
            check(out.throttle <= Math.min(1.0, (i + 1) * in.dtSeconds / 0.8) + 1e-9, "pedal independently ramps");
            previous = -out.engineForce;
        }
        check(-out.engineForce > cap * 0.6, "reverse retains usable steady low-speed force");
        double previousGovernor = 1;
        for (double speed = 0; speed <= 100; speed += 0.25) {
            double g = DrivetrainModel.speedGovernor(speed, 9, 12);
            check(g >= 0 && g <= 1 && g <= previousGovernor + 1e-12, "governor bounded and monotonic");
            previousGovernor = g;
        }
        near(DrivetrainModel.speedGovernor(12, 9, 12), 0, 0, "governor shuts down positive propulsion");
        near(DrivetrainModel.speedGovernor(9, 9, 12), 1, 0, "governor starts continuously");
        for (double speed : new double[]{in.reverseMaxSpeedKph, 35, 100, 500}) {
            in.speedMps = -speed / 3.6;
            m.step(in, out);
            near(out.engineForce, 0, 0, "overspeed never creates negative-throttle braking or thrust");
        }
    }

    private static void directionTransitionAndReset() {
        DrivetrainModel m = model();
        DrivetrainModel.Input in = input();
        DrivetrainModel.Output out = new DrivetrainModel.Output();
        in.speedMps = 8;
        step(m, in, out, 3);
        in.direction = -1;
        for (int i = 0; i < 50; i++) {
            m.step(in, out);
            check(out.decision == DrivetrainModel.Decision.DIRECTION_HOLD, "moving opposite request holds original brakes");
            near(out.engineForce, 0, 0, "hold leaks no preceding forward force");
            check(!out.ownOffroad, "hold never owns offroad");
        }
        in.speedMps = 0;
        for (int i = 0; i < 8; i++) {
            m.step(in, out);
            check(out.decision == DrivetrainModel.Decision.DIRECTION_HOLD, "direction dwell includes zero-force approval sample");
        }
        m.step(in, out);
        check(out.decision == DrivetrainModel.Decision.APPLIED && out.engineForce < 0, "reverse starts after dwell");
        check(-out.engineForce <= reverseEnvelope(in, out.engineRpm) / 0.8 * in.dtSeconds + 1e-8,
            "old forward RPM cannot bypass reverse ramp");
        step(m, in, out, 2);
        m.reset();
        in.currentGear = -1;
        m.step(in, out);
        DrivetrainModel.Output fresh = new DrivetrainModel.Output();
        model().step(in, fresh);
        near(out.engineForce, fresh.engineForce, 1e-9, "vanilla interval resumes like fresh state");
        near(out.engineRpm, fresh.engineRpm, 1e-9, "reset drops stale RPM");
        m.reset();
        in.direction = in.currentGear = 1;
        in.speedMps = 0;
        step(m, in, out, 1);
        in.speedMps = -0.3;
        m.step(in, out);
        check(out.decision == DrivetrainModel.Decision.DIRECTION_HOLD, "unexpected roll against selected gear holds");
        in.speedMps = 0;
        m.step(in, out);
        check(out.decision == DrivetrainModel.Decision.DIRECTION_HOLD, "residual-motion hold retains near-stop dwell");
    }

    private static void reverseVehicleLimitsAndTraitFade() {
        for (double configured : new double[]{0, 20, 35}) {
            DrivetrainConfig c = DrivetrainConfig.parse(Map.of("reverse_max_speed_kph", Double.toString(configured)));
            for (double vehicleLimit : new double[]{20, 40.0 / 1.5, 40}) {
                double limit = configured == 0 ? vehicleLimit : configured;
                for (int traits = 0; traits < 4; traits++) {
                    for (double speed : new double[]{0, 3.333 - 0.01, 10.0 / 3.0, 10.0 / 3.0 + 0.01,
                            5, 9.99, 10, 10.01, limit * 0.75, limit - 0.01, limit, limit + 0.01}) {
                        DrivetrainModel.Input in = input(); in.direction = in.currentGear = -1;
                        in.reverseMaxSpeedKph = vehicleLimit; in.speedMps = -speed / 3.6;
                        in.sundayDriver = (traits & 1) != 0; in.speedDemon = (traits & 2) != 0;
                        DrivetrainModel.Output out = new DrivetrainModel.Output();
                        step(new DrivetrainModel(c), in, out, 3);
                        check(out.decision == DrivetrainModel.Decision.APPLIED && out.engineForce <= 0,
                            "valid reverse limits always retain reverse force polarity");
                        double actualSpeed = Math.abs(in.speedMps) * 3.6;
                        double expected = actualSpeed >= limit ? 0 : reverseEnvelope(in, out.engineRpm);
                        near(-out.engineForce, expected, 1e-7,
                            "reverse script/override cutoff and independent Sunday fade: " + configured + "/" + vehicleLimit + "/" + traits + "/" + speed);
                    }
                }
            }
        }
        // Compare force divided by the changing RPM envelope, not force alone: RPM itself adds force.
        for (double onset : new double[]{0.5, 0.75, 1.0}) {
            DrivetrainConfig c = DrivetrainConfig.parse(Map.of("reverse_max_speed_kph", "20",
                "reverse_governor_start_fraction", Double.toString(onset), "reverse_force_ratio", "0.4"));
            double previous = 1;
            for (double speed = 0; speed <= 24; speed += 0.25) {
                DrivetrainModel.Input in = input(); in.direction = in.currentGear = -1; in.speedMps = -speed / 3.6;
                DrivetrainModel.Output out = new DrivetrainModel.Output(); step(new DrivetrainModel(c), in, out, 3);
                double governor = -out.engineForce / (reverseEnvelope(in, out.engineRpm) * 0.4);
                double expected = speed >= 20 ? 0 : onset == 1 ? 1 : DrivetrainModel.speedGovernor(speed, 20 * onset, 20);
                near(governor, expected, 1e-9, "explicit early reverse fade is applied once");
                check(governor >= -1e-12 && governor <= previous + 1e-12, "reverse governor remains nonnegative and monotonic");
                previous = governor;
            }
        }
        for (boolean towing : new boolean[]{false, true}) {
            DrivetrainModel.Input in = input(); in.direction = in.currentGear = -1; in.speedMps = -8 / 3.6;
            in.offroad = true; in.offroadEfficiency = 0.8; in.towing = towing;
            DrivetrainModel.Output out = new DrivetrainModel.Output(); step(model(), in, out, 3);
            near(-out.engineForce, reverseEnvelope(in, out.engineRpm), 1e-7, "reverse road factor belongs to the model exactly once");
            check(out.ownOffroad, "applied reverse owns its road factor");
        }
    }

    private static void reverseLimitValidationIsDirectional() {
        for (double invalid : new double[]{0, -1, Double.NaN, Double.POSITIVE_INFINITY}) {
            DrivetrainModel.Input in = input(); in.reverseMaxSpeedKph = invalid;
            DrivetrainModel.Output out = new DrivetrainModel.Output(); step(model(), in, out, 1);
            check(out.decision == DrivetrainModel.Decision.APPLIED && out.engineForce > 0,
                "invalid vehicle reverse limit cannot disable forward control");
            in.direction = in.currentGear = -1; model().step(in, out);
            check(out.decision == DrivetrainModel.Decision.VANILLA && out.engineForce == 0 && !out.ownOffroad,
                "default reverse requires a valid vehicle-derived limit");
            DrivetrainConfig override = DrivetrainConfig.parse(Map.of("reverse_max_speed_kph", "20"));
            step(new DrivetrainModel(override), in, out, 1);
            check(out.decision == DrivetrainModel.Decision.APPLIED && out.engineForce < 0,
                "explicit reverse override does not depend on the invalid script limit");
        }
        DrivetrainModel m = model(); DrivetrainModel.Input in = input(); in.direction = in.currentGear = -1;
        DrivetrainModel.Output out = new DrivetrainModel.Output(); step(m, in, out, 2);
        in.reverseMaxSpeedKph = Double.NaN; m.step(in, out);
        check(out.decision == DrivetrainModel.Decision.VANILLA, "invalid script interval falls through after live reverse");
        in.reverseMaxSpeedKph = 40.0 / 1.5; m.step(in, out);
        DrivetrainModel.Output fresh = new DrivetrainModel.Output(); model().step(in, fresh);
        near(out.engineForce, fresh.engineForce, 0, "reverse script recovery cannot resurrect prior force");
    }

    private static double reverseEnvelope(DrivetrainModel.Input in, double rpm) {
        double magnitude = in.enginePower * (0.75 + rpm / 24000.0);
        if (rpm > 6000) magnitude *= Math.max(0, (7000 - rpm) / 1000.0);
        if (in.sundayDriver) {
            magnitude *= 0.7;
            double scaledSpeed = Math.abs(in.speedMps) * 3.6 * 1.5;
            if (scaledSpeed > 5) magnitude *= Math.max(0, (15 - scaledSpeed) / 10.0);
        }
        if (in.offroad) magnitude *= in.offroadEfficiency * (in.towing ? 0.8 : 0.6);
        return magnitude;
    }

    private static void automaticGearsAndLowMode() {
        DrivetrainModel.Input in = input();
        DrivetrainModel.Output out = new DrivetrainModel.Output();
        DrivetrainModel m = model();
        in.engineRpm = 6500;
        step(m, in, out, 20);
        check(out.gear == 1, "stationary high RPM never upshifts");
        in.speedMps = 35 / 3.6;
        step(m, in, out, 2);
        check(out.gear >= 2, "speed-derived RPM enables upshift");
        in.speedMps = 1;
        step(m, in, out, 3);
        check(out.gear == 1, "held throttle downshifts as vehicle slows");
        in.currentGear = 3;
        in.speedMps = 60 / 3.6;
        in.lowMode = true;
        m.reset();
        step(m, in, out, 2);
        check(out.gear >= 3, "low mode refuses unsafe downshift");
        in.speedMps = 8 / 3.6;
        step(m, in, out, 3);
        check(out.gear == 1, "low mode returns to low gear where safe");
        in.speedMps = 36 / 3.6;
        step(m, in, out, 2);
        check(out.gear > 1, "redline protection outranks low mode");
        m.reset();
        in.lowMode = false;
        in.currentGear = 1;
        int lastGear = 1;
        int changes = 0;
        double lastShiftTime = -10;
        for (int i = 0; i < 300; i++) {
            in.speedMps = ((i & 1) == 0 ? 28 : 29) / 3.6;
            m.step(in, out);
            if (out.gear != lastGear) {
                check(i * in.dtSeconds - lastShiftTime >= 0.34, "shift hold prevents rapid hunting");
                lastShiftTime = i * in.dtSeconds;
                lastGear = out.gear;
                changes++;
            }
        }
        check(changes < 5, "adjacent boundary samples do not hunt repeatedly");
    }

    private static void commonCurveAndSurfaceOwnership() {
        double rpm = 2400;
        check(CAR.torqueShape(rpm) * CAR.ratio(1) > CAR.torqueShape(rpm) * CAR.ratio(3),
            "at equal RPM/coupling low gear delivers greater force");
        DrivetrainModel.Input in = input();
        DrivetrainModel.Output road = new DrivetrainModel.Output();
        step(model(), in, road, 3);
        in.offroad = true;
        in.offroadEfficiency = 0.8;
        DrivetrainModel.Output dirt = new DrivetrainModel.Output();
        step(model(), in, dirt, 3);
        check(dirt.ownOffroad, "successful offroad result claims same-step ownership");
        near(dirt.engineForce / road.engineForce, 0.8 * 0.6, 1e-9, "offroad efficiency applied exactly once");
        in.towing = true;
        DrivetrainModel.Output tow = new DrivetrainModel.Output();
        step(model(), in, tow, 3);
        near(tow.engineForce / road.engineForce, 0.8 * 0.8, 1e-9, "ordinary tow base factor applied once");
        in.offroadEfficiency = 0;
        model().step(in, tow);
        check(tow.decision == DrivetrainModel.Decision.VANILLA && !tow.ownOffroad, "invalid surface returns original penalty");
    }

    private static void allGearSpacingsAvoidHunting() {
        for (String family : new String[]{"generic", "van", "jeep", "firebird"}) {
            for (int count = 3; count <= 5; count++) {
                for (DrivetrainConfig config : new DrivetrainConfig[]{DrivetrainConfig.defaults(),
                        DrivetrainConfig.parse(Map.of("upshift_rpm_fraction", "0.95", "downshift_rpm_fraction", "0.55")),
                        DrivetrainConfig.parse(Map.of("upshift_rpm_fraction", "0.65", "downshift_rpm_fraction", "0.15"))}) {
                    VehicleProfile p = VehicleProfile.resolve(family, count, 120);
                    DrivetrainModel.Input in = input();
                    in.profile = p;
                    in.speedMps = (config.upshiftRpmFraction + 0.01) * p.maxSpeedKph / p.ratio(1) / 3.6;
                    DrivetrainModel m = new DrivetrainModel(config);
                    DrivetrainModel.Output out = new DrivetrainModel.Output();
                    int changes = 0, previousGear = 1;
                    for (int i = 0; i < 500; i++) {
                        m.step(in, out);
                        if (out.gear != previousGear) { changes++; previousGear = out.gear; }
                    }
                    check(out.gear == 2, "valid thresholds permit wide-ratio first upshift: " + family + "/" + count);
                    check(changes == 1, "held speed cannot undo its upshift: " + family + "/" + count);
                }
            }
        }
    }

    private static void equalCouplingForceAndOffroadRecovery() {
        DrivetrainModel.Output first = new DrivetrainModel.Output(), third = new DrivetrainModel.Output();
        DrivetrainModel.Input in = input();
        in.throttle = 0.7;
        in.engineRpm = CAR.redlineRpm * 0.55;
        in.speedMps = 0.55 * CAR.maxSpeedKph / CAR.ratio(1) / 3.6;
        step(model(), in, first, 3);
        in.currentGear = 3;
        in.speedMps = 0.55 * CAR.maxSpeedKph / CAR.ratio(3) / 3.6;
        step(model(), in, third, 3);
        check(first.gear == 1 && third.gear == 3, "equal-coupling fixture holds chosen gears");
        near(first.engineRpm, third.engineRpm, 1e-8, "force comparison uses the same coupled RPM");
        double firstSpeedKph = 0.55 * CAR.maxSpeedKph / CAR.ratio(1);
        double thirdSpeedKph = 0.55 * CAR.maxSpeedKph / CAR.ratio(3);
        near(first.engineForce / third.engineForce, 1.5 * (1.0 - firstSpeedKph / 200) / (1.0 - thirdSpeedKph / 200), 1e-8,
            "actual step preserves first-gear leverage without multiplying high-gear attenuation twice");
        in.enginePower *= 2;
        DrivetrainModel.Output doubled = new DrivetrainModel.Output();
        step(model(), in, doubled, 3);
        near(doubled.engineForce / third.engineForce, 2, 1e-8, "raw engine power is scaled once");

        in = input();
        in.currentGear = CAR.gearCount;
        in.speedMps = 100.0 / 3.6;
        DrivetrainModel m = model();
        step(m, in, first, 2);
        check(first.gear == CAR.gearCount, "high-speed case begins in top gear");
        in.offroad = true;
        in.offroadEfficiency = 0.8;
        in.speedMps = 5.0 / 3.6;
        step(m, in, first, 2);
        check(first.gear == 1 && first.ownOffroad, "held throttle downshifts to first after offroad slowdown");
        check(first.engineForce > in.enginePower * 0.65 * 0.8 * 0.6 * 0.6,
            "low-speed offroad force does not retain old high-gear penalty");
        in.dtSeconds = 0;
        m.step(in, first);
        check(first.decision == DrivetrainModel.Decision.VANILLA && first.engineForce == 0 && !first.ownOffroad,
            "zero dt clears prior nonzero offroad result before reuse");
        in.dtSeconds = 0.02;
        in.currentGear = 0;
        in.engineRpm = 800;
        in.speedMps = 0;
        m.step(in, first);
        model().step(in, third);
        near(first.engineForce, third.engineForce, 0, "zero-dt recovery starts a fresh launch ramp");
        near(first.engineRpm, third.engineRpm, 0, "zero-dt recovery uses current original RPM");
        check(first.gear == third.gear, "zero-dt recovery does not reuse old high gear");
    }

    private static void traitsAndIndependentVehicles() {
        DrivetrainModel.Input in = input();
        DrivetrainModel.Output normal = new DrivetrainModel.Output();
        DrivetrainModel.Output slow = new DrivetrainModel.Output();
        step(model(), in, normal, 3);
        in.sundayDriver = true;
        step(model(), in, slow, 3);
        near(slow.engineForce / normal.engineForce, 0.75, 1e-9, "Sunday Driver forward power preserved");
        in.direction = in.currentGear = -1;
        in.sundayDriver = false;
        step(model(), in, normal, 3);
        in.sundayDriver = true;
        step(model(), in, slow, 3);
        near(slow.engineForce / normal.engineForce, 0.70, 1e-9, "Sunday Driver reverse power preserved");
        in.speedMps = -16.5 / 3.6;
        step(model(), in, slow, 1);
        near(slow.engineForce, 0, 0, "Sunday Driver reverse cap");
        in.direction = 1;
        in.currentGear = CAR.gearCount;
        in.sundayDriver = false;
        in.speedDemon = true;
        in.speedMps = 128 / 3.6;
        step(model(), in, normal, 3);
        check(normal.engineForce > 0, "Speed Demon extra speed is not preempted by an unadjusted RPM proxy");
        in.speedMps = 161 / 3.6;
        step(model(), in, normal, 3);
        near(normal.engineForce, 0, 0, "Speed Demon still has a finite speed cap");
        DrivetrainModel first = model();
        DrivetrainModel second = model();
        DrivetrainModel.Input a = input();
        DrivetrainModel.Input b = input();
        b.direction = b.currentGear = -1;
        DrivetrainModel.Output oa = new DrivetrainModel.Output();
        DrivetrainModel.Output ob = new DrivetrainModel.Output();
        for (int i = 0; i < 100; i++) {
            first.step(a, oa);
            second.step(b, ob);
        }
        check(oa.engineForce > 0 && ob.engineForce < 0, "instances with same profile have independent state");
        second.reset();
        first.step(a, oa);
        check(oa.throttle == 1, "other vehicle reset cannot reset first vehicle");
    }

    private static void forwardBaseEnvelopeAtProxyRpm() {
        // These compare the inspected B42 base force formula, not its separate >6000 RPM fade,
        // at the SAME output RPM/speed, retaining the original first-speed force floor.
        // They do not establish native acceleration or equality of the two gear/RPM trajectories.
        for (String family : new String[]{"generic", "van", "jeep", "firebird"}) {
            for (int count = 3; count <= 5; count++) {
                for (double maximum : new double[]{40, 120, 300}) {
                    VehicleProfile p = VehicleProfile.resolve(family, count, maximum);
                    for (double fraction : new double[]{0, 0.05, 0.15, 0.3, 0.5, 0.75, 0.9, 1.0}) {
                        DrivetrainModel.Input in = input(); in.profile = p; in.currentGear = 0;
                        in.speedMps = maximum * fraction / 3.6;
                        DrivetrainModel.Output out = new DrivetrainModel.Output();
                        step(model(), in, out, 3);
                        check(out.decision == DrivetrainModel.Decision.APPLIED, "supported baseline profile applies");
                        double original = in.enginePower * (out.gear == 1 || maximum * fraction < maximum / count ? 1.5 : 1.0)
                            * (0.30 + out.engineRpm / 30000.0) * Math.max(0.0, 1.0 - maximum * fraction / 200.0);
                        check(out.engineForce >= original - 1e-8 && out.engineForce <= original * 1.10 + 1e-8,
                            "settled road force retains the proxy-RPM base formula through +10% modulation: " + family + "/" + count + "/" + fraction);
                    }
                }
            }
        }
        DrivetrainModel.Input in = input(); in.currentGear = 4; in.speedMps = 114.0 / 3.6;
        DrivetrainModel.Output out = new DrivetrainModel.Output();
        step(model(), in, out, 3);
        check(out.engineForce > in.enginePower * 0.18, "95% reference-speed force no longer suffers old ratio and double fade");
        in.speedMps = 140.0 / 3.6;
        step(model(), in, out, 3);
        near(out.engineForce, 0, 0, "forward propulsion has finite reference-plus-20 cutoff");

        in = input(); in.direction = in.currentGear = -1;
        DrivetrainModel.Output reverse = new DrivetrainModel.Output();
        step(model(), in, reverse, 3);
        DrivetrainConfig forwardOnly = DrivetrainConfig.parse(Map.of("low_gear_boost", "1.6", "forward_governor_start_fraction", "0.75", "torque_enabled", "false"));
        in.profile = VehicleProfile.resolve("generic", 4, 120, forwardOnly);
        step(new DrivetrainModel(forwardOnly), in, out, 3);
        near(out.engineForce, reverse.engineForce, 1e-9, "forward-only tuning does not scale reverse force");
    }

    private static void forwardTraitAndLimitParity() {
        // Independent base-envelope checks, excluding the original >6000 RPM fade and gear/RPM loop.
        // Sunday Driver has an intentional >1 multiplier and composes with the ordinary limiter.
        for (double maximum : new double[]{40, 65, 120}) {
            for (int count = 3; count <= 5; count++) {
                for (int traits = 0; traits < 4; traits++) {
                    double sundayCut = maximum * 0.75 + 20, fastStart = maximum * 1.15;
                    for (double speed : new double[]{0, maximum * 0.27, maximum * 0.6 - 0.01,
                            maximum * 0.6, maximum * 0.6 + 0.01, maximum * 0.75 - 0.01, maximum * 0.75,
                            maximum - 0.01, maximum, maximum + 0.01, sundayCut - 0.01, sundayCut, sundayCut + 0.01,
                            maximum + 19.99, maximum + 20, maximum + 20.01,
                            fastStart - 0.01, fastStart, fastStart + 0.01, fastStart + 19.99, fastStart + 20, fastStart + 20.01}) {
                        DrivetrainModel.Input in = input(); in.profile = VehicleProfile.resolve("generic", count, maximum);
                        in.currentGear = 0; in.speedMps = speed / 3.6;
                        in.sundayDriver = (traits & 1) != 0; in.speedDemon = (traits & 2) != 0;
                        DrivetrainModel.Output out = new DrivetrainModel.Output(); step(model(), in, out, 3);
                        double baseline = forwardBaseEnvelope(in, out.engineRpm, out.gear);
                        check(out.decision == DrivetrainModel.Decision.APPLIED && Double.isFinite(out.engineForce) && out.engineForce >= 0,
                            "forward threshold/trait matrix never reverses force");
                        check(out.engineForce >= baseline - 1e-7 && out.engineForce <= baseline * 1.10 + 1e-7,
                            "forward linear limit and independent trait factors: " + maximum + "/" + count + "/" + traits + "/" + speed);
                    }
                }
            }
        }
        DrivetrainModel.Input in = input(); in.profile = VehicleProfile.resolve("generic", 3, 120);
        in.speedMps = 36 / 3.6;
        DrivetrainModel.Output out = new DrivetrainModel.Output(); step(model(), in, out, 3);
        check(out.gear == 2 && out.engineForce >= forwardBaseEnvelope(in, out.engineRpm, 1) - 1e-7,
            "earlier model upshift cannot erase the original first-speed force range");

        // Isolate the limiter from the RPM curve so its linear shape is checked without conflation.
        for (boolean fast : new boolean[]{false, true}) {
            double start = CAR.maxSpeedKph * (fast ? 1.15 : 1.0), previous = 1;
            for (int offset = 0; offset <= 21; offset++) {
                in = input(); in.speedDemon = fast; in.speedMps = (start + offset) / 3.6;
                step(model(), in, out, 3);
                double noGovernor = in.enginePower * (0.30 + out.engineRpm / 30000.0)
                    * Math.max(0, 1 - Math.abs(in.speedMps) * 3.6 / 200.0) * CAR.forwardTorqueModulation(out.engineRpm);
                double factor = out.engineForce / noGovernor;
                near(factor, Math.max(0, (20.0 - offset) / 20.0), 1e-8, "normal/Speed Demon high-speed fade is linear");
                check(factor >= -1e-12 && factor <= previous + 1e-12, "forward high-speed fade never adds thrust as speed increases");
                previous = factor;
            }
        }
    }

    private static double forwardBaseEnvelope(DrivetrainModel.Input in, double rpm, int outputGear) {
        double speed = Math.abs(in.speedMps) * 3.6, maximum = in.profile.maxSpeedKph;
        boolean firstRange = outputGear == 1 || speed < maximum / in.profile.gearCount;
        double force = in.enginePower * (firstRange ? 1.5 : 1.0) * (0.30 + rpm / 30000.0)
            * Math.max(0, 1 - speed / 200.0);
        if (in.sundayDriver) {
            force *= 0.75;
            if (speed > maximum * 0.6) force *= Math.max(0, (maximum * 0.75 + 20 - speed) / 20);
        }
        double reference = maximum * (in.speedDemon ? 1.15 : 1);
        if (speed > reference) force *= Math.max(0, (reference + 20 - speed) / 20);
        return force;
    }

    private static void rollingReentryAndReverseOverrev() {
        for (int count = 3; count <= 5; count++) {
            DrivetrainModel.Input in = input(); in.profile = VehicleProfile.resolve("generic", count, 120);
            in.currentGear = 0; in.engineRpm = 800; in.speedMps = 100.0 / 3.6;
            DrivetrainModel m = model(); DrivetrainModel.Output out = new DrivetrainModel.Output();
            m.step(in, out);
            check(out.gear == count && out.engineForce > 0, "rolling neutral reentry directly chooses safe top gear");
            for (int i = 0; i < 60; i++) {
                m.step(in, out);
                check(out.gear == count, "reentry has no 1-to-top shift-hold staircase");
            }
            in.speedMps = 8.0 / 3.6;
            step(m, in, out, 3);
            check(out.gear == 1, "held-demand slowdown still kicks down after direct reentry");
            m.reset(); in.currentGear = 0; in.speedMps = 60.0 / 3.6; in.engineRpm = 800;
            m.step(in, out);
            check(out.gear > 1 && (out.gear == count || in.profile.coupledRpm(in.speedMps, out.gear) <= in.profile.redlineRpm * 0.82),
                "coast/reset reacquires from current road speed, not stored high or low gear");
        }
        DrivetrainConfig c = DrivetrainConfig.parse(Map.of("reverse_max_speed_kph", "35"));
        for (String family : new String[]{"generic", "van", "jeep", "firebird"}) {
            for (double maximum : new double[]{20, 120, 300}) {
                DrivetrainModel.Input in = input(); in.profile = VehicleProfile.resolve(family, 4, maximum, c);
                in.direction = in.currentGear = -1;
                for (double speed : new double[]{0, 5, 26.25, 35, 52.5, 100}) {
                    in.speedMps = -speed / 3.6;
                    DrivetrainModel.Output out = new DrivetrainModel.Output();
                    step(new DrivetrainModel(c), in, out, 3);
                    check(out.decision == DrivetrainModel.Decision.APPLIED && out.engineRpm <= in.profile.redlineRpm * 0.90 + 1e-8,
                        "independent reverse RPM coupling never over-revs a slow/fast forward profile");
                    if (speed < 35) check(out.engineForce < 0, "reverse does not lose force early through forward first-gear over-rev");
                    else near(out.engineForce, 0, 0, "reverse overspeed only cuts propulsion");
                }
            }
        }
        double forward30 = rollingIntegral(30), forward60 = rollingIntegral(60), forward144 = rollingIntegral(144);
        near(forward30 / forward60, 1, 0.03, "30/60 Hz rolling reentry impulse agrees within model tolerance");
        near(forward144 / forward60, 1, 0.03, "144/60 Hz rolling reentry impulse agrees within model tolerance");
    }

    private static double rollingIntegral(int hz) {
        DrivetrainModel m = model(); DrivetrainModel.Input in = input();
        in.currentGear = 0; in.speedMps = 100.0 / 3.6; in.dtSeconds = 1.0 / hz;
        DrivetrainModel.Output out = new DrivetrainModel.Output(); double total = 0;
        for (int i = 0; i < hz * 2; i++) { m.step(in, out); total += out.engineForce * in.dtSeconds; }
        return total;
    }

    private static void timePartitionAndLongRunning() {
        double integral30 = launchIntegral(30);
        double integral60 = launchIntegral(60);
        double integral144 = launchIntegral(144);
        near(integral30 / integral60, 1, 0.03, "30/60 Hz launch impulse agrees within model tolerance");
        near(integral144 / integral60, 1, 0.03, "144/60 Hz launch impulse agrees within model tolerance");
        DrivetrainModel m = model();
        DrivetrainModel.Input in = input();
        DrivetrainModel.Output out = new DrivetrainModel.Output();
        in.direction = in.currentGear = -1;
        for (int i = 0; i < 50000; i++) {
            m.step(in, out);
            check(Double.isFinite(out.engineForce) && Double.isFinite(out.engineRpm), "long blocked throttle does not accumulate infinite energy");
            check(-out.engineForce <= in.enginePower, "long blocked throttle preserves baseline force bound");
        }
    }

    private static double launchIntegral(int hz) {
        DrivetrainModel m = model();
        DrivetrainModel.Input in = input();
        DrivetrainModel.Output out = new DrivetrainModel.Output();
        in.direction = in.currentGear = -1;
        in.dtSeconds = 1.0 / hz;
        double total = 0;
        for (int i = 0; i < hz * 2; i++) { m.step(in, out); total += -out.engineForce * in.dtSeconds; }
        return total;
    }

    private static DrivetrainModel model() { return new DrivetrainModel(DrivetrainConfig.defaults()); }
    private static DrivetrainModel.Input input() {
        DrivetrainModel.Input in = new DrivetrainModel.Input();
        in.profile = CAR;
        in.dtSeconds = 0.02;
        in.enginePower = 4000;
        in.engineRpm = 800;
        in.reverseMaxSpeedKph = 40.0 / 1.5;
        in.throttle = 1;
        return in;
    }
    private static void step(DrivetrainModel m, DrivetrainModel.Input in, DrivetrainModel.Output out, double seconds) {
        int n = (int)Math.ceil(seconds / in.dtSeconds);
        for (int i = 0; i < n; i++) m.step(in, out);
    }
    private static void reject(Map<String, String> values) {
        try { DrivetrainConfig.parse(values); throw new AssertionError("Expected invalid settings: " + values); }
        catch (IllegalArgumentException expected) { checks++; }
    }
    private static void check(boolean condition, String message) {
        checks++;
        if (!condition) throw new AssertionError(message);
    }
    private static void near(double actual, double expected, double tolerance, String message) {
        check(Double.isFinite(actual) && Math.abs(actual - expected) <= tolerance,
            message + ": actual=" + actual + ", expected=" + expected + ", tolerance=" + tolerance);
    }
}
