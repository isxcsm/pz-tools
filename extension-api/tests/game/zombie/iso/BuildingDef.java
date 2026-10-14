package zombie.iso;

import java.util.ArrayList;

/** Synthetic. */
public final class BuildingDef {
    public final ArrayList<RoomDef> rooms = new ArrayList<>();
    public final ArrayList<RoomDef> emptyoutside = new ArrayList<>();
    private boolean userDefined;
    /** As the game's: the door keys' number (a new building draws one), and some of its state. */
    private int keyId = (int)(Math.random() * 1_000_000);
    public boolean alarmed, seen;
    public BuildingDef(boolean userDefined) { this.userDefined = userDefined; }
    /** Test: how many times the building's rooms were asked for. */
    public int asked;
    public ArrayList<RoomDef> getRooms() { asked++; return rooms; }
    public boolean isUserDefined() { return userDefined; }
    public int getKeyId() { return keyId; }
    public void setKeyId(int value) { keyId = value; }
}
