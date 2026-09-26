package zombie.core.physics;
/** Test sink only; does not load a native library. */
public final class Bullet {
    public static int calls,vehicleId; public static float force,brake,steer;
    public static void controlVehicle(int id,float drive,float stopping,float steering) { calls++; vehicleId=id; force=drive; brake=stopping; steer=steering; }
}
