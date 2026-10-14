package zombie.buildingRooms;

import zombie.iso.RoomDef;

/** Synthetic: a room of the editor, as the game's: made explored and spawned. */
public final class BRERoom {
    final BREBuilding building;
    final RoomDef roomDef;
    BRERoom(BREBuilding building) {
        roomDef = new RoomDef(0, "");
        this.building = building;
        roomDef.explored = true;
        roomDef.doneSpawn = true;
    }
    public BRERoom copyFrom(RoomDef other) { roomDef.copyFrom(other); return this; }
}
