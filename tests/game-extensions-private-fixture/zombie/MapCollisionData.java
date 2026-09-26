package zombie;
import java.util.concurrent.CountDownLatch;
import zombie.popman.ZombiePopulationManager;
/** All gates and writes here are synthetic; no JNI or real game files. */
public final class MapCollisionData {
    public static final MapCollisionData instance = new MapCollisionData();
    public final MCDThread thread = new MCDThread();
    public int calls, writes;
    public boolean client;
    public volatile CountDownLatch releaseNative = new CountDownLatch(0), nativeEntered = new CountDownLatch(1);
    public volatile CountDownLatch preNative = new CountDownLatch(0), preEntered = new CountDownLatch(1);
    public volatile boolean failOnce, exitWithoutAck;
    private MapCollisionData() { thread.setDaemon(true); thread.start(); }
    public void save() {
        calls++;
        if (client) return;
        ZombiePopulationManager.instance.beginSaveRealZombies();
        if (!thread.isAlive()) { n_save(); ZombiePopulationManager.instance.save(); return; }
        thread.save = true;
        synchronized (thread.notifier) { thread.notifier.notify(); }
        while (thread.save) { try { Thread.sleep(5); } catch (InterruptedException ignored) { } }
        ZombiePopulationManager.instance.endSaveRealZombies();
    }
    public void stop() {
        thread.stop = true;
        synchronized (thread.notifier) { thread.notifier.notify(); }
        while (thread.isAlive()) { try { thread.join(100); } catch (InterruptedException ignored) { } }
    }
    private static void await(CountDownLatch gate) {
        try { if (!gate.await(15, java.util.concurrent.TimeUnit.SECONDS)) throw new IllegalStateException("Fixture gate timed out"); }
        catch (InterruptedException failure) { throw new IllegalStateException(failure); }
    }
    private static void n_save() {
        instance.nativeEntered.countDown(); await(instance.releaseNative);
        if (instance.failOnce) { instance.failOnce = false; throw new IllegalStateException("Synthetic native failure"); }
        instance.writes++;
    }
    public final class MCDThread extends Thread {
        public final Object notifier = new Object();
        public volatile boolean save, stop;
        public void run() {
            while (!stop) {
                try { runInner(); } catch (Exception ignored) { }
            }
        }
        private void runInner() {
            // Models an earlier iteration's pending-cell path before this iteration reaches n_save.
            if (save && preNative.getCount() != 0) { preEntered.countDown(); await(preNative); ZombiePopulationManager.instance.processPendingSaveCells(); }
            if (save) {
                if (exitWithoutAck) { stop = true; return; }
                n_save();
                ZombiePopulationManager.instance.save();
                save = false;
            }
            ZombiePopulationManager.instance.processPendingSaveCells();
            synchronized (notifier) {
                if (!save && !stop) { try { notifier.wait(100); } catch (InterruptedException ignored) { } }
            }
        }
    }
}