package zombie.scripting.objects;
public final class VehicleScript {
    public int gearRatioCount=4; public String engineRpmType="generic"; public float efficiency=1;
    public float steeringMaximum=.9f,steeringMinimum=.4f;
    private final Wheel[] wheels={new Wheel(),new Wheel(),new Wheel(),new Wheel()};
    public float getOffroadEfficiency() { return efficiency; }
    public String getEngineRPMType() { return engineRpmType; }
    public int getWheelCount() { return wheels.length; }
    public Wheel getWheel(int index) { return wheels[index]; }
    public float getSteeringClamp(float speed) { return steeringMaximum+(steeringMinimum-steeringMaximum)*Math.min(1,Math.abs(speed)/100); }
    public static final class Wheel { public float radius=.3f; }
}
