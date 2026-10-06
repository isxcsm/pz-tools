package pztools.bridge.runtime;

import pztools.extensions.api.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;

/** The resident controller of a game the startup loader started: what it reads, what it asks for, what it leaves. */
final class ResidentExtensionsTest {
    private ResidentExtensionsTest() { }

    static void run() throws Exception {
        Path folder = Files.createTempDirectory("pztools-resident-test");
        try {
            desiredFile(folder);
            residentSessionKeepsModules();
            reconcile(folder);
        } finally {
            try (var files = Files.list(folder)) { for (Path file : files.toList()) Files.delete(file); }
            Files.delete(folder);
        }
        System.out.println("PASS: resident extensions read the app's file, apply once per world and revision, and keep modules on handover");
    }

    private static final String CONFIG = Base64.getEncoder().encodeToString("force_scale\t1.25\n".getBytes(StandardCharsets.UTF_8));

    private static void write(Path folder, String text) throws Exception {
        Files.writeString(folder.resolve(ResidentExtensions.DESIRED), text, StandardCharsets.UTF_8);
    }

    private static void desiredFile(Path folder) throws Exception {
        check(ResidentExtensions.readDesired(folder) == null, "A missing file was read as a request");
        write(folder, "PZTOOLS-RESIDENT\t1\nrevision\t7\nmodule\tpztools.first-module\ton\tforce\t" + CONFIG
            + "\nmodule\tpztools.second-module\toff\tnormal\t\n");
        var desired = ResidentExtensions.readDesired(folder);
        check(desired != null && desired.revision() == 7 && desired.modules().equals(List.of(
            new ResidentExtensions.Module("pztools.first-module", true, true, CONFIG),
            new ResidentExtensions.Module("pztools.second-module", false, false, ""))), "The app's file was misread");
        // Windows line ends are the same file.
        write(folder, "PZTOOLS-RESIDENT\t1\r\nrevision\t7\r\nmodule\tpztools.first-module\ton\tnormal\t" + CONFIG + "\r\n");
        check(ResidentExtensions.readDesired(folder) != null, "CRLF line ends were refused");
        for (String invalid : List.of("PZTOOLS-RESIDENT\t2\nrevision\t1\n", "PZTOOLS-RESIDENT\t1\nrevision\t-1\n",
                "PZTOOLS-RESIDENT\t1\nrevision\t1\nmodule\tNot.A.Module\ton\tnormal\t\n",
                "PZTOOLS-RESIDENT\t1\nrevision\t1\nmodule\tpztools.a-b\ton\tnormal\t\nmodule\tpztools.a-b\toff\tnormal\t\n",
                "PZTOOLS-RESIDENT\t1\nrevision\t1\nmodule\tpztools.a-b\tmaybe\tnormal\t\n",
                "PZTOOLS-RESIDENT\t1\nrevision\t1\nmodule\tpztools.a-b\ton\tnormal\tnot base64!\n")) {
            write(folder, invalid);
            check(ResidentExtensions.readDesired(folder) == null, "An invalid file was read as a request: " + invalid);
        }
    }

    /** The resident's own session has no lease; an app's session in such a game hands the modules on when it ends. */
    private static void residentSessionKeepsModules() throws Exception {
        var clock = new AtomicLong(100);
        var modules = new Modules();
        var resident = new ExtensionControl.Session(null, zombie.GameWindow.class, clock::get, () -> modules,
            ExtensionControl::residentHostAbi, false, true);
        resident.command("STATUS\ts1\t" + "a".repeat(32));
        clock.addAndGet(TimeUnit.SECONDS.toNanos(60));
        check(!resident.expired(), "The resident controller's session expired like a lease");
        resident.close();
        check(modules.revokes == 0 && modules.off.isEmpty() && modules.closes == 0, "A resident session's end withdrew the modules");

        var app = new ExtensionControl.Session(null, zombie.GameWindow.class, clock::get, () -> modules,
            ExtensionControl::residentHostAbi, true, true);
        app.command("STATUS\ts1\t" + "b".repeat(32));
        clock.addAndGet(TimeUnit.SECONDS.toNanos(6));
        check(app.expired(), "An app's session in a resident game lost its lease");
        app.poll();
        app.close();
        check(modules.revokes == 0 && modules.closes == 0, "An app's lapsed lease withdrew modules the resident controller takes back");
    }

    private static void reconcile(Path folder) throws Exception {
        zombie.GameWindow.mode = "normal"; zombie.GameWindow.gameThread = Thread.currentThread();
        zombie.ZomboidFileSystem.path = "synthetic-world";
        zombie.ui.UIManager.getSpeedControls().SetCurrentGameSpeed(1);
        var modules = new Modules();
        var session = new ExtensionControl.Session(null, zombie.GameWindow.class, System::nanoTime, () -> modules,
            ExtensionControl::residentHostAbi, false, true);
        var controller = new ResidentExtensions.Controller();
        try {
            write(folder, "PZTOOLS-RESIDENT\t1\nrevision\t5\nmodule\tpztools.first-module\ton\tnormal\t" + CONFIG
                + "\nmodule\tpztools.second-module\toff\tnormal\t\n");
            check(controller.reconcile(session, folder) && modules.applies.isEmpty(), "Applied before a world was loaded");
            session.poll();
            String world = session.worldId();
            check(world != null && world.equals(RuntimeIdentity.worldId(zombie.iso.IsoWorld.instance.currentCell)),
                "The session did not name the loaded world");

            modules.set("pztools.second-module", "Active", world, 4);
            check(controller.reconcile(session, folder), "A pass failed");
            var apply = modules.applies.getFirst();
            check(modules.applies.size() == 1 && apply.moduleId().equals("pztools.first-module") && apply.worldId().equals(world)
                && apply.processId().equals(RuntimeIdentity.processId()) && apply.expectedRevision() == -1 && apply.revision() == 5
                && !apply.forceVersion() && apply.config().equals(Map.of("force_scale", "1.25")), "The wanted module was not asked for: " + apply);
            check(modules.off.equals(List.of("pztools.second-module")), "A module the app has off kept running");

            // Running at the wanted revision: nothing more.
            modules.set("pztools.first-module", "Active", world, 5);
            controller.reconcile(session, folder);
            check(modules.applies.size() == 1 && modules.off.size() == 1, "A running module was asked for again");

            // Withdrawn in the same world (the game refused it, say): not asked for again until the request changes.
            modules.set("pztools.first-module", "Disabled", world, 5);
            controller.reconcile(session, folder);
            check(modules.applies.size() == 1, "A request the game withdrew was repeated in the same world");
            write(folder, "PZTOOLS-RESIDENT\t1\nrevision\t6\nmodule\tpztools.first-module\ton\tforce\t" + CONFIG + "\n");
            controller.reconcile(session, folder);
            check(modules.applies.size() == 2 && modules.applies.get(1).expectedRevision() == 5 && modules.applies.get(1).revision() == 6
                && modules.applies.get(1).forceVersion(), "A new revision was not asked for");

            // A module the game faulted in this world, or one that needs a restart, is left to the app to report.
            write(folder, "PZTOOLS-RESIDENT\t1\nrevision\t7\nmodule\tpztools.first-module\ton\tnormal\t" + CONFIG + "\n");
            modules.set("pztools.first-module", "FaultedPassThrough", world, 6);
            controller.reconcile(session, folder);
            modules.set("pztools.first-module", "RestartRequired", world, 6);
            controller.reconcile(session, folder);
            check(modules.applies.size() == 2, "A faulted module was asked for again");

            // The next world gets the module again.
            zombie.iso.IsoWorld.instance.currentCell = new Object();
            session.poll();
            check(!session.worldId().equals(world), "The new world kept the old identity");
            modules.set("pztools.first-module", "Disabled", world, 6);
            controller.reconcile(session, folder);
            check(modules.applies.size() == 3 && modules.applies.get(2).worldId().equals(session.worldId()), "The next world did not get the module");

            // Without the app's file, nothing changes.
            Files.delete(folder.resolve(ResidentExtensions.DESIRED));
            modules.set("pztools.first-module", "Disabled", session.worldId(), -1);
            check(controller.reconcile(session, folder) && modules.applies.size() == 3, "Acted without the app's file");
        } finally { session.close(); }
    }

    /** One status per module, settable; records what it was asked. */
    public static final class Modules implements ContinuousModules {
        final List<Apply> applies = new ArrayList<>();
        final List<String> off = new ArrayList<>();
        final Map<String, Status> states = new HashMap<>();
        int revokes, closes;
        void set(String module, String state, String world, long applied) {
            states.put(module, new Status(state, null, RuntimeIdentity.processId(), world, null, applied, null, null, ""));
        }
        private static Status disabled() { return new Status("Disabled", null, RuntimeIdentity.processId(), null, null, -1, null, null, ""); }
        public Status apply(Apply request, java.lang.instrument.Instrumentation i, ClassLoader l, String version) {
            applies.add(request);
            var pending = new Status("Pending", "safe-boundary", request.processId(), request.worldId(), "g", request.expectedRevision(), null, null, "");
            states.put(request.moduleId(), pending);
            return pending;
        }
        public void tick(ContinuousProvider.Context context) { }
        public void revoke(String reason) { revokes++; }
        public Status deactivate(String reason) { closes++; return disabled(); }
        public Status status() { return disabled(); }
        public Status status(String module) { return states.getOrDefault(module, disabled()); }
        public Status deactivate(String module, String reason) { off.add(module); states.put(module, disabled()); return disabled(); }
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
