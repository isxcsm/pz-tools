package pztools.extensions.vehicle;

import java.lang.invoke.*;
import java.lang.reflect.*;
import pztools.extensions.api.ContinuousProvider;

/** Cached, build-specific reads and primitive commits; never calls Lua or Bullet. */
final class VehicleAccess {
    private final Class<?> controllerType, vehicleType, playerType, engineType, transmissionType;
    private final VarHandle vehicle, force, brake, controls, parking, throttle, transmission, rpm, steering, steeringInput;
    private final VarHandle client, server, world, worldCell, players, time, slowTrait, fastTrait, gearCount, radius, reverseSpeedLimit;
    private final MethodHandle driver, script, running, getEngine, getVehicleEngine, getTowedBy, getTowing, burnt;
    private final MethodHandle localPlayer, hasTrait, speed, power, mass, engineRpm, gear, maxSpeed, offroad, offroadEfficiency;
    private final MethodHandle rpmType, wheelCount, getWheel, physicsSeconds, frameNo, getVehicle, gas, gasReverse, regulator, joypad, steeringClamp;
    private final MethodHandle keyboardControlled, steeringKeyDown;
    private final VarHandle[] gears=new VarHandle[9];
    private final VarHandle reverse;
    private final ClassLoader loader;

    VehicleAccess(ClassLoader loader) throws ReflectiveOperationException {
        this.loader=loader;
        controllerType=type("zombie.core.physics.CarController"); vehicleType=type("zombie.vehicles.BaseVehicle");
        playerType=type("zombie.characters.IsoPlayer"); engineType=type("zombie.vehicles.VehicleEngine");
        transmissionType=type("zombie.vehicles.TransmissionNumber");
        Class<?> scriptType=type("zombie.scripting.objects.VehicleScript"), controlsType=type("zombie.core.physics.CarController$ClientControls");
        Class<?> gameTime=type("zombie.GameTime"), worldType=type("zombie.iso.IsoWorld"), character=type("zombie.characters.IsoGameCharacter");
        Class<?> trait=type("zombie.scripting.objects.CharacterTrait"), wheel=type("zombie.scripting.objects.VehicleScript$Wheel");
        vehicle=field(controllerType,"vehicleObject"); force=field(controllerType,"engineForce"); brake=field(controllerType,"brakingForce");
        controls=field(controllerType,"clientControls"); parking=field(controlsType,"wasUsingParkingBrakes");
        steering=field(controllerType,"vehicleSteering"); steeringInput=field(controlsType,"steering");
        throttle=field(vehicleType,"throttle"); transmission=field(vehicleType,"transmissionNumber"); rpm=field(engineType,"speed");
        client=field(type("zombie.network.GameClient"),"client"); server=field(type("zombie.network.GameServer"),"server");
        world=field(worldType,"instance"); worldCell=field(worldType,"currentCell"); players=field(playerType,"players"); time=field(gameTime,"instance");
        slowTrait=field(trait,"SUNDAY_DRIVER"); fastTrait=field(trait,"SPEED_DEMON");
        gearCount=field(scriptType,"gearRatioCount"); radius=field(wheel,"radius");
        reverseSpeedLimit=field(scriptType,"maxSpeedReverse");
        driver=method(vehicleType,"getDriver",Object.class); script=method(vehicleType,"getScript",Object.class);
        running=method(vehicleType,"isEngineRunning",boolean.class); getEngine=method(vehicleType,"getEngine",Object.class);
        getVehicleEngine=method(vehicleType,"getVehicleEngine",Object.class);
        getTowedBy=method(vehicleType,"getVehicleTowedBy",Object.class); getTowing=method(vehicleType,"getVehicleTowing",Object.class);
        burnt=method(vehicleType,"isBurnt",boolean.class); localPlayer=method(playerType,"isLocalPlayer",boolean.class);
        hasTrait=method(character,"hasTrait",boolean.class,trait);
        speed=method(vehicleType,"getCurrentSpeedKmHour",float.class); power=method(vehicleType,"getEnginePower",int.class);
        mass=method(vehicleType,"getMass",float.class); engineRpm=method(vehicleType,"getEngineSpeed",double.class);
        gear=method(vehicleType,"getTransmissionNumber",int.class); maxSpeed=method(vehicleType,"getMaxSpeed",float.class);
        offroad=method(vehicleType,"isDoingOffroad",boolean.class); offroadEfficiency=method(scriptType,"getOffroadEfficiency",float.class);
        rpmType=method(scriptType,"getEngineRPMType",Object.class); wheelCount=method(scriptType,"getWheelCount",int.class);
        getWheel=method(scriptType,"getWheel",Object.class,int.class); physicsSeconds=method(gameTime,"getPhysicsSecondsSinceLastUpdate",float.class);
        frameNo=method(worldType,"getFrameNo",int.class); getVehicle=method(playerType,"getVehicle",Object.class);
        gas=method(controllerType,"isGas",boolean.class); gasReverse=method(controllerType,"isGasR",boolean.class);
        regulator=method(vehicleType,"isRegulator",boolean.class);
        joypad=method(vehicleType,"getJoypad",int.class); steeringClamp=method(scriptType,"getSteeringClamp",float.class,float.class);
        keyboardControlled=method(vehicleType,"isKeyboardControlled",boolean.class);
        steeringKeyDown=MethodHandles.publicLookup().findStatic(type("zombie.input.GameKeyboard"),"isKeyDown",
            MethodType.methodType(boolean.class,String.class));
        reverse=field(transmissionType,"R");
        for(int i=1;i<=8;i++) gears[i]=field(transmissionType,"Speed"+i);
    }
    private Class<?> type(String name) throws ClassNotFoundException { return Class.forName(name,false,loader); }
    private static VarHandle field(Class<?> type,String name) throws ReflectiveOperationException {
        Field f=type.getDeclaredField(name);
        return MethodHandles.privateLookupIn(type,MethodHandles.lookup()).unreflectVarHandle(f);
    }
    private static MethodHandle method(Class<?> type,String name,Class<?> result,Class<?>... args) throws ReflectiveOperationException {
        Method m;
        try { m=type.getMethod(name,args); } catch(NoSuchMethodException absent) { m=type.getDeclaredMethod(name,args); }
        MethodHandle h=MethodHandles.privateLookupIn(m.getDeclaringClass(),MethodHandles.lookup()).unreflect(m);
        Class<?>[] erased=new Class<?>[args.length+1]; erased[0]=Object.class;
        for(int i=0;i<args.length;i++) erased[i+1]=args[i].isPrimitive()?args[i]:Object.class;
        return h.asType(MethodType.methodType(result,erased));
    }
    boolean ready(ContinuousProvider.Context context) throws Throwable {
        context.requireGameThread();
        Object currentWorld=world.get();
        if ((boolean)client.get() || (boolean)server.get() || currentWorld==null
                || worldCell.get(currentWorld)!=context.worldIdentity()) return false;
        Object[] list=(Object[])players.get();
        for(Object p:list) {
            if(p==null) continue;
            Object v=(Object)getVehicle.invokeExact(p);
            if(v!=null) {
                float currentSpeed=(float)speed.invokeExact(v), currentThrottle=(float)throttle.get(v);
                if(!Float.isFinite(currentSpeed) || !Float.isFinite(currentThrottle)
                    || Math.abs(currentSpeed)>0.5f || Math.abs(currentThrottle)>0.01f || (boolean)regulator.invokeExact(v)) return false;
            }
        }
        return true;
    }
    String read(Object c,ContinuousProvider.Context context,Frame f) throws Throwable {
        if (Thread.currentThread()!=context.gameThread() || !context.worldValid().get()) return "wrong-thread-or-world";
        if ((boolean)client.get() || (boolean)server.get()) return "multiplayer-unsupported";
        Object currentWorld=world.get();
        if(currentWorld==null || worldCell.get(currentWorld)!=context.worldIdentity()
                || !controllerType.isInstance(c)) return "world-or-controller-changed";
        Object v=vehicle.get(c); if(!vehicleType.isInstance(v)) return "missing-vehicle";
        f.vehicle=v;
        Object p=(Object)driver.invokeExact(v);
        if(!playerType.isInstance(p) || !(boolean)localPlayer.invokeExact(p)) return "not-local-driver";
        f.driver=p;
        if((Object)getTowedBy.invokeExact(v)!=null || (boolean)burnt.invokeExact(v)) return "towed-or-burnt";
        Object towing=(Object)getTowing.invokeExact(v);
        if(towing!=null && (boolean)burnt.invokeExact(towing)) return "burnt-tow-unsupported";
        if(!(boolean)running.invokeExact(v) || (Object)getEngine.invokeExact(v)==null) return "engine-not-running";
        Object s=(Object)script.invokeExact(v);
        if(s==null || (int)wheelCount.invokeExact(s)!=4) return "unsupported-wheels";
        for(int i=0;i<4;i++) {
            Object w=(Object)getWheel.invokeExact(s,i); float r=(float)radius.get(w);
            if(!Float.isFinite(r) || r<0.05f || r>5f) return "invalid-wheel-radius";
            f.radiusMin=i==0?r:Math.min(f.radiusMin,r); f.radiusMax=Math.max(f.radiusMax,r);
        }
        Object e=(Object)getVehicleEngine.invokeExact(v);
        if(!engineType.isInstance(e)) return "missing-engine-state";
        f.engine=e; f.controls=controls.get(c);
        f.script=s; f.engineType=(String)(Object)rpmType.invokeExact(s); f.gears=(int)gearCount.get(s);
        f.frame=(int)frameNo.invokeExact(currentWorld); f.dt=(float)physicsSeconds.invokeExact((Object)time.get());
        f.speed=(float)speed.invokeExact(v); f.maxSpeed=(float)maxSpeed.invokeExact(v); f.mass=(float)mass.invokeExact(v);
        // control_Reverse compares 1.5 * actual speed with this script field.
        f.reverseMaxSpeed=(float)reverseSpeedLimit.get(s)/1.5;
        f.power=(int)power.invokeExact(v); f.rpm=(double)engineRpm.invokeExact(v); f.gear=(int)gear.invokeExact(v);
        f.offroad=(boolean)offroad.invokeExact(v); f.efficiency=(float)offroadEfficiency.invokeExact(s); f.towing=towing!=null;
        f.slow=(boolean)hasTrait.invokeExact(p,(Object)slowTrait.get()); f.fast=(boolean)hasTrait.invokeExact(p,(Object)fastTrait.get());
        f.gas=(boolean)gas.invokeExact(c); f.reverseGas=(boolean)gasReverse.invokeExact(c);
        return null;
    }
    Object gearObject(int gear) { return gear==-1 ? reverse.get() : gear>=1 && gear<=8 ? gears[gear].get() : null; }
    String readSteering(Object c,ContinuousProvider.Context context,SteeringFrame f) throws Throwable {
        if(Thread.currentThread()!=context.gameThread() || !context.worldValid().get()) return "wrong-thread-or-world";
        if((boolean)client.get() || (boolean)server.get()) return "multiplayer-unsupported";
        Object currentWorld=world.get();
        if(currentWorld==null || worldCell.get(currentWorld)!=context.worldIdentity() || !controllerType.isInstance(c)) return "world-or-controller-changed";
        Object v=vehicle.get(c); if(!vehicleType.isInstance(v)) return "missing-vehicle";
        Object p=(Object)driver.invokeExact(v);
        if(!playerType.isInstance(p) || !(boolean)localPlayer.invokeExact(p)) return "not-local-driver";
        if((int)joypad.invokeExact(v)!=-1) return "gamepad-original";
        if((Object)getTowedBy.invokeExact(v)!=null || (boolean)burnt.invokeExact(v)) return "towed-or-burnt";
        Object s=(Object)script.invokeExact(v);
        if(s==null || (int)wheelCount.invokeExact(s)!=4) return "unsupported-wheels";
        Object input=controls.get(c);
        if(input==null) return "missing-controls";
        f.driver=p; f.input=(float)steeringInput.get(input); f.actual=(float)steering.get(c);
        // The game updates physics before refreshing ClientControls. Only veto
        // a stale held direction when that mapped key is no longer held. Never
        // synthesize a new press/reversal or write ClientControls: the game's
        // aiming/loading/drunk input gates remain authoritative for new input.
        if(Float.isFinite(f.input) && Math.abs(f.input)>0.1f && Math.abs(f.input)<=1.0001f
                && (boolean)keyboardControlled.invokeExact(v)) {
            boolean left=(boolean)steeringKeyDown.invokeExact("Left");
            boolean right=(boolean)steeringKeyDown.invokeExact("Right");
            int heldDirection=(right?1:0)-(left?1:0);
            if(f.input*heldDirection<=0) f.input=0;
        }
        f.speed=(float)speed.invokeExact(v); f.maximumSpeed=(float)maxSpeed.invokeExact(v);
        f.maximum=(float)steeringClamp.invokeExact(s,Math.abs(f.speed));
        f.frame=(int)frameNo.invokeExact(currentWorld); f.dt=(float)physicsSeconds.invokeExact((Object)time.get());
        return null;
    }
    /** Validated primitive steering field only; original clamp/tire/wheel/native paths remain downstream. */
    void commitSteering(Object c,float value) { steering.set(c,value); }
    boolean canCommit(Object c,Frame f,Object g) {
        return controllerType.isInstance(c) && vehicleType.isInstance(f.vehicle) && engineType.isInstance(f.engine)
            && transmissionType.isInstance(g) && controls.varType().isInstance(f.controls);
    }
    /** All receiver/value types were validated before entry; no game methods or allocating conversions. */
    void commit(Object c,Frame f,Object g,float outputForce,double outputRpm,float outputThrottle) {
        rpm.set(f.engine,outputRpm); transmission.set(f.vehicle,g); throttle.set(f.vehicle,outputThrottle);
        force.set(c,outputForce); brake.set(c,0f); parking.set(f.controls,false);
    }
    static final class Frame {
        Object vehicle,engine,driver,controls,script; String engineType;
        int gears,frame,power,gear; double rpm,reverseMaxSpeed; float dt,speed,maxSpeed,mass,efficiency,radiusMin,radiusMax;
        boolean offroad,towing,slow,fast,gas,reverseGas;
        void clear() {
            vehicle=null; engine=null; driver=null; controls=null; script=null; engineType=null;
            gears=frame=power=gear=0; rpm=reverseMaxSpeed=0; dt=speed=maxSpeed=mass=efficiency=radiusMin=radiusMax=0;
            offroad=towing=slow=fast=gas=reverseGas=false;
        }
    }
    static final class SteeringFrame {
        Object driver; int frame; float input,actual,maximum,speed,maximumSpeed,dt;
        void clear() { driver=null; frame=0; input=actual=maximum=speed=maximumSpeed=dt=0; }
    }
}
