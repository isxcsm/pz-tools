package pztools.extensions.vehicle;

import java.lang.ref.WeakReference;
import java.util.*;
import pztools.extensions.api.*;
import pztools.extensions.vehicle.model.*;

/** Game-thread model ownership. Only APPLIED commits; every VANILLA interval invalidates dynamics. */
final class VehicleControl implements VehicleHooks.Controller {
    final ContinuousProvider.Context context;
    private final VehicleAccess access;
    private volatile Settings settings;
    private final WeakHashMap<Object,Slot> states=new WeakHashMap<>();
    private final WeakHashMap<Object,SteeringSlot> steeringStates=new WeakHashMap<>();
    private final VehicleAccess.Frame frame=new VehicleAccess.Frame();
    private final VehicleAccess.SteeringFrame steeringFrame=new VehicleAccess.SteeringFrame();
    private volatile boolean invalidated;
    private volatile long sampleVersion;
    private int sampleMode,sampleGear,sampleOutcome;
    private double sampleDt,sampleRpm,sampleForce,sampleSpeed,sampleMass,sampleThrottle,sampleRadiusMin,sampleRadiusMax;
    private boolean sampleOffroad,sampleNativeValid;
    private float sampleNativeForce,sampleNativeBrake,sampleNativeSteering;
    private WeakReference<Object> sampledController=new WeakReference<>(null);
    private String sampleReason="awaiting-controller";
    private long sampleCount,lastSampleNanos,windowStart,windowCalls,windowNativeCalls,windowNanos,windowMaximum;
    private long completedCalls,completedNativeCalls,completedNanos,completedMaximum,completedWindowNanos;
    private long steeringSamples,steeringCostNanos;
    private int steeringSampleFrame;
    private double steeringSampleInput,steeringSampleAngle,steeringSampleMaximum;
    private boolean steeringSampleApplied;
    private String steeringSampleReason="awaiting-controller";

    private final SteeringKeys keys;
    private boolean steeringPrecise;
    private double steeringHeld;
    private boolean steeringSamplePrecise;
    private double steeringSampleHeld;
    private String steeringSampleKeys="not-started",steeringTiming="frame",steeringSampleTiming="frame";

    // The light around the vehicle. Written on the game thread; deactivation reads the first two from any thread.
    private static final long LIGHT_MOVE_NANOS=50_000_000L;
    private volatile Object areaLight;
    private volatile boolean lightStopped;
    private volatile String areaLightState="off";
    private final int[] lightTile=new int[3];
    private int lightX,lightY,lightZ,lightRadius;
    private float lightBrightness;
    private long lightMovedNanos;
    private boolean lightFailed;

    VehicleControl(VehicleAccess access,ContinuousProvider.Context context,Settings settings) { this(access,context,settings,null); }
    VehicleControl(VehicleAccess access,ContinuousProvider.Context context,Settings settings,SteeringKeys.Platform keyPlatform) {
        this.access=access; this.context=context; this.settings=settings; keys=new SteeringKeys(access,keyPlatform);
    }
    /** Any thread, never blocks: the key-measuring thread must not outlive the activation. */
    void stopKeys() { keys.stop(); }
    /**
     * Once per game frame, driving or not. The light sits on the tile of the vehicle the player is
     * in while its headlights are lit, and follows it tile by tile as the game's own lightbar glow
     * does. A fault here ends only the light for this activation; driving assistance carries on.
     */
    void gameFrame() {
        if(Thread.currentThread()!=context.gameThread()) return;
        keys.retireIfIdle(System.nanoTime());
        Settings current=settings;
        if(!current.areaLight || lightStopped || lightFailed) {
            if(areaLight!=null) removeAreaLight();
            if(!lightFailed) areaLightState="off";
            return;
        }
        try {
            if(!access.areaLightResolved()) { areaLightState="unavailable"; return; }
            if(!access.areaLightTarget(context,lightTile)) { removeAreaLight(); areaLightState="waiting"; return; }
            int radius=current.model.areaLightRadius; float brightness=(float)current.model.areaLightBrightness;
            boolean same=radius==lightRadius && brightness==lightBrightness;
            if(areaLight!=null && same) {
                if(lightTile[0]==lightX && lightTile[1]==lightY && lightTile[2]==lightZ) return;
                // Each move makes the game relight the surroundings; at speed, not on every single tile.
                if(System.nanoTime()-lightMovedNanos<LIGHT_MOVE_NANOS) return;
            }
            removeAreaLight();
            // Slightly warm, like a headlamp's spill, rather than pure white.
            Object next=access.placeLight(context,lightTile[0],lightTile[1],lightTile[2],brightness,brightness*0.95f,brightness*0.85f,radius);
            lightX=lightTile[0]; lightY=lightTile[1]; lightZ=lightTile[2]; lightRadius=radius; lightBrightness=brightness;
            lightMovedNanos=System.nanoTime();
            areaLight=next; areaLightState="lit";
            if(lightStopped) access.expireLight(next);
        } catch(Throwable failure) {
            lightFailed=true; areaLightState="failed:"+failure.getClass().getSimpleName();
            try { removeAreaLight(); } catch(Throwable ignored) { }
        }
    }
    private void removeAreaLight() {
        Object light=areaLight;
        if(light==null) return;
        areaLight=null;
        try { access.removeLight(context,light); }
        catch(Throwable failure) { access.expireLight(light); }
    }
    /** Any thread, never blocks: the light must not outlive the activation that made it. */
    void stopLight() {
        lightStopped=true;
        Object light=areaLight;
        if(light!=null) access.expireLight(light);
    }
    String areaLightState() { return areaLightState; }
    @Override public int tryControl(Object controller,int mode,float speed) throws Exception {
        if(mode==VehicleHooks.STEERING) return trySteering(controller);
        if(Thread.currentThread()!=context.gameThread()) { invalidated=true; return VehicleHooks.VANILLA; }
        long started=settings.diagnostics?System.nanoTime():0;
        if(settings.diagnostics && sampledController.get()!=controller) sampledController=new WeakReference<>(controller);
        if(invalidated) { states.clear(); steeringStates.clear(); invalidated=false; }
        Slot slot=states.get(controller);
        try {
            if(mode==VehicleHooks.FORWARD && !settings.model.torqueEnabled) return vanilla(slot,mode,"forward-disabled");
            if(mode==VehicleHooks.REVERSE && !settings.model.reverseEnabled) return vanilla(slot,mode,"reverse-disabled");
            String rejected=access.read(controller,context,frame);
            if(rejected!=null) return vanilla(slot,mode,rejected);
            if(mode==VehicleHooks.BRAKING || mode==VehicleHooks.NO_CONTROL) return vanilla(slot,mode,"original-coast-or-brake");
            if(mode!=VehicleHooks.FORWARD && mode!=VehicleHooks.REVERSE) return vanilla(slot,mode,"unknown-mode");
            if(!Float.isFinite(speed) || !Float.isFinite(frame.dt) || frame.dt<=0 || frame.dt>settings.model.maxDtSeconds)
                return vanilla(slot,mode,"invalid-or-long-dt");
            if(slot==null) { slot=new Slot(settings.model); states.put(controller,slot); }
            if(slot.lastFrame==frame.frame) return vanilla(slot,mode,"duplicate-frame");
            if(slot.lastFrame+1!=frame.frame || slot.driver.get()!=frame.driver) slot.model.reset();
            slot.lastFrame=frame.frame;
            if(slot.driver.get()!=frame.driver) slot.driver=new WeakReference<>(frame.driver);
            if(slot.profile==null || slot.profile.gearCount!=frame.gears || slot.profile.maxSpeedKph!=frame.maxSpeed
                    || !slot.profile.engineRpmType.equals(frame.engineType)) {
                slot.model.reset(); slot.profile=VehicleProfile.resolve(frame.engineType,frame.gears,frame.maxSpeed,settings.model);
            }
            if(slot.profile==null) return vanilla(slot,mode,"unsupported-profile");
            var in=slot.input;
            in.dtSeconds=frame.dt; in.speedMps=frame.speed/3.6; in.enginePower=frame.power; in.engineRpm=frame.rpm;
            in.reverseMaxSpeedKph=frame.reverseMaxSpeed;
            in.throttle=1; // The resolved mode already includes cruise and input safety decisions.
            in.direction=mode==VehicleHooks.FORWARD?1:-1; in.currentGear=frame.gear; in.profile=slot.profile;
            in.offroad=frame.offroad; in.offroadEfficiency=frame.efficiency; in.towing=frame.towing;
            in.sundayDriver=frame.slow; in.speedDemon=frame.fast;
            slot.model.step(in,slot.output);
            var out=slot.output;
            if(out.decision==DrivetrainModel.Decision.VANILLA) return vanilla(slot,mode,"model-declined");
            if(settings.probeOnly) {
                record(mode,VehicleHooks.VANILLA,"probe-one-step-prediction",out);
                slot.model.reset(); return VehicleHooks.VANILLA;
            }
            if(out.decision==DrivetrainModel.Decision.DIRECTION_HOLD) {
                record(mode,VehicleHooks.DIRECTION_HOLD,"direction-hold",out);
                return VehicleHooks.DIRECTION_HOLD;
            }
            if(!Double.isFinite(out.engineForce) || !Double.isFinite(out.engineRpm) || !Double.isFinite(out.throttle)
                    || Math.abs(out.engineForce)>1_000_000 || out.engineRpm<0 || out.engineRpm>7000 || out.throttle<0 || out.throttle>1
                    || out.engineForce*in.direction<0 || (in.direction<0?out.gear!=-1:out.gear<1 || out.gear>frame.gears))
                throw new IllegalStateException("invalid-model-output");
            Object gear=access.gearObject(out.gear);
            if(!access.canCommit(controller,frame,gear)) throw new IllegalStateException("invalid-commit-target");
            int flags=VehicleHooks.APPLIED | (out.ownOffroad?VehicleHooks.OWN_OFFROAD:0);
            record(mode,flags,"applied",out); // No potentially throwing work follows the first field write.
            access.commit(controller,frame,gear,(float)out.engineForce,out.engineRpm,(float)out.throttle);
            return flags;
        } catch(Throwable failure) {
            if(slot!=null) slot.model.reset();
            if(failure instanceof Exception exception) throw exception;
            if(failure instanceof Error error) throw error;
            throw new IllegalStateException(failure);
        } finally { frame.clear(); if(started!=0) recordCost(started); }
    }
    private int trySteering(Object controller) throws Exception {
        if(Thread.currentThread()!=context.gameThread()) { invalidated=true; return VehicleHooks.VANILLA; }
        if(invalidated) { states.clear(); steeringStates.clear(); invalidated=false; }
        long started=settings.diagnostics?System.nanoTime():0;
        SteeringSlot slot=steeringStates.get(controller);
        try {
            if(!settings.model.steeringEnabled) return originalSteering(slot,"steering-disabled");
            String rejected=access.readSteering(controller,context,steeringFrame);
            if(rejected!=null) return originalSteering(slot,rejected);
            if(slot==null) { slot=new SteeringSlot(); steeringStates.put(controller,slot); }
            boolean sameDriver=slot.driver.get()==steeringFrame.driver;
            if(slot.lastFrame==steeringFrame.frame && sameDriver) {
                if(!SteeringModel.accepts(steeringFrame.gameInput,steeringFrame.actual,steeringFrame.multiplier,
                        steeringFrame.speed,steeringFrame.maximumSpeed,0))
                    return originalSteering(slot,"invalid-steering-input-or-step");
                if(!slot.applied) return originalSteering(slot,"duplicate-frame");
                // A completed physics frame owns one integration, even if input changes before a repeated callback.
                // Restore the pre-tire value: replaying the already adjusted field would compound tire correction.
                recordSteering(true,"duplicate-frame-applied",slot.appliedAngle);
                access.commitSteering(controller,slot.appliedAngle);
                return VehicleHooks.APPLIED;
            }
            if(slot.lastFrame+1!=steeringFrame.frame || !sameDriver) slot.reset();
            slot.applied=false;
            slot.lastFrame=steeringFrame.frame;
            if(!sameDriver) slot.driver=new WeakReference<>(steeringFrame.driver);
            // Without a trustworthy measurement this is the game's own step: the whole update, by its input.
            double input=steeringFrame.input, held=Math.abs(input)>SteeringModel.INPUT_DEAD_ZONE?1:0;
            boolean heldAtEnd=true;
            steeringPrecise=false; steeringTiming="frame";
            if(settings.model.steeringPreciseInput && steeringFrame.keyboard && measure(slot)) {
                if(steeringFrame.inputOpen) {
                    // The keys themselves are the input: the game accepts steering right now, so nothing
                    // waits for its once-per-frame look at the keyboard. A tap that falls between two
                    // frames, however long the frame, steers for exactly as long as it was held.
                    double net=(double)(slot.right-slot.left)/slot.update;
                    input=net>0?1:net<0?-1:0; held=Math.min(1,Math.abs(net));
                    heldAtEnd=input>0?slot.rightDown && !slot.leftDown:input<0 && slot.leftDown && !slot.rightDown;
                    slot.input.reset(); steeringPrecise=true; steeringTiming="direct";
                } else if(slot.input.update(steeringFrame.gameInput,slot.left,slot.right,slot.update,slot.leftDown,slot.rightDown)) {
                    input=steeringFrame.gameInput; held=slot.input.fraction; heldAtEnd=slot.input.heldAtEnd;
                    steeringPrecise=true; steeringTiming="confirmed";
                }
            } else slot.input.reset();
            steeringHeld=held; steeringFrame.input=(float)input;
            // Where the unheld part of the update goes. Physics only sees the value an update ends
            // with, so returning right after a key is let go would hide the tap: the wheels would
            // be back before anything turned, and by how much would depend on where in the frame
            // the tap happened to end. Instead the steering is left standing for this update and
            // the return it is owed is carried into the next one. No return is lost, only moved,
            // and what a tap leaves behind depends on how long it was held and nothing else.
            // A key that is down at the end was pressed after the gap, so the gap returns first.
            double unheld=Math.max(0,1-held), before=slot.returnOwed, carried=0;
            if(held<=0 || heldAtEnd) before+=unheld; else carried=unheld;
            double angle=SteeringModel.advance(input,steeringFrame.actual,steeringFrame.multiplier,
                steeringFrame.speed,steeringFrame.maximumSpeed,Math.min(SteeringModel.MAXIMUM_RELEASE,before),held,0);
            slot.returnOwed=carried;
            if(!Double.isFinite(angle)) return originalSteering(slot,"invalid-steering-input-or-step");
            if(settings.probeOnly) {
                recordSteering(false,"probe-steering-prediction",angle); slot.reset(); return VehicleHooks.VANILLA;
            }
            recordSteering(true,"applied",angle);
            access.commitSteering(controller,(float)angle);
            slot.appliedAngle=(float)angle; slot.applied=true;
            return VehicleHooks.APPLIED;
        } catch(Throwable failure) {
            if(slot!=null) { slot.reset(); slot.applied=false; }
            if(failure instanceof Exception exception) throw exception;
            if(failure instanceof Error error) throw error;
            throw new IllegalStateException(failure);
        } finally {
            steeringFrame.clear();
            if(started!=0) { sampleVersion++; steeringCostNanos=Math.max(0,System.nanoTime()-started); sampleVersion++; }
        }
    }
    /**
     * How much of this update the steering keys were really down. False whenever that cannot be
     * said with confidence: the first update after a gap, a starved measuring thread, keys that
     * cannot be timed. The caller then steers by the game's input, as the game itself would.
     */
    private boolean measure(SteeringSlot slot) {
        if(!keys.read()) { slot.primed=false; return false; }
        var now=keys.reading;
        boolean comparable=slot.primed && slot.generation==keys.generation;
        long update=now.clock-slot.clock, unreliable=now.unreliable-slot.unreliable;
        slot.left=comparable?keys.held(slot.held,0):0; slot.right=comparable?keys.held(slot.held,1):0;
        slot.update=update; slot.leftDown=keys.down(0); slot.rightDown=keys.down(1);
        slot.primed=true; slot.generation=keys.generation; slot.clock=now.clock; slot.unreliable=now.unreliable;
        System.arraycopy(now.held,0,slot.held,0,keys.keyCount());
        return comparable && update>0 && unreliable==0;
    }
    private int originalSteering(SteeringSlot slot,String reason) {
        if(slot!=null) { slot.reset(); slot.applied=false; }
        recordSteering(false,reason,Double.NaN); return VehicleHooks.VANILLA;
    }
    private void recordSteering(boolean applied,String reason,double angle) {
        if(!settings.diagnostics) return;
        sampleVersion++; steeringSamples++; steeringSampleFrame=steeringFrame.frame;
        steeringSampleInput=steeringFrame.input; steeringSampleMaximum=steeringFrame.maximum;
        steeringSampleAngle=angle; steeringSampleApplied=applied; steeringSampleReason=reason;
        steeringSamplePrecise=applied && steeringPrecise; steeringSampleHeld=applied?steeringHeld:0; steeringSampleKeys=keys.state;
        steeringSampleTiming=applied?steeringTiming:"frame";
        sampleVersion++;
    }
    private int vanilla(Slot slot,int mode,String reason) {
        if(slot!=null) slot.model.reset();
        record(mode,VehicleHooks.VANILLA,reason,null); return VehicleHooks.VANILLA;
    }
    private void record(int mode,int outcome,String reason,DrivetrainModel.Output output) {
        if(!settings.diagnostics) return;
        sampleVersion++; sampleMode=mode; sampleOutcome=outcome; sampleReason=reason;
        sampleDt=frame.dt; sampleSpeed=frame.speed; sampleMass=frame.mass;
        sampleOffroad=frame.offroad; sampleRadiusMin=frame.radiusMin; sampleRadiusMax=frame.radiusMax;
        sampleThrottle=output==null?0:output.throttle; sampleNativeValid=false;
        sampleNativeForce=sampleNativeBrake=sampleNativeSteering=0;
        sampleGear=output==null?frame.gear:output.gear; sampleRpm=output==null?frame.rpm:output.engineRpm;
        sampleForce=output==null?0:output.engineForce; sampleCount++; lastSampleNanos=System.nanoTime(); sampleVersion++;
    }
    private void recordCost(long started) {
        long now=System.nanoTime(), cost=Math.max(0,now-started);
        sampleVersion++;
        if(windowStart==0) windowStart=started;
        windowCalls++; windowNanos+=cost; windowMaximum=Math.max(windowMaximum,cost);
        if(now-windowStart>=1_000_000_000L) {
            completedCalls=windowCalls; completedNativeCalls=windowNativeCalls;
            completedNanos=windowNanos; completedMaximum=windowMaximum; completedWindowNanos=now-windowStart;
            windowStart=now; windowCalls=windowNativeCalls=windowNanos=windowMaximum=0;
        }
        sampleVersion++;
    }
    @Override public void observeNative(Object controller,float force,float brake,float steering) {
        if(!settings.diagnostics || Thread.currentThread()!=context.gameThread() || !context.worldValid().get()
                || sampledController.get()!=controller) return;
        sampleVersion++;
        sampleNativeForce=force; sampleNativeBrake=brake; sampleNativeSteering=steering;
        sampleNativeValid=true; windowNativeCalls++; sampleVersion++;
    }
    String diagnostics() {
        if(!settings.diagnostics) return "";
        for(int attempt=0;attempt<3;attempt++) {
            long before=sampleVersion; if((before&1)!=0) continue;
            int mode=sampleMode,gear=sampleGear,outcome=sampleOutcome;
            double dt=sampleDt,rpm=sampleRpm,force=sampleForce,speed=sampleSpeed,mass=sampleMass;
            double throttle=sampleThrottle,radiusMin=sampleRadiusMin,radiusMax=sampleRadiusMax;
            boolean road=sampleOffroad,nativeValid=sampleNativeValid;
            float nativeForce=sampleNativeForce,nativeBrake=sampleNativeBrake,nativeSteering=sampleNativeSteering;
            String reason=sampleReason; long count=sampleCount,last=lastSampleNanos;
            long calls=completedCalls,nativeCalls=completedNativeCalls,nanos=completedNanos,maximum=completedMaximum,window=completedWindowNanos;
            long steeringCount=steeringSamples,steeringCost=steeringCostNanos; int steeringFrameNumber=steeringSampleFrame;
            double steeringInput=steeringSampleInput,steeringAngle=steeringSampleAngle,steeringMaximum=steeringSampleMaximum;
            boolean steeringApplied=steeringSampleApplied; String steeringReason=steeringSampleReason;
            boolean precise=steeringSamplePrecise; double heldShare=steeringSampleHeld; String keyState=steeringSampleKeys,timing=steeringSampleTiming;
            if(before!=sampleVersion) continue;
            return "mode="+mode+";outcome="+outcome+";reason="+reason+";samples="+count+";dt_seconds="+dt
                +";gear="+gear+";rpm="+rpm+";requested_force="+force+";speed_kph="+speed+";mass="+mass
                +";throttle="+throttle+";offroad="+road+";wheel_radius_min="+radiusMin+";wheel_radius_max="+radiusMax
                +";native_args_observed="+nativeValid+";native_force="+nativeForce+";native_brake="+nativeBrake+";native_steering="+nativeSteering
                +";window_ms="+window/1_000_000+";window_calls="+calls+";window_native_calls="+nativeCalls
                +";callback_mean_us="+(calls==0?0:nanos/calls/1000)+";callback_max_us="+maximum/1000
                +";steering_samples="+steeringCount+";steering_frame="+steeringFrameNumber+";steering_reason="+steeringReason
                +";steering_applied="+steeringApplied+";steering_input="+steeringInput+";steering_requested="+steeringAngle
                +";steering_max="+steeringMaximum+";steering_callback_us="+steeringCost/1000
                +";steering_precise="+precise+";steering_timing="+timing+";steering_held_share="+heldShare+";steering_keys="+keyState
                +";sample_age_ms="+(last==0?-1:Math.max(0,(System.nanoTime()-last)/1_000_000))
                +";area_light="+areaLightState;
        }
        return "snapshot=updating";
    }
    void clear() {
        states.clear(); steeringStates.clear(); frame.clear(); steeringFrame.clear(); sampledController.clear();
        sampleVersion++;
        sampleNativeValid=false; sampleNativeForce=sampleNativeBrake=sampleNativeSteering=0;
        sampleCount=0; sampleMode=sampleGear=sampleOutcome=0; sampleReason="awaiting-controller";
        sampleDt=sampleRpm=sampleForce=sampleSpeed=sampleMass=sampleThrottle=sampleRadiusMin=sampleRadiusMax=0;
        sampleOffroad=false;
        steeringSamples=steeringCostNanos=0; steeringSampleFrame=0;
        steeringSampleInput=steeringSampleAngle=steeringSampleMaximum=0;
        steeringSampleApplied=false; steeringSampleReason="awaiting-controller";
        steeringSamplePrecise=false; steeringSampleHeld=0; steeringSampleKeys="not-started"; steeringSampleTiming="frame"; keys.clear();
        windowStart=windowCalls=windowNativeCalls=windowNanos=windowMaximum=0;
        completedCalls=completedNativeCalls=completedNanos=completedMaximum=completedWindowNanos=0;
        lastSampleNanos=0; sampleVersion++;
    }
    void reconfigure(Settings settings) { context.requireGameThread(); clear(); this.settings=settings; }
    static final class Settings {
        final DrivetrainConfig model; final boolean probeOnly,diagnostics,areaLight;
        Settings(Map<String,String> values) {
            var modelValues=new HashMap<>(values);
            probeOnly=flag(modelValues.remove("probe_only"),"probe_only");
            diagnostics=flag(modelValues.remove("diagnostics_enabled"),"diagnostics_enabled");
            model=DrivetrainConfig.parse(modelValues);
            // Observation-only mode changes nothing in the game, a light included.
            areaLight=model.areaLightEnabled && !probeOnly;
        }
        private static boolean flag(String value,String key) {
            if(value==null || value.equals("false")) return false;
            if(value.equals("true")) return true;
            throw new IllegalArgumentException(key+" must be true or false");
        }
    }
    private static final class Slot {
        final DrivetrainModel model; final DrivetrainModel.Input input=new DrivetrainModel.Input();
        final DrivetrainModel.Output output=new DrivetrainModel.Output();
        VehicleProfile profile; WeakReference<Object> driver=new WeakReference<>(null); int lastFrame=Integer.MIN_VALUE;
        Slot(DrivetrainConfig config) { model=new DrivetrainModel(config); }
    }
    private static final class SteeringSlot {
        final HeldInput input=new HeldInput(); WeakReference<Object> driver=new WeakReference<>(null); int lastFrame=Integer.MIN_VALUE;
        float appliedAngle; boolean applied;
        // The key totals at this controller's previous update; differences give the time held since.
        final long[] held=new long[4]; long clock,unreliable; int generation; boolean primed;
        // This update's measurement: time each side was down, the span it covers, and what is down now.
        long left,right,update; boolean leftDown,rightDown;
        // Return time from an update in which a key was let go, to be spent at the start of the next.
        double returnOwed;
        void reset() { input.reset(); primed=false; returnOwed=0; }
    }
}
