package zombie.iso;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import zombie.characters.IsoGameCharacter;
import zombie.iso.objects.IsoLightSwitch;

/** Synthetic: like the game's, a room's light is on while one of the room's switches stands on a square with power. */
public final class LightingJNI {
    private static List<IsoLightSwitch> switches;
    private static boolean lit;
    // The degrees of the vision cone, which the game smooths over time and hands to the shadows.
    private static float visionConeLerp = 144.0f;

    public static void setCone(float degrees) { visionConeLerp = degrees; }

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
        visionConeLerp = degrees;
        return (degrees - 180.0f) / 180.0f;
    }

    /** What the lighting hands for a square, by "x,y,z" (the visibility, the light, two darknesses, the level, 8 corners); a test sets it. */
    public static final Map<String, int[]> squares = new HashMap<>();

    /** Like the game's: the lighting of a square for a player into {@code into} (its z is offset by 32), or false when there is none. */
    public static boolean getSquareLighting(int player, int x, int y, int z, int[] into) {
        int[] known = squares.get(x + "," + y + "," + (z - 32));
        if (known == null) return false;
        System.arraycopy(known, 0, into, 0, known.length);
        return true;
    }

    /** The squares by "x,y,z" the lighting says changed; a test sets them. */
    public static final java.util.Set<String> changed = new java.util.HashSet<>();

    /** Like the game's: whether a square's lighting changed for a player since it was read (its z is offset by 32). */
    public static boolean getSquareDirty(int player, int x, int y, int z) { return changed.contains(x + "," + y + "," + (z - 32)); }

    /** Synthetic: a square's lighting for a player, read out of what the lighting hands as the game's two reads do, when it changed. */
    public static final class JNILighting {
        private static final int[] lightInts = new int[64];
        private final int playerIndex;
        private final IsoGridSquare square;
        private final int[] cacheVertLight = new int[8];

        public JNILighting(int playerIndex, IsoGridSquare square) { this.playerIndex = playerIndex; this.square = square; }

        private void update() {
            if (!getSquareDirty(playerIndex, square.x, square.y, square.z + 32)) return;
            if (!getSquareLighting(playerIndex, square.x, square.y, square.z + 32, lightInts)) return;
            for (int corner = 0; corner < 8; corner++) cacheVertLight[corner] = lightInts[5 + corner];
        }

        private void updateFBORenderChunk() {
            int[] ints = new int[64];
            if (!getSquareDirty(playerIndex, square.x, square.y, square.z + 32)) return;
            if (!getSquareLighting(playerIndex, square.x, square.y, square.z + 32, ints)) return;
            int index = 5;
            for (int corner = 0; corner < 8; corner++) cacheVertLight[corner] = ints[index++];
        }

        /** Reads the lighting again (by the chunk renderer's read, or the other). */
        public void read(boolean chunks) { if (chunks) updateFBORenderChunk(); else update(); }

        public int lightverts(int corner) { return cacheVertLight[corner]; }
    }

    /** Whether the light of a room with these switches is on. */
    public static boolean roomLit(List<IsoLightSwitch> roomSwitches) {
        switches = roomSwitches;
        checkLights();
        return lit;
    }
}
