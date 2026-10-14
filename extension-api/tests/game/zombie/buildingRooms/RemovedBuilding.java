package zombie.buildingRooms;

import zombie.iso.BuildingDef;

/** Synthetic: a map building the editor took out, by a square of it (its first room's first rectangle's corner). */
public final class RemovedBuilding {
    public int x, y, z;
    public RemovedBuilding setFrom(BuildingDef def) {
        var room = def.rooms.isEmpty() ? def.emptyoutside.get(0) : def.rooms.get(0);
        x = room.rects.get(0).x; y = room.rects.get(0).y; z = room.level;
        return this;
    }
}
