package zombie;
public final class GameTime {
    public static GameTime instance=new GameTime();
    public float dt=1f/60;
    /** 0.8 is one 60 Hz update at normal speed, the scale the game's own steering line divides by. */
    public float multiplier=.8f;
    public float getPhysicsSecondsSinceLastUpdate() { return dt; }
    public float getMultiplier() { return multiplier; }
}
