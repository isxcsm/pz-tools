package zombie.iso;

import java.util.ArrayList;

/** Synthetic. */
public final class BuildingDef {
    public final ArrayList<RoomDef> rooms = new ArrayList<>();
    public final ArrayList<RoomDef> emptyoutside = new ArrayList<>();
    private boolean userDefined;
    /** As the game's: the door keys' number (a new building draws one), and some of its state. */
    private int keyId = (int)(Math.random() * 1_000_000);
    public boolean alarmed, seen, hasBeenVisited;
    public long metaId;
    public int lootRespawnHour, alarmDecay;
    public BuildingDef(boolean userDefined) { this.userDefined = userDefined; }
    /** Test: how many times the building's rooms were asked for. */
    public int asked;
    public ArrayList<RoomDef> getRooms() { asked++; return rooms; }
    public boolean isUserDefined() { return userDefined; }
    /** As the game's: a building whose first room is below ground. */
    public boolean isBasement() { return !rooms.isEmpty() && rooms.get(0).level < 0; }
    /** The squares of its rooms. */
    public int getArea() {
        int area = 0;
        for (RoomDef room : rooms) for (RoomDef.RoomRect rect : room.rects) area += rect.w * rect.h;
        return area;
    }
    public boolean isHasBeenVisited() { return hasBeenVisited; }
    public int getKeyId() { return keyId; }
    public void setKeyId(int value) { keyId = value; }
}
