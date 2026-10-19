package zombie.vehicles;

import java.util.ArrayList;
import java.util.List;
import zombie.iso.IsoMovingObject;

/** Synthetic: a vehicle with its parts; what it sends to the clients is counted, and which wheels have no tire. */
public final class BaseVehicle extends IsoMovingObject {
    public final VehicleParts parts = new VehicleParts();
    public final List<String> sentConditions = new ArrayList<>(), sentItems = new ArrayList<>();
    public final boolean[] tireRemoved = new boolean[4];
    public VehicleParts getParts() { return parts; }
    public void transmitPartCondition(VehiclePart part) { sentConditions.add(part.id); }
    public void transmitPartItem(VehiclePart part) { sentItems.add(part.id); }
    public void setTireRemoved(int wheel, boolean removed) { if (wheel >= 0 && wheel < tireRemoved.length) tireRemoved[wheel] = removed; }

    /** A part added to the vehicle (a test's). */
    public VehiclePart add(String id, zombie.inventory.InventoryItem item, int wheel) {
        var part = new VehiclePart();
        part.id = id;
        part.item = item;
        part.wheel = wheel;
        part.condition = 100;
        parts.list.add(part);
        return part;
    }
}
