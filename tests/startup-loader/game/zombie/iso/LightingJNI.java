package zombie.iso;

import java.util.List;
import zombie.characters.IsoGameCharacter;
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

    /** How dark it is for the character: the light on it, inverted. */
    private static float getLumaInverted(IsoGameCharacter character) {
        return 1.0f - character.luma;
    }

    public static float darkness(IsoGameCharacter character) { return getLumaInverted(character); }

    /** The vision cone as a value from -1 (a sliver) to 1 (all around), from the degrees the character sees; the worn items scale the degrees. */
    public static float calculateVisionCone(IsoGameCharacter character) {
        float degrees = 144.0f;
        degrees = degrees - 126.0f * getLumaInverted(character);
        degrees = Math.max(18.0f, Math.min(180.0f, degrees));
        if (character.eagleEyed) degrees = degrees + 36.0f;
        degrees = degrees * character.getWornItemsVisionMultiplier();
        degrees = Math.max(18.0f, Math.min(360.0f, degrees));
        return (degrees - 180.0f) / 180.0f;
    }

    /** Whether the light of a room with these switches is on. */
    public static boolean roomLit(List<IsoLightSwitch> roomSwitches) {
        switches = roomSwitches;
        checkLights();
        return lit;
    }
}
