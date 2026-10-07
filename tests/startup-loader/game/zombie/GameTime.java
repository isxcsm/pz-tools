package zombie;

/** Synthetic: the world's age, which the test sets. */
public final class GameTime {
    public static final GameTime instance = new GameTime();
    public double hours;
    public static GameTime getInstance() { return instance; }
    public double getWorldAgeHours() { return hours; }
}
