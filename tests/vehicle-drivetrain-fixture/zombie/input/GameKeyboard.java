package zombie.input;

/** Synthetic mapped input; NaN follows the fixture controls unless explicitly overridden. */
public final class GameKeyboard {
    public static zombie.core.physics.CarController.ClientControls controls;
    public static float steering=Float.NaN;
    public static boolean both;
    public static int reads;
    public static boolean isKeyDown(String key) {
        reads++;
        float value=Float.isNaN(steering)?controls.steering:steering;
        return switch(key) {
            case "Left" -> both || value<0;
            case "Right" -> both || value>0;
            default -> throw new AssertionError("Only mapped steering keys may be sampled");
        };
    }
}
