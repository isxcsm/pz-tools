package pztools.extensions.vehicle.model;

import java.util.Map;

/** Pure JVM contract tests. Passing these does not establish native-force units or in-game handling. */
public final class DrivetrainModelTest {
    private static int checks;
    private static final VehicleProfile CAR = VehicleProfile.resolve("generic", 4, 120.0);

    public static void main(String[] args) {
        configurationAndProfiles();
        boundedProfileTuning();
        finiteInputsAndRecovery();
        reverseRampAndGovernor();
        directionTransitionAndReset();
        automaticGearsAndLowMode();
        allGearSpacingsAvoidHunting();
        equalCouplingForceAndOffroadRecovery();
        forwardBaselineEnvelope();
        rollingReentryAndReverseOverrev();
        commonCurveAndSurfaceOwnership();
        traitsAndIndependentVehicles();
        timePartitionAndLongRunning();
        System.out.println("PASS: " + checks + " vehicle drivetrain model assertions (game-free; experimental calibration)");
    }

    private static void configurationAndProfiles() {
        DrivetrainConfig c = DrivetrainConfig.defaults();
        near(c.lowGearBoost, 1.0, 0.0, "no default extra launch boost");
        near(c.reverseForceRatio, 0.85, 0.0, "reverse retains low-speed torque");
        near(c.reverseMaxSpeedKph, 22.0, 0.0, "reverse range is independent from its retained launch ramp");
        near(c.forwardGovernorStartFraction, 1.0, 0.0, "forward governor does not preempt the reference speed");
        check(c.torqueEnabled && c.reverseEnabled && c.steeringEnabled, "independent options default on within the disabled module");
        near(c.steeringHighSpeedRateFactor, 0.6, 0.0, "high-speed steering rate defaults to moderate independent reduction");
        near(c.maxDtSeconds, 0.1, 0.0, "bounded timestep");
        check(!c.lowMode, "low mode opt in");
        reject(Map.of("force_scale", "NaN"));
        reject(Map.of("force_scale", "Infinity"));
        reject(Map.of("force_scale", "0"));
        reject(Map.of("reverse_force_ratio", "0.3"));
        reject(Map.of("reverse_max_speed_kph", "36"));
        reject(Map.of("torque_enabled", "yes"));
        reject(Map.of("reverse_enabled", "1"));
        reject(Map.of("steering_enabled", "TRUE"));
        reject(Map.of("steering_initial_rate", "3.1"));
        reject(Map.of("steering_full_rate", "0.4"));
        reject(Map.of("steering_ramp_seconds", "0.04"));
        reject(Map.of("steering_return_rate", "10.1"));
        reject(Map.of("steering_countersteer_rate", "NaN"));
        reject(Map.of("steering_high_speed_rate_factor", "0.19"));
        reject(Map.of("steering_high_speed_rate_factor", "1.01"));
        reject(Map.of("steering_high_speed_rate_factor", "NaN"));
        near(DrivetrainConfig.parse(Map.of("steering_high_speed_rate_factor", "0.2")).steeringHighSpeedRateFactor, 0.2, 0.0, "high-speed steering factor lower bound");
        near(DrivetrainConfig.parse(Map.of("steering_high_speed_rate_factor", "1")).steeringHighSpeedRateFactor, 1.0, 0.0, "high-speed steering factor can retain full response");
        reject(Map.of("steering_initial_rate", "3", "steering_full_rate", "2.5"));
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
                {"forward_governor_start_fraction", "1.01"}, {"reverse_governor_start_fraction", "1"},
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
            DrivetrainModel.speedGovernor(17.6, 11, 22) / DrivetrainModel.speedGovernor(17.6, 16.5, 22), 1e-9,
            "configured reverse governor onset is used exactly once");
    }

    private static void reverseRampAndGovernor() {
        DrivetrainModel m = model();
        DrivetrainModel.Input in = input();
        DrivetrainModel.Output out = new DrivetrainModel.Output();
        in.direction = in.currentGear = -1;
        in.engineRpm = 6500;
        double cap = in.enginePower * 0.65 * 0.85;
        double previous = 0;
        for (int i = 0; i < 100; i++) {
            m.step(in, out);
            check(out.decision == DrivetrainModel.Decision.APPLIED && out.gear == -1, "reverse applies consistent gear");
            check(out.engineForce <= 0 && -out.engineForce <= cap + 1e-9, "reverse bounded and signed");
            check(-out.engineForce - previous <= cap / 0.8 * in.dtSeconds + 1e-8, "delivered reverse rise is limited");
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
        for (double speed : new double[]{22, 35, 100, 500}) {
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
        check(-out.engineForce <= in.enginePower * 0.65 * 0.85 / 0.8 * in.dtSeconds, "old forward RPM cannot bypass reverse ramp");
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

    private static void forwardBaselineEnvelope() {
        // These are candidate force-unit comparisons against the inspected B42 control_ForwardNew
        // formula at the SAME output RPM/gear/speed. They do not establish native acceleration.
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
                        double original = in.enginePower * (out.gear == 1 ? 1.5 : 1.0)
                            * (0.30 + out.engineRpm / 30000.0) * Math.max(0.0, 1.0 - maximum * fraction / 200.0);
                        check(out.engineForce >= original * 0.90 - 1e-8 && out.engineForce <= original * 1.10 + 1e-8,
                            "settled road force stays within +/-10% of same-state baseline: " + family + "/" + count + "/" + fraction);
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
            check(-out.engineForce <= in.enginePower * 0.65 * 0.85, "long blocked throttle preserves force bound");
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
