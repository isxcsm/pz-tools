package zombie;
/** Synthetic pause source; tests never load or edit the game JAR. */
public final class GameTime {
    public static boolean isGamePaused() {
        return zombie.ui.UIManager.getSpeedControls().getCurrentGameSpeed() == 0;
    }
}
