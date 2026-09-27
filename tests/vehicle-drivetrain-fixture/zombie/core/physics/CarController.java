package zombie.core.physics;

import zombie.vehicles.BaseVehicle;

/** Synthetic branch sentinels, intentionally not the game's controller implementation. */
public final class CarController {
    public final BaseVehicle vehicleObject;
    public final ClientControls clientControls=new ClientControls();
    public float engineForce,brakingForce;
    private boolean isGas,isGasR,isBreak;
    public int request,forwardCalls,reverseCalls,coastCalls,brakeCalls,startRequests,speedRequests;
    public int delaySelections,chunkSelections,cruiseSelections,parkingSelections;
    public float tireFactor=1,steering,vehicleSteering,speed,steeringTireFactor=1;
    public int originalSteeringCalls,rammingCalls;
    public int vehicleId=1;
    public boolean backSignal,brakeLights;
    public boolean drunkDelay,unsafeChunk,cruiseInput,parkingInput;
    public CarController(BaseVehicle vehicle) {
        vehicleObject=vehicle;
        zombie.input.GameKeyboard.controls=clientControls;
    }
    public enum ControlState { NoControl,Braking,Forward,Reverse }
    public static final class ClientControls { public boolean wasUsingParkingBrakes; public float steering; }
    public boolean isGas() { return isGas; }
    public boolean isGasR() { return isGasR; }
    public void update() {
        zombie.scripting.objects.VehicleScript script=vehicleObject.getScript();
        float speed=vehicleObject.getCurrentSpeedKmHour();
        this.speed=speed;
        isGas=request==1; isGasR=request==2; isBreak=request==3;
        // Synthetic input sentinels: no installed game input implementation is reproduced here.
        if(cruiseInput && !isGasR && !isBreak) { cruiseSelections++; isGas=true; }
        if(drunkDelay) { delaySelections++; isGas=false; isGasR=false; clientControls.steering=0; }
        if(unsafeChunk) { chunkSelections++; isBreak=true; isGas=false; isGasR=false; }
        if(parkingInput) { parkingSelections++; isBreak=true; isGas=false; isGasR=false; }
        ControlState state=ControlState.NoControl;
        if(isBreak) state=ControlState.Braking;
        else if(isGas) state=ControlState.Forward;
        else if(isGasR) state=ControlState.Reverse;
        if(state!=ControlState.NoControl) speedRequests++;
        if(state==ControlState.NoControl) control_NoControl();
        if(state==ControlState.Reverse) control_Reverse(speed);
        if(state==ControlState.Forward) control_ForwardNew(speed);
        updateBackSignal();
        if(state==ControlState.Braking) control_Braking();
        updateBrakeLights();
        updateRammingSound(speed);
        if(Math.abs(this.clientControls.steering)>.1f) {
            originalSteeringCalls++;
            this.vehicleSteering-=(this.clientControls.steering+this.vehicleSteering)*.06f;
        } else {
            originalSteeringCalls++;
            this.vehicleSteering=Math.abs(this.vehicleSteering)<=.04f?0:this.vehicleSteering-Math.copySign(.04f,this.vehicleSteering);
        }
        float steeringClamp=script.getSteeringClamp(this.speed);
        this.vehicleSteering=Math.max(-steeringClamp,Math.min(steeringClamp,this.vehicleSteering));
        this.vehicleSteering*=steeringTireFactor;
        engineForce*=tireFactor; brakingForce*=tireFactor;
        if(vehicleObject.isDoingOffroad()) engineForce*=vehicleObject.legacyOffroad;
        vehicleObject.setCurrentSteering(vehicleSteering);
        Bullet.controlVehicle(vehicleId,engineForce,brakingForce,vehicleSteering);
        if(!vehicleObject.isEngineRunning()) {
            if(engineForce>0) startRequests++;
            Bullet.controlVehicle(vehicleId,0,brakingForce,vehicleSteering);
        }
    }
    private void control_NoControl() { coastCalls++; engineForce=0; brakingForce=2; vehicleObject.transmissionNumber=zombie.vehicles.TransmissionNumber.N; vehicleObject.engine.setSpeed(800); }
    private void control_ForwardNew(float speed) { forwardCalls++; engineForce=11; brakingForce=0; if(clientControls.wasUsingParkingBrakes) { engineForce*=8; clientControls.wasUsingParkingBrakes=false; } }
    private void control_Reverse(float speed) { reverseCalls++; engineForce=-13; brakingForce=0; }
    private void control_Braking() { brakeCalls++; engineForce=0; brakingForce=17; vehicleObject.transmissionNumber=zombie.vehicles.TransmissionNumber.N; vehicleObject.engine.setSpeed(800); }
    private void updateBackSignal() { backSignal=isGasR; }
    private void updateBrakeLights() { brakeLights=isBreak; }
    private void updateRammingSound(float speed) { rammingCalls++; }
}
