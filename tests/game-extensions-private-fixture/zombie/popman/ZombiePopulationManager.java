package zombie.popman;
import java.util.concurrent.locks.ReentrantLock;
public class ZombiePopulationManager {
    public static final ZombiePopulationManager instance = new ZombiePopulationManager();
    private static final ReentrantLock saveLock = new ReentrantLock();
    public int captures, writes, writesAtLastCapture;
    public void beginSaveRealZombies() {
        saveLock.lock();
        try { captures++; writesAtLastCapture = writes; } finally { saveLock.unlock(); }
    }
    public void endSaveRealZombies() { }
    public void save() { writes++; }
    public void processPendingSaveCells() { saveLock.lock(); try { } finally { saveLock.unlock(); } }
}