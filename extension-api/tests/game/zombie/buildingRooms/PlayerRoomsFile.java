package zombie.buildingRooms;

import zombie.ZomboidFileSystem;

/** Synthetic: the editor's rooms file of the save, as the game reads it as the world loads (here: which file it opened). */
public final class PlayerRoomsFile {
    /** The file the last load read, or null when there was none. */
    public static java.io.File lastRead;

    public void load() {
        java.io.File file = ZomboidFileSystem.instance.getFileInCurrentSave("player_buildings.bin");
        lastRead = file.exists() ? file : null;
    }
}
