package pztools.bridge.runtime;

import pztools.bridge.AgentEntry;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * The frame router: its jobs run in their order, one that throws leaves the others, the bootstrap's slot is held while
 * any job is and refused to a new holder while a payload switch waits; and the game's state is read once per frame.
 */
final class FramesTest {
    private FramesTest() { }

    static void run() throws Exception {
        orderAndIsolation();
        slotFollowsTheJobs();
        oneReadPerFrame();
        System.out.println("PASS: frame router order, job isolation, bootstrap slot and switch, one state read per frame");
    }

    private static void orderAndIsolation() {
        var order = new ArrayList<String>();
        Object api = new Object(), observer = new Object(), lifecycle = new Object();
        // Added out of order: they run in the router's.
        check(Frames.add(Frames.Job.LIFECYCLE, lifecycle, () -> order.add("lifecycle")), "Lifecycle job refused");
        check(Frames.add(Frames.Job.OBSERVER, observer, () -> order.add("observer")), "Observer job refused");
        var apiRuns = new AtomicInteger();
        check(Frames.add(Frames.Job.API, api, () -> { apiRuns.incrementAndGet(); order.add("api"); }), "API job refused");
        check(!Frames.add(Frames.Job.LIFECYCLE, new Object(), () -> { }), "A held job was given to another owner");
        try {
            AgentEntry.poll();
            check(order.equals(List.of("api", "observer", "lifecycle")), "Jobs ran out of order: " + order);

            // A job that throws is dropped; the others go on, and its owner still holds it.
            order.clear();
            check(Frames.add(Frames.Job.API, api, () -> { apiRuns.incrementAndGet(); throw new LinkageError("synthetic"); }),
                "The owner could not replace its own job");
            AgentEntry.poll();
            AgentEntry.poll();
            check(apiRuns.get() == 2 && order.equals(List.of("observer", "lifecycle", "observer", "lifecycle")),
                "A failing job stopped the others or kept running: " + order);
            check(Frames.holds(Frames.Job.API, api) && !Frames.add(Frames.Job.API, new Object(), () -> { }),
                "A dropped job was taken from its owner");
        } finally {
            Frames.remove(Frames.Job.API, api);
            Frames.remove(Frames.Job.OBSERVER, observer);
            Frames.remove(Frames.Job.LIFECYCLE, lifecycle);
        }
        check(AgentEntry.diagnostics().contains("framesActive=false"), "The router kept the bootstrap's slot with no job");
    }

    /** What a payload switch relies on: once the router has let go, nothing new takes the slot until the switch ends. */
    private static void slotFollowsTheJobs() throws Exception {
        var pause = Class.forName("pztools.bridge.GameHook").getDeclaredField("paused");
        pause.setAccessible(true);
        Object first = new Object(), second = new Object();
        var runs = new AtomicInteger();
        check(Frames.add(Frames.Job.OBSERVER, first, runs::incrementAndGet), "Observer job refused");
        check(AgentEntry.diagnostics().contains("framesActive=true"), "The router did not take the bootstrap's slot");
        try {
            pause.setBoolean(null, true);
            AgentEntry.poll();
            check(runs.get() == 0, "A paused game loop ran a job");
            // Held already: another job may still come (the switch then waits for it to go too).
            check(Frames.add(Frames.Job.NOTICES, second, () -> { }), "A job was refused to a router that holds the slot");
            Frames.remove(Frames.Job.NOTICES, second);
            Frames.remove(Frames.Job.OBSERVER, first);
            check(AgentEntry.diagnostics().contains("framesActive=false"), "The last job's end kept the slot");
            check(!Frames.add(Frames.Job.OBSERVER, first, runs::incrementAndGet), "A job took the slot during a switch");
            check(!AgentEntry.acquire(second, () -> { }), "A request took the game thread during a switch");
            pause.setBoolean(null, false);
            check(Frames.add(Frames.Job.OBSERVER, first, runs::incrementAndGet), "A job was refused after the switch");
            AgentEntry.poll();
            check(runs.get() == 1, "The job did not run after the switch");
        } finally {
            pause.setBoolean(null, false);
            Frames.remove(Frames.Job.OBSERVER, first);
        }
    }

    /** The observer and the extension lifecycle share one adapter, read once in a frame of the router. */
    private static void oneReadPerFrame() throws Exception {
        zombie.GameWindow.mode = "normal"; zombie.GameWindow.gameThread = Thread.currentThread();
        zombie.ZomboidFileSystem.path = "synthetic-world";
        var adapter = PzRuntimeAdapter.of(zombie.GameWindow.class);
        check(PzRuntimeAdapter.of(zombie.GameWindow.class) == adapter, "Each reader made its own adapter");
        Object before = zombie.iso.IsoWorld.instance.currentCell, later = new Object();
        var seen = new ArrayList<Object>();
        Object first = new Object(), second = new Object();
        check(Frames.add(Frames.Job.OBSERVER, first, () -> {
            try { adapter.read(); } catch (ReflectiveOperationException failure) { throw new AssertionError(failure); }
            seen.add(adapter.worldCell);
            // Changed between the two readers of one frame: the second still sees what the frame read.
            zombie.iso.IsoWorld.instance.currentCell = later;
        }), "Observer job refused");
        check(Frames.add(Frames.Job.LIFECYCLE, second, () -> {
            try { adapter.read(); } catch (ReflectiveOperationException failure) { throw new AssertionError(failure); }
            seen.add(adapter.worldCell);
        }), "Lifecycle job refused");
        try {
            AgentEntry.poll();
            check(seen.size() == 2 && seen.get(0) == before && seen.get(1) == before, "The frame's two readers read twice: " + seen);
            // The next frame reads again; outside a frame every read is fresh.
            AgentEntry.poll();
            check(seen.get(2) == later, "The next frame kept the last frame's read");
            zombie.iso.IsoWorld.instance.currentCell = before;
            adapter.read();
            check(adapter.worldCell == before, "A read outside the router's frame was not fresh");
        } finally {
            zombie.iso.IsoWorld.instance.currentCell = before;
            Frames.remove(Frames.Job.OBSERVER, first);
            Frames.remove(Frames.Job.LIFECYCLE, second);
        }
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
