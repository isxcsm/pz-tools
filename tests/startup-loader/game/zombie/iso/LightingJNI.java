package zombie.iso;

import java.util.List;
import zombie.iso.objects.IsoLightSwitch;

/** Synthetic: like the game's, a room's light is on while one of the room's switches stands on a square with power. */
public final class LightingJNI {
    private static List<IsoLightSwitch> switches;
    private static boolean lit;

    private static void checkLights() {
        boolean any = false;
        for (IsoLightSwitch light : switches) if (light.square != null && light.square.haveElectricity()) any = true;
        lit = any;
    }

    /** Whether the light of a room with these switches is on. */
    public static boolean roomLit(List<IsoLightSwitch> roomSwitches) {
        switches = roomSwitches;
        checkLights();
        return lit;
    }
}
