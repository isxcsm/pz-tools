package pztools.extensions.vehicle;

import java.lang.invoke.*;
import java.lang.reflect.*;
import pztools.extensions.api.ContinuousProvider;
import pztools.extensions.vehicle.model.SteeringModel;

/** Cached, build-specific reads and primitive commits; never calls Lua or Bullet. */
final class VehicleAccess {
    private final Class<?> controllerType, vehicleType, playerType, engineType, transmissionType;
    private final VarHandle vehicle, force, brake, controls, parking, throttle, transmission, rpm, steering, steeringInput;
    private final VarHandle client, server, world, worldCell, players, time, slowTrait, fastTrait, gearCount, radius, reverseSpeedLimit;
    private final MethodHandle driver, script, running, getEngine, getVehicleEngine, getTowedBy, getTowing, burnt;
    private final MethodHandle localPlayer, hasTrait, speed, power, mass, engineRpm, gear, maxSpeed, offroad, offroadEfficiency;
    private final MethodHandle rpmType, wheelCount, getWheel, physicsSeconds, frameNo, getVehicle, gas, gasReverse, regulator, joypad, steeringClamp;
    private final MethodHandle keyboardControlled, steeringKeyDown, multiplier;
    // Optional: only precise key timing needs the bindings. Without them steering uses the game's input as is.
    private MethodHandle coreInstance, keyBinding, bindingKey, bindingAlternate, bindingShift, bindingControl, bindingAlt;
    // Optional: the conditions under which the game accepts a steering key. Without them measured
    // key time waits for the game's own input to confirm the direction.
    private VarHandle textEntryBox, drunkMoodle;
    private MethodHandle doingTextEntry, blockMovement, operational, moodles, moodleLevel;
    // Optional: a light around the occupied vehicle. Without these only that light is unavailable.
    private MethodHandle headlightsOn, headlightsEmit, positionX, positionY, positionZ, newLight, addLamppost, removeLamppost;
    private VarHandle lightLife;
    private final VarHandle[] gears=new VarHandle[9];
    private final VarHandle reverse;
    private final ClassLoader loader;

    VehicleAccess(ClassLoader loader) throws ReflectiveOperationException {
        this.loader=loader;
        controllerType=type("zombie.core.physics.CarController"); vehicleType=type("zombie.vehicles.BaseVehicle");
        playerType=type("zombie.characters.IsoPlayer"); engineType=type("zombie.vehicles.VehicleEngine");
        transmissionType=type("zombie.vehicles.TransmissionNumber");
        Class<?> scriptType=type("zombie.scripting.objects.VehicleScript"), controlsType=type("zombie.core.physics.CarController$ClientControls");
        Class<?> controlState=type("zombie.core.physics.CarController$ControlState");
        for(String state:new String[]{"NoControl","Forward","Reverse","Braking"}) field(controlState,state,controlState,true);
        Class<?> gameTime=type("zombie.GameTime"), worldType=type("zombie.iso.IsoWorld"), character=type("zombie.characters.IsoGameCharacter");
        Class<?> trait=type("zombie.scripting.objects.CharacterTrait"), wheel=type("zombie.scripting.objects.VehicleScript$Wheel");
        Class<?> cell=type("zombie.iso.IsoCell"), part=type("zombie.vehicles.VehiclePart");
        if(!character.isAssignableFrom(playerType))
            throw new ReflectiveOperationException("class-contract:zombie.characters.IsoPlayer:expected-IsoGameCharacter");
        vehicle=field(controllerType,"vehicleObject",vehicleType,false);
        force=writableField(controllerType,"engineForce",float.class,false); brake=writableField(controllerType,"brakingForce",float.class,false);
        controls=field(controllerType,"clientControls",controlsType,false); parking=writableField(controlsType,"wasUsingParkingBrakes",boolean.class,false);
        steering=writableField(controllerType,"vehicleSteering",float.class,false); steeringInput=field(controlsType,"steering",float.class,false);
        throttle=writableField(vehicleType,"throttle",float.class,false); transmission=writableField(vehicleType,"transmissionNumber",transmissionType,false);
        rpm=writableField(engineType,"speed",double.class,false);
        client=field(type("zombie.network.GameClient"),"client",boolean.class,true);
        server=field(type("zombie.network.GameServer"),"server",boolean.class,true);
        world=field(worldType,"instance",worldType,true); worldCell=field(worldType,"currentCell",cell,false);
        players=field(playerType,"players",playerType.arrayType(),true); time=field(gameTime,"instance",gameTime,true);
        slowTrait=field(trait,"SUNDAY_DRIVER",trait,true); fastTrait=field(trait,"SPEED_DEMON",trait,true);
        gearCount=field(scriptType,"gearRatioCount",int.class,false); radius=field(wheel,"radius",float.class,false);
        reverseSpeedLimit=field(scriptType,"maxSpeedReverse",float.class,false);
        driver=method(vehicleType,"getDriver",character,false); script=method(vehicleType,"getScript",scriptType,false);
        running=method(vehicleType,"isEngineRunning",boolean.class,false); getEngine=method(vehicleType,"getEngine",part,false);
        getVehicleEngine=method(vehicleType,"getVehicleEngine",engineType,false);
        getTowedBy=method(vehicleType,"getVehicleTowedBy",vehicleType,false); getTowing=method(vehicleType,"getVehicleTowing",vehicleType,false);
        burnt=method(vehicleType,"isBurnt",boolean.class,false); localPlayer=method(playerType,"isLocalPlayer",boolean.class,false);
        hasTrait=method(character,"hasTrait",boolean.class,false,trait);
        speed=method(vehicleType,"getCurrentSpeedKmHour",float.class,false); power=method(vehicleType,"getEnginePower",int.class,false);
        mass=method(vehicleType,"getMass",float.class,false); engineRpm=method(vehicleType,"getEngineSpeed",double.class,false);
        gear=method(vehicleType,"getTransmissionNumber",int.class,false); maxSpeed=method(vehicleType,"getMaxSpeed",float.class,false);
        offroad=method(vehicleType,"isDoingOffroad",boolean.class,false); offroadEfficiency=method(scriptType,"getOffroadEfficiency",float.class,false);
        rpmType=method(scriptType,"getEngineRPMType",String.class,false); wheelCount=method(scriptType,"getWheelCount",int.class,false);
        getWheel=method(scriptType,"getWheel",wheel,false,int.class); physicsSeconds=method(gameTime,"getPhysicsSecondsSinceLastUpdate",float.class,false);
        frameNo=method(worldType,"getFrameNo",int.class,false); getVehicle=method(playerType,"getVehicle",vehicleType,false);
        gas=method(controllerType,"isGas",boolean.class,false); gasReverse=method(controllerType,"isGasR",boolean.class,false);
        regulator=method(vehicleType,"isRegulator",boolean.class,false);
        joypad=method(vehicleType,"getJoypad",int.class,false); steeringClamp=method(scriptType,"getSteeringClamp",float.class,false,float.class);
        keyboardControlled=method(vehicleType,"isKeyboardControlled",boolean.class,false);
        steeringKeyDown=method(type("zombie.input.GameKeyboard"),"isKeyDown",boolean.class,true,String.class)
            .asType(MethodType.methodType(boolean.class,String.class));
        multiplier=method(gameTime,"getMultiplier",float.class,false);
        reverse=field(transmissionType,"R",transmissionType,true);
        for(int i=1;i<=8;i++) gears[i]=field(transmissionType,"Speed"+i,transmissionType,true);
        try {
            Class<?> core=type("zombie.core.Core"), binding=type("zombie.core.Core$KeyBinding");
            MethodHandle instance=method(core,"getInstance",core,true), lookup=method(core,"getKeyBinding",binding,false,String.class);
            MethodHandle key=method(binding,"keyValue",int.class,false), alternate=method(binding,"altKey",int.class,false);
            MethodHandle shift=method(binding,"shift",boolean.class,false), control=method(binding,"ctrl",boolean.class,false);
            MethodHandle alt=method(binding,"alt",boolean.class,false);
            coreInstance=instance; keyBinding=lookup; bindingKey=key; bindingAlternate=alternate;
            bindingShift=shift; bindingControl=control; bindingAlt=alt;
        } catch(ReflectiveOperationException | LinkageError unavailable) { coreInstance=null; }
        try {
            Class<?> core=type("zombie.core.Core"), entry=type("zombie.ui.UITextEntryInterface");
            Class<?> moodleSet=type("zombie.characters.Moodles.Moodles"), moodle=type("zombie.scripting.objects.MoodleType");
            VarHandle box=field(core,"currentTextEntryBox",entry,true), drunkType=field(moodle,"DRUNK",moodle,true);
            MethodHandle typing=method(entry,"isDoingTextEntry",boolean.class,false), blocked=method(playerType,"isBlockMovement",boolean.class,false);
            MethodHandle working=method(vehicleType,"isOperational",boolean.class,false);
            MethodHandle mood=method(character,"getMoodles",moodleSet,false), level=method(moodleSet,"getMoodleLevel",int.class,false,moodle);
            textEntryBox=box; drunkMoodle=drunkType; doingTextEntry=typing; blockMovement=blocked; operational=working;
            moodles=mood; moodleLevel=level;
        } catch(ReflectiveOperationException | LinkageError unavailable) { textEntryBox=null; }
        try {
            Class<?> light=type("zombie.iso.IsoLightSource");
            MethodHandle on=method(vehicleType,"getHeadlightsOn",boolean.class,false), emit=method(vehicleType,"getHeadlightCanEmmitLight",boolean.class,false);
            MethodHandle x=method(vehicleType,"getX",float.class,false), y=method(vehicleType,"getY",float.class,false), z=method(vehicleType,"getZ",float.class,false);
            MethodHandle create=MethodHandles.publicLookup().findConstructor(light,
                    MethodType.methodType(void.class,int.class,int.class,int.class,float.class,float.class,float.class,int.class))
                .asType(MethodType.methodType(Object.class,int.class,int.class,int.class,float.class,float.class,float.class,int.class));
            MethodHandle add=method(cell,"addLamppost",void.class,false,light), remove=method(cell,"removeLamppost",void.class,false,light);
            VarHandle life=writableField(light,"life",int.class,false);
            headlightsOn=on; headlightsEmit=emit; positionX=x; positionY=y; positionZ=z;
            addLamppost=add; removeLamppost=remove; lightLife=life; newLight=create;
        } catch(ReflectiveOperationException | LinkageError unavailable) { newLight=null; }
    }
    boolean areaLightResolved() { return newLight!=null; }
    /**
     * The tile of the vehicle the local player sits in, while its headlights are actually lit
     * (switched on, with a charged battery and a working bulb, as the game itself judges it).
     * False in every other case, including a world that is no longer this activation's.
     */
    boolean areaLightTarget(ContinuousProvider.Context context,int[] tile) throws Throwable {
        if(newLight==null || Thread.currentThread()!=context.gameThread() || !context.worldValid().get()) return false;
        if((boolean)client.get() || (boolean)server.get()) return false;
        Object currentWorld=world.get();
        if(currentWorld==null || worldCell.get(currentWorld)!=context.worldIdentity()) return false;
        for(Object p:(Object[])players.get()) {
            if(p==null || !(boolean)localPlayer.invokeExact(p)) continue;
            Object v=(Object)getVehicle.invokeExact(p);
            if(v==null) continue;
            if(!(boolean)headlightsOn.invokeExact(v) || !(boolean)headlightsEmit.invokeExact(v)) return false;
            float x=(float)positionX.invokeExact(v), y=(float)positionY.invokeExact(v), z=(float)positionZ.invokeExact(v);
            if(!Float.isFinite(x) || !Float.isFinite(y) || !Float.isFinite(z)) return false;
            tile[0]=(int)Math.floor(x); tile[1]=(int)Math.floor(y); tile[2]=(int)Math.floor(z);
            return true;
        }
        return false;
    }
    /**
     * A steady light registered with the world the way the game registers a lightbar's glow.
     * It lives in memory only: nothing about it is saved, and it ends with the world.
     */
    Object placeLight(ContinuousProvider.Context context,int x,int y,int z,float r,float g,float b,int radius) throws Throwable {
        Object light=(Object)newLight.invokeExact(x,y,z,r,g,b,radius);
        lightLife.set(light,-1); // Steady; any other value makes the game treat it as a fading flash.
        addLamppost.invokeExact((Object)context.worldIdentity(),light);
        return light;
    }
    /** Game thread: withdraws the light and has the game recompute the lighting it touched. */
    void removeLight(ContinuousProvider.Context context,Object light) throws Throwable {
        Object currentWorld=world.get();
        if(currentWorld!=null && worldCell.get(currentWorld)==context.worldIdentity())
            removeLamppost.invokeExact((Object)context.worldIdentity(),light);
        else expireLight(light);
    }
    /** Any thread: marks this module's own light as ended; the game drops it on its next lighting pass. */
    void expireLight(Object light) { lightLife.setVolatile(light,0); }
    boolean inputGateResolved() { return textEntryBox!=null; }
    /**
     * Whether the game would take a steering key right now, by the same conditions it applies when
     * it samples the keyboard: a working vehicle, a driver whose movement is not blocked, no text
     * being typed. False also when that cannot be told, and when the driver is drunk: the game then
     * delays commands by a random time, which only its own input reproduces.
     */
    private boolean steeringInputOpen(Object v,Object p) throws Throwable {
        if(textEntryBox==null) return false;
        if(!(boolean)operational.invokeExact(v) || (boolean)blockMovement.invokeExact(p)) return false;
        Object box=textEntryBox.get();
        if(box!=null && (boolean)doingTextEntry.invokeExact(box)) return false;
        Object mood=(Object)moodles.invokeExact(p);
        return mood!=null && (int)moodleLevel.invokeExact(mood,(Object)drunkMoodle.get())==0;
    }
    boolean bindingsResolved() { return coreInstance!=null; }
    /**
     * Game key codes bound to steering as {left, left alternate, right, right alternate}; 0 is unbound.
     * False when the bindings cannot be read or carry a modifier: one plain key per press is all that is timed.
     */
    boolean steeringKeys(int[] out) throws Throwable {
        if(coreInstance==null) return false;
        Object core=(Object)coreInstance.invokeExact();
        if(core==null) return false;
        return binding(core,"Left",out,0) && binding(core,"Right",out,2);
    }
    private boolean binding(Object core,String name,int[] out,int offset) throws Throwable {
        Object value=(Object)keyBinding.invokeExact(core,(Object)name);
        if(value==null || (boolean)bindingShift.invokeExact(value) || (boolean)bindingControl.invokeExact(value)
                || (boolean)bindingAlt.invokeExact(value)) return false;
        out[offset]=(int)bindingKey.invokeExact(value); out[offset+1]=(int)bindingAlternate.invokeExact(value);
        return true;
    }
    private Class<?> type(String name) throws ClassNotFoundException { return Class.forName(name,false,loader); }
    private static VarHandle field(Class<?> type,String name,Class<?> expectedType,boolean isStatic) throws ReflectiveOperationException {
        Field f=type.getDeclaredField(name);
        if(f.getType()!=expectedType || Modifier.isStatic(f.getModifiers())!=isStatic)
            throw new NoSuchFieldException("field-contract:"+type.getName()+"."+name);
        return MethodHandles.privateLookupIn(type,MethodHandles.lookup()).unreflectVarHandle(f);
    }
    private static VarHandle writableField(Class<?> type,String name,Class<?> expectedType,boolean isStatic) throws ReflectiveOperationException {
        VarHandle handle=field(type,name,expectedType,isStatic);
        if(!handle.isAccessModeSupported(VarHandle.AccessMode.SET))
            throw new IllegalAccessException("readonly-field-contract:"+type.getName()+"."+name);
        return handle;
    }
    private static MethodHandle method(Class<?> type,String name,Class<?> result,boolean isStatic,Class<?>... args) throws ReflectiveOperationException {
        Method m;
        try { m=type.getMethod(name,args); } catch(NoSuchMethodException absent) { m=type.getDeclaredMethod(name,args); }
        if(m.getReturnType()!=result || Modifier.isStatic(m.getModifiers())!=isStatic
                || !java.util.Arrays.equals(m.getParameterTypes(),args))
            throw new NoSuchMethodException("method-contract:"+type.getName()+"."+name);
        MethodHandle h=MethodHandles.privateLookupIn(m.getDeclaringClass(),MethodHandles.lookup()).unreflect(m);
        int receiverCount=isStatic?0:1;
        Class<?>[] erased=new Class<?>[args.length+receiverCount];
        if(!isStatic) erased[0]=Object.class;
        for(int i=0;i<args.length;i++) erased[i+receiverCount]=args[i].isPrimitive()?args[i]:Object.class;
        // Erasure is only a calling convention, never a relaxation of the declared game ABI.
        return h.asType(MethodType.methodType(result.isPrimitive()?result:Object.class,erased));
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
        // The game sets its pedal for this update before choosing the control branch: up while the accelerator is
        // held (from the value applied last), 0.5 while cruise control alone keeps the speed.
        f.pedal=(float)throttle.get(v);
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
        f.driver=p; f.gameInput=f.input=(float)steeringInput.get(input); f.actual=(float)steering.get(c);
        f.keyboard=(boolean)keyboardControlled.invokeExact(v);
        f.inputOpen=f.keyboard && steeringInputOpen(v,p);
        // The game updates physics before refreshing ClientControls. Only veto
        // a stale held direction when that mapped key is no longer held. Never
        // synthesize a new press/reversal or write ClientControls: the game's
        // aiming/loading/drunk input gates remain authoritative for new input.
        if(Float.isFinite(f.input) && Math.abs(f.input)>SteeringModel.INPUT_DEAD_ZONE && Math.abs(f.input)<=1.0001f
                && f.keyboard) {
            boolean left=(boolean)steeringKeyDown.invokeExact("Left");
            boolean right=(boolean)steeringKeyDown.invokeExact("Right");
            int heldDirection=(right?1:0)-(left?1:0);
            if(f.input*heldDirection<=0) f.input=0;
        }
        f.speed=(float)speed.invokeExact(v); f.maximumSpeed=(float)maxSpeed.invokeExact(v);
        f.maximum=(float)steeringClamp.invokeExact(s,Math.abs(f.speed));
        // The same per-update scale the game's own steering line uses.
        f.multiplier=(float)multiplier.invokeExact((Object)time.get())/0.8f;
        f.frame=(int)frameNo.invokeExact(currentWorld);
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
        int gears,frame,power,gear; double rpm,reverseMaxSpeed; float dt,speed,maxSpeed,mass,efficiency,radiusMin,radiusMax,pedal;
        boolean offroad,towing,slow,fast,gas,reverseGas;
        void clear() {
            vehicle=null; engine=null; driver=null; controls=null; script=null; engineType=null;
            gears=frame=power=gear=0; rpm=reverseMaxSpeed=0; dt=speed=maxSpeed=mass=efficiency=radiusMin=radiusMax=pedal=0;
            offroad=towing=slow=fast=gas=reverseGas=false;
        }
    }
    static final class SteeringFrame {
        /** {@code gameInput} is what the game holds; {@code input} is that with an already released key removed. */
        Object driver; int frame; float gameInput,input,actual,maximum,speed,maximumSpeed,multiplier; boolean keyboard,inputOpen;
        void clear() { driver=null; frame=0; gameInput=input=actual=maximum=speed=maximumSpeed=multiplier=0; keyboard=inputOpen=false; }
    }
}
