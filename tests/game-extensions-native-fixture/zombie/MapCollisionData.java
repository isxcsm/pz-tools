package zombie;

import java.io.IOException;
import java.util.concurrent.CountDownLatch;
import pztools.extensions.api.GameHooks;
import zombie.popman.ZombiePopulationManager;

/** Synthetic native-worker boundary; no game libraries, game files or native calls. */
public final class MapCollisionData {
    public static MapCollisionData instance;
    public final MCDThread thread = new MCDThread();
    public boolean client;
    public final CountDownLatch entered = new CountDownLatch(1), release = new CountDownLatch(1);
    public final CountDownLatch failureLogged = new CountDownLatch(1), retry = new CountDownLatch(1);
    public volatile boolean failOnce, exitWithoutAck;
    public volatile int writes, writesAtStop = -1;
    public volatile Thread writerThread;
    public MapCollisionData() { instance = this; thread.setDaemon(true); thread.start(); }
    public void save() {
        if (client) return;
        ZombiePopulationManager.instance.beginSaveRealZombies();
        if (!thread.isAlive()) { n_save(); ZombiePopulationManager.instance.save(); return; }
        thread.save = true;
        synchronized (thread.notifier) { thread.notifier.notify(); }
        while (thread.save) { try { Thread.sleep(5); } catch (InterruptedException ignored) { } }
        ZombiePopulationManager.instance.endSaveRealZombies();
    }
    public void stop() {
        writesAtStop = writes;
        thread.stop = true;
        synchronized (thread.notifier) { thread.notifier.notify(); }
        while (thread.isAlive()) { try { Thread.sleep(5); } catch (InterruptedException ignored) { } }
    }
    private static void n_save() { instance.writerThread = Thread.currentThread(); instance.writes++; }
    public final class MCDThread extends Thread {
        public final Object notifier = new Object();
        public volatile boolean save, stop;
        public void run() {
            try {
                while (!stop) {
                    if (save) {
                        entered.countDown(); release.await();
                        if (exitWithoutAck) return;
                        if (failOnce) {
                            failOnce = false;
                            GameHooks.error("pztools.save.error.v1", new IOException("Synthetic native save failure"));
                            failureLogged.countDown(); retry.await();
                        }
                        n_save(); ZombiePopulationManager.instance.save();
                        save = false; // Release publication after BOTH original write operations.
                    }
                    Thread.sleep(1);
                }
            } catch (InterruptedException unexpected) { throw new AssertionError(unexpected); }
        }
    }
}
