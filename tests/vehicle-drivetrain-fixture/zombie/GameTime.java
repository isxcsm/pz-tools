package zombie;
public final class GameTime { public static GameTime instance=new GameTime(); public float dt=1f/60; public float getPhysicsSecondsSinceLastUpdate() { return dt; } }
