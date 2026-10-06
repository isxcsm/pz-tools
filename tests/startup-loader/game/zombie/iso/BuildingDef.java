package zombie.iso;

import java.util.ArrayList;

/** Synthetic. */
public final class BuildingDef {
    public final ArrayList<RoomDef> rooms = new ArrayList<>();
    private final boolean userDefined;
    public BuildingDef(boolean userDefined) { this.userDefined = userDefined; }
    public ArrayList<RoomDef> getRooms() { return rooms; }
    public boolean isUserDefined() { return userDefined; }
}
