package zombie.ui;
/** Synthetic speed state; not game code. */
public final class SpeedControls {
    private int speed = 1;
    public int getCurrentGameSpeed() { return speed; }
    public void SetCurrentGameSpeed(int value) {
        if (value < 0 || value > 4) throw new IllegalArgumentException();
        speed = value;
    }
}
