package pztools.extensions.runtime;

import pztools.extensions.api.*;
import java.nio.file.Path;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Two continuous modules in one host, through the host's real loading path and two synthetic
 * module archives. What is checked is independence: applying, updating, faulting and retiring one
 * module leaves the other's generation, revision and activity exactly as they were.
 */
public final class ModuleSlotsTest {
    private static final String VEHICLE = "pztools.vehicle-drivetrain", LOOK = "pztools.screen-look";

    public static void main(String[] args) throws Exception {
        if (args.length != 1) throw new IllegalArgumentException("directory with catalog.tsv and both fixture archives required");
        var host = new ModuleHost(Path.of(args[0]));
        ClassLoader game = ModuleSlotsTest.class.getClassLoader();
        String process = RuntimeIdentity.processId(), world = "a".repeat(32);
        var context = new ContinuousProvider.Context(process, world, new Object(), Thread.currentThread(), game, new AtomicBoolean(true));

        check(host.status(VEHICLE).state().equals("Disabled") && host.status(LOOK).state().equals("Disabled"), "nothing runs before it is asked for");
        check(apply(host, game, process, world, VEHICLE, -1, 1, Map.of("fixture_value", "drive")).state().equals("Pending"), "vehicle accepted");
        check(apply(host, game, process, world, LOOK, -1, 2, Map.of("fixture_value", "look")).state().equals("Pending"), "look accepted beside it");
        host.tick(context);
        var vehicle = host.status(VEHICLE); var look = host.status(LOOK);
        check(vehicle.state().equals("Active") && vehicle.appliedRevision() == 1 && look.state().equals("Active") && look.appliedRevision() == 2,
            "both active at their own revisions: " + vehicle + " / " + look);
        check(!vehicle.generation().equals(look.generation()), "each has its own generation");
        check(vehicle.diagnostics().contains("fixtureValue=drive") && look.diagnostics().contains("lookValue=look"), "each got its own configuration");
        for (int i = 0; i < 3; i++) host.tick(context);
        check(number(host.status(VEHICLE), "fixtureFrames") >= 3 && number(host.status(LOOK), "lookFrames") >= 3, "both are called every frame");

        // The settings revision is shared. A change made for another module arrives here as a new
        // revision of the same configuration: acknowledged at once, and the module is not disturbed.
        var same = apply(host, game, process, world, LOOK, 2, 3, Map.of("fixture_value", "look"));
        check(same.state().equals("Active") && same.appliedRevision() == 3 && same.generation().equals(look.generation()), "identical configuration is acknowledged without waiting: " + same);
        host.tick(context);
        check(number(host.status(LOOK), "lookUpdates") == 0, "and never reaches the provider");

        var changed = apply(host, game, process, world, LOOK, 3, 4, Map.of("fixture_value", "stronger"));
        check(changed.state().equals("Pending") && changed.appliedRevision() == 3, "a real change waits for the game thread");
        check(host.status(VEHICLE).state().equals("Active") && host.status(VEHICLE).appliedRevision() == 1, "the other module is not pending because of it");
        host.tick(context);
        look = host.status(LOOK);
        check(look.state().equals("Active") && look.appliedRevision() == 4 && look.diagnostics().contains("lookValue=stronger")
            && number(look, "lookUpdates") == 1, "applied to its own module: " + look);
        check(apply(host, game, process, world, LOOK, 2, 5, Map.of()).reason().equals("revision-conflict"), "a stale expectation is refused per module");
        check(host.status(VEHICLE).generation().equals(vehicle.generation()) && host.status(VEHICLE).appliedRevision() == 1, "the vehicle module was never touched");

        // One module faults: it alone goes to pass-through.
        apply(host, game, process, world, LOOK, 4, 6, Map.of("fixture_fail", "true"));
        host.tick(context); host.tick(context);
        look = host.status(LOOK);
        check(look.state().equals("FaultedPassThrough") && look.reason().equals("provider-failed:fixture-failed"), "the faulted module reports its own fault: " + look);
        long before = number(host.status(VEHICLE), "fixtureFrames");
        host.tick(context);
        check(host.status(VEHICLE).state().equals("Active") && number(host.status(VEHICLE), "fixtureFrames") == before + 1, "the healthy module keeps running");
        check(host.status().state().equals("Disabled"), "the host itself is not at fault");

        // One module is turned off: the other keeps its generation and carries on.
        check(host.deactivate(LOOK, "user-disabled").state().equals("Disabled") && host.status(LOOK).appliedRevision() == -1, "look retired");
        host.tick(context);
        check(host.status(VEHICLE).state().equals("Active") && host.status(VEHICLE).generation().equals(vehicle.generation()), "vehicle unaffected by the other's retirement");
        check(apply(host, game, process, world, LOOK, -1, 7, Map.of("fixture_value", "again")).state().equals("Pending"), "a retired module can be applied again");
        host.tick(context);
        check(host.status(LOOK).state().equals("Active") && !host.status(LOOK).generation().equals(look.generation()), "as a fresh generation");

        // A lost lease or a changed world concerns them all.
        host.revoke("world-changed");
        check(host.status(VEHICLE).state().equals("Disabled") && host.status(LOOK).state().equals("Disabled"), "revocation reaches every module");
        check(host.deactivate("connection-ended").state().equals("Disabled"), "everything retires cleanly");

        check(apply(host, game, process, world, "pztools.unknown-module", -1, 8, Map.of()).state().equals("Unsupported"), "an uncatalogued module is refused");
        check(host.status("pztools.unknown-module").state().equals("Unsupported") || host.status("pztools.never-applied").state().equals("Disabled"), "and asking about one is harmless");
        host.close();
        System.out.println("PASS module slots: two modules active together, shared-revision no-op, per-module update, fault and retirement, host-wide revocation");
    }

    private static ContinuousModules.Status apply(ModuleHost host, ClassLoader game, String process, String world, String module,
                                                  long expected, long revision, Map<String, String> config) {
        return host.apply(new ContinuousModules.Apply(process, world, expected, revision, module, false, config), null, game, "42.0");
    }
    private static long number(ContinuousModules.Status status, String key) {
        for (String field : status.diagnostics().split(";")) if (field.startsWith(key + "=")) return Long.parseLong(field.substring(key.length() + 1));
        throw new AssertionError("missing " + key + " in " + status.diagnostics());
    }
    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
