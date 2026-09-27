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

    VehicleControl(VehicleAccess access,ContinuousProvider.Context context,Settings settings) {
        this.access=access; this.context=context; this.settings=settings;
    }
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
            if(slot==null) { slot=new SteeringSlot(settings.model); steeringStates.put(controller,slot); }
            if(slot.lastFrame==steeringFrame.frame) return originalSteering(slot,"duplicate-frame");
            if(slot.lastFrame+1!=steeringFrame.frame || slot.driver.get()!=steeringFrame.driver) slot.model.reset();
            slot.lastFrame=steeringFrame.frame;
            if(slot.driver.get()!=steeringFrame.driver) slot.driver=new WeakReference<>(steeringFrame.driver);
            double angle=slot.model.step(steeringFrame.input,steeringFrame.actual,steeringFrame.maximum,
                steeringFrame.speed,steeringFrame.maximumSpeed,steeringFrame.dt);
            if(!Double.isFinite(angle)) return originalSteering(slot,"invalid-steering-input-or-dt");
            if(settings.probeOnly) {
                recordSteering(false,"probe-steering-prediction",angle); slot.model.reset(); return VehicleHooks.VANILLA;
            }
            recordSteering(true,"applied",angle);
            access.commitSteering(controller,(float)angle);
            return VehicleHooks.APPLIED;
        } catch(Throwable failure) {
            if(slot!=null) slot.model.reset();
            if(failure instanceof Exception exception) throw exception;
            if(failure instanceof Error error) throw error;
            throw new IllegalStateException(failure);
        } finally {
            steeringFrame.clear();
            if(started!=0) { sampleVersion++; steeringCostNanos=Math.max(0,System.nanoTime()-started); sampleVersion++; }
        }
    }
    private int originalSteering(SteeringSlot slot,String reason) {
        if(slot!=null) slot.model.reset(); recordSteering(false,reason,Double.NaN); return VehicleHooks.VANILLA;
    }
    private void recordSteering(boolean applied,String reason,double angle) {
        if(!settings.diagnostics) return;
        sampleVersion++; steeringSamples++; steeringSampleFrame=steeringFrame.frame;
        steeringSampleInput=steeringFrame.input; steeringSampleMaximum=steeringFrame.maximum;
        steeringSampleAngle=angle; steeringSampleApplied=applied; steeringSampleReason=reason; sampleVersion++;
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
                +";sample_age_ms="+(last==0?-1:Math.max(0,(System.nanoTime()-last)/1_000_000));
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
        windowStart=windowCalls=windowNativeCalls=windowNanos=windowMaximum=0;
        completedCalls=completedNativeCalls=completedNanos=completedMaximum=completedWindowNanos=0;
        lastSampleNanos=0; sampleVersion++;
    }
    void reconfigure(Settings settings) { context.requireGameThread(); clear(); this.settings=settings; }
    static final class Settings {
        final DrivetrainConfig model; final boolean probeOnly,diagnostics;
        Settings(Map<String,String> values) {
            var modelValues=new HashMap<>(values);
            probeOnly=flag(modelValues.remove("probe_only"),"probe_only");
            diagnostics=flag(modelValues.remove("diagnostics_enabled"),"diagnostics_enabled");
            model=DrivetrainConfig.parse(modelValues);
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
        final SteeringModel model; WeakReference<Object> driver=new WeakReference<>(null); int lastFrame=Integer.MIN_VALUE;
        SteeringSlot(DrivetrainConfig config) { model=new SteeringModel(config); }
    }
}
