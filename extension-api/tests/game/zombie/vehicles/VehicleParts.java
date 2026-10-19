package zombie.vehicles;

import java.util.ArrayList;

/** Synthetic: a vehicle's parts, in order, found by index or id. */
public final class VehicleParts {
    public final ArrayList<VehiclePart> list = new ArrayList<>();
    public int getPartCount() { return list.size(); }
    public VehiclePart getPartByIndex(int index) { return index >= 0 && index < list.size() ? list.get(index) : null; }
    public VehiclePart getPartById(String id) {
        for (VehiclePart part : list) if (id != null && id.equals(part.id)) return part;
        return null;
    }
}
