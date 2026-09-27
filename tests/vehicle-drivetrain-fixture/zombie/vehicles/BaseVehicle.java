package zombie.vehicles;
import zombie.characters.IsoPlayer;
import zombie.scripting.objects.VehicleScript;
public final class BaseVehicle {
    public float throttle,speed,maxSpeed=100,mass=1000,legacyOffroad=.25f;
    public int enginePower=1000;
    public int joypad=-1; public float currentSteering;
    public TransmissionNumber transmissionNumber=TransmissionNumber.N;
    public VehicleEngine engine=new VehicleEngine();
    public VehicleScript script=new VehicleScript();
    public IsoPlayer driver;
    public boolean running=true,burnt,offroad,regulator;
    public boolean keyboardControlled=true;
    public BaseVehicle towedBy,towing;
    public Object getDriver() { return driver; }
    public VehicleScript getScript() { return script; }
    public boolean isEngineRunning() { return running; }
    public Object getEngine() { return engine; }
    private VehicleEngine getVehicleEngine() { return engine; }
    public BaseVehicle getVehicleTowedBy() { return towedBy; }
    public BaseVehicle getVehicleTowing() { return towing; }
    public boolean isBurnt() { return burnt; }
    public float getCurrentSpeedKmHour() { return speed; }
    public int getEnginePower() { return enginePower; }
    public float getMass() { return mass; }
    public double getEngineSpeed() { return engine.getSpeed(); }
    public int getTransmissionNumber() { return transmissionNumber.index; }
    public float getMaxSpeed() { return maxSpeed; }
    public boolean isDoingOffroad() { return offroad; }
    public boolean isRegulator() { return regulator; }
    public int getJoypad() { return joypad; }
    public boolean isKeyboardControlled() { return keyboardControlled; }
    public void setCurrentSteering(float value) { currentSteering=value; }
}
