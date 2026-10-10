package zombie.iso;

import java.util.ArrayList;

/** Synthetic. */
public final class BuildingDef {
    public final ArrayList<RoomDef> rooms = new ArrayList<>();
    private final boolean userDefined;
    public BuildingDef(boolean userDefined) { this.userDefined = userDefined; }
    /** Test: how many times the building's rooms were asked for. */
    public int asked;
    public ArrayList<RoomDef> getRooms() { asked++; return rooms; }
    public boolean isUserDefined() { return userDefined; }
}
