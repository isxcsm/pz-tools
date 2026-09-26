package zombie.popman;

public final class ZombiePopulationManager {
    public static final ZombiePopulationManager instance = new ZombiePopulationManager();
    public int captures, writes, finishes, writesAtLastCapture = -1;
    public void beginSaveRealZombies() {
        writesAtLastCapture = zombie.MapCollisionData.instance.writes;
        captures++;
    }
    public void save() { writes++; }
    public void endSaveRealZombies() { finishes++; }
}
