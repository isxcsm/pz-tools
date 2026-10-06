package zombie.iso.objects;

import zombie.iso.IsoGridSquare;
import zombie.iso.IsoObject;
import zombie.iso.IsoWorld;
import zombie.iso.sprite.IsoSprite;

/** Synthetic: like the game's, a switch has power when its square or a room square beside it has. */
public class IsoLightSwitch extends IsoObject {
    public long roomId = -1;
    public IsoLightSwitch(IsoSprite sprite) { super(sprite); powered = true; consumption = 0.002f; }
    private boolean hasElectricityAround() {
        if (square == null) return false;
        for (int[] step : new int[][] { { 0, 0 }, { 0, -1 }, { -1, 0 } }) {
            IsoGridSquare near = IsoWorld.instance.getCell().getGridSquare(square.x + step[0], square.y + step[1], square.z);
            if (near != null && near.haveElectricity()) return true;
        }
        return false;
    }
    /** What the game asks when the switch is used. */
    public boolean canSwitch() { return hasElectricityAround(); }
}
