package pztools.extensions.vehicle;

import java.lang.classfile.ClassFile;
import java.lang.reflect.*;
import java.net.*;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.atomic.AtomicBoolean;
import pztools.extensions.api.*;

/** Executes only hand-authored fixtures. No installed game method or native library is called. */
public final class VehicleAdapterBehaviorTest {
    private static Path fixture;
    private static int groups;
    public static void main(String[] args) throws Throwable {
        if(args.length!=1) throw new IllegalArgumentException("fixture classes directory required");
        fixture=Path.of(args[0]);
        inert(); appliedBoundary(); holdBoundary(); adapterAndReset(); directionChange(); rejects(); probeAndReadiness(); invalidation();
        originalIntervalsResetHighGear(); enginePowerAndMass(); noDriverAndPausedRetirement(); repeatedCallbackGenerations();
        resolvedInputSentinels(); cellReplacement(); nativeObservationIsolation();
        independentToggleMatrix(); steeringBehavior(); steeringGuardsAndResets(); steeringPhaseFailure();
        System.out.println("PASS vehicle adapter: "+groups+" groups (synthetic classes only)");
    }
    private static void inert() throws Throwable {
        for(int mode=0;mode<=3;mode++) try(var e=new Env()) {
            e.set(e.controller,"request",mode); e.set(e.vehicle,"offroad",true); e.set(e.controller,"tireFactor",.5f);
            e.tick();
            near(e.nativeForce(),mode==1?11*.5*.25:mode==2?-13*.5*.25:0,"inert force");
            near(e.number(e.controller,"brakeCalls"),mode==3?1:0,"inert braking count");
            check(e.bool(e.controller,"backSignal")== (mode==2),"inert reverse signal");
        }
        try(var e=new Env()) {
            e.set(e.controller,"request",1); e.set(e.vehicle,"running",false); e.tick();
            near(e.number(e.controller,"startRequests"),1,"original start request");
            near(e.staticNumber("zombie.core.physics.Bullet","calls"),2,"engine-off second native");
            near(e.nativeForce(),0,"engine-off final zero");
        }
        groups++;
    }
    private static void appliedBoundary() throws Throwable {
        try(var e=new Env()) {
            e.set(e.controller,"request",1); e.set(e.vehicle,"offroad",true); e.set(e.controller,"tireFactor",.5f);
            int[] calls={0};
            e.register((c,m,s)-> { calls[0]++; check(m==VehicleHooks.FORWARD,"resolved forward"); e.set(c,"engineForce",100f); return VehicleHooks.APPLIED|VehicleHooks.OWN_OFFROAD; });
            e.tick();
            near(calls[0],1,"exactly one callback"); near(e.number(e.controller,"forwardCalls"),0,"skip only owned control");
            near(e.nativeForce(),50,"tire once and legacy offroad skipped"); near(e.number(e.controller,"speedRequests"),1,"later original branch");
            e.unregister(); e.tick(); near(e.nativeForce(),11*.5*.25,"retired hook is original");
        }
        try(var e=new Env()) {
            e.set(e.controller,"request",2); e.register((c,m,s)->{ e.set(c,"engineForce",-100f); return VehicleHooks.APPLIED; });
            e.tick(); near(e.number(e.controller,"reverseCalls"),0,"reverse skip"); check(e.bool(e.controller,"backSignal"),"reverse signal retained");
        }
        groups++;
    }
    private static void holdBoundary() throws Throwable {
        try(var e=new Env()) {
            e.set(e.controller,"request",2); e.set(e.vehicle,"throttle",1f);
            e.register((c,m,s)->VehicleHooks.DIRECTION_HOLD); e.tick();
            near(e.number(e.controller,"reverseCalls"),0,"hold does not propel"); near(e.number(e.controller,"brakeCalls"),1,"one original braking call");
            check(e.bool(e.controller,"brakeLights"),"hold brake light"); check(!e.bool(e.controller,"backSignal"),"hold reverse signal cleared");
            near(e.number(e.vehicle,"throttle"),0,"hold throttle cleared"); near(e.nativeForce(),0,"hold zero force");
            near(e.staticNumber("zombie.core.physics.Bullet","brake"),17,"original braking magnitude");
        }
        groups++;
    }
    private static void adapterAndReset() throws Throwable {
        try(var e=new Env()) {
            VehicleControl control=e.adapter(Map.of("diagnostics_enabled","true"));
            e.set(e.controller,"request",1); e.set(e.controller,"tireFactor",.5f); e.set(e.vehicle,"offroad",true);
            Object inputs=e.get(e.controller,"clientControls"); e.set(inputs,"wasUsingParkingBrakes",true);
            e.tick(); double first=e.nativeForce(); check(first>0,"model positive force");
            near(e.number(e.controller,"forwardCalls"),0,"adapter skipped original forward");
            near(first,diagnostic(control,"requested_force")*.5,"offroad not duplicated after model");
            near(diagnostic(control,"native_force"),first,"native observation is the final tire-adjusted force");
            check(control.diagnostics().contains("native_args_observed=true"),"native observation is explicitly marked");
            check(!e.bool(inputs,"wasUsingParkingBrakes"),"applied consumes original parking boost");
            for(int i=0;i<10;i++) e.tick(); check(e.nativeForce()>first,"ramp advances");
            e.set(e.controller,"request",0); e.tick(); near(e.number(e.controller,"coastCalls"),1,"coast remains original");
            e.set(e.controller,"request",1); e.tick(); near(e.nativeForce(),first,"coast invalidates model ramp");
            e.set(e.controller,"request",3); e.tick(); near(e.number(e.controller,"brakeCalls"),1,"braking remains original");
            e.set(e.controller,"request",1); e.tick(); near(e.nativeForce(),first,"braking invalidates model ramp");
            e.unregister(); e.set(e.vehicle,"offroad",false); e.set(e.controller,"tireFactor",1f); e.tick();
            near(e.nativeForce(),11,"parking boost cannot reappear after retiring applied control");
        }
        groups++;
    }
    private static void directionChange() throws Throwable {
        try(var e=new Env()) {
            e.adapter(Map.of()); e.set(e.controller,"request",1); e.tick();
            e.set(e.controller,"request",2); e.set(e.vehicle,"speed",2f); e.tick();
            near(e.nativeForce(),0,"opposed motion held"); near(e.number(e.controller,"brakeCalls"),1,"hold routed to original braking");
            e.set(e.vehicle,"speed",0f);
            for(int i=0;i<12;i++) e.tick();
            check(e.nativeForce()<0,"reverse eventually ramps"); near(e.number(e.controller,"reverseCalls"),0,"reverse remained owned");
            near((Number)e.invoke(e.vehicle,"getTransmissionNumber"),-1,"reverse game gear");
            check(e.bool(e.controller,"backSignal"),"reverse sound signal returns after hold");
        }
        groups++;
    }
    private static void rejects() throws Throwable {
        try(var e=new Env()) {
            VehicleControl control=e.adapter(Map.of("diagnostics_enabled","true")); e.set(e.controller,"request",1);
            e.tick(); double initial=e.nativeForce(); for(int i=0;i<5;i++) e.tick();
            e.update(); near(e.nativeForce(),11,"duplicate frame original"); check(control.diagnostics().contains("duplicate-frame"),"duplicate reason");
            e.tick(); check(e.nativeForce()<=initial*1.15,"duplicate rejection resets ramp while resynchronizing current RPM");
            e.set(e.time,"dt",1f); e.tick(); near(e.nativeForce(),11,"long dt original");
            e.set(e.time,"dt",1f/60); e.tick(); check(e.nativeForce()<=initial*1.15,"pause gap rebase");
            for(int i=0;i<12;i++) e.tick();
            e.set(e.time,"dt",0f); e.tick(); near(e.nativeForce(),11,"zero dt returns original rather than prior model force");
            check(control.diagnostics().contains("invalid-or-long-dt"),"zero dt diagnostic");
            e.set(e.time,"dt",1f/60); e.tick(); check(e.nativeForce()<=initial*1.15,"zero dt discards prior model ramp");
            Object script=e.get(e.vehicle,"script"); e.set(script,"engineRpmType","modded-unknown"); e.tick(); near(e.nativeForce(),11,"unknown profile original");
            e.set(script,"engineRpmType","generic"); e.setStatic("zombie.network.GameClient","client",true); e.tick(); near(e.nativeForce(),11,"multiplayer original");
            check(control.diagnostics().contains("mass=0.0"),"early rejection does not expose prior sample fields");
            e.setStatic("zombie.network.GameClient","client",false); e.set(e.vehicle,"towedBy",e.vehicle); e.tick(); near(e.nativeForce(),11,"towed original");
            e.set(e.vehicle,"towedBy",null); e.set(e.vehicle,"running",false); e.tick();
            near(e.number(e.controller,"startRequests"),1,"adapter rejection preserves starting"); near(e.nativeForce(),0,"engine off ends with native zero");
        }
        groups++;
    }
    private static void probeAndReadiness() throws Throwable {
        try(var e=new Env()) {
            VehicleAccess access=new VehicleAccess(e.loader);
            check(access.ready(e.context),"stationary ready"); e.set(e.vehicle,"speed",2f); check(!access.ready(e.context),"moving waits");
            e.set(e.vehicle,"speed",0f); e.set(e.vehicle,"throttle",1f); check(!access.ready(e.context),"throttle waits");
            e.set(e.vehicle,"throttle",0f); e.set(e.vehicle,"regulator",true); check(!access.ready(e.context),"cruise waits"); e.set(e.vehicle,"regulator",false);
            VehicleControl control=e.adapter(Map.of("probe_only","true","diagnostics_enabled","true"));
            e.set(e.controller,"request",1); e.tick(); near(e.nativeForce(),11,"probe original force");
            near((Number)e.invoke(e.vehicle,"getTransmissionNumber"),0,"probe does not set gear");
            near((Number)e.invoke(e.vehicle,"getEngineSpeed"),800,"probe does not set rpm"); near(e.number(e.vehicle,"throttle"),0,"probe no throttle commit");
            check(control.diagnostics().contains("probe-one-step-prediction"),"probe diagnostic");
            check(diagnostic(control,"requested_force")>0,"probe has prediction");
            check(control.diagnostics().contains("native_args_observed=true"),"probe observes native arguments");
            near(diagnostic(control,"native_force"),11,"probe records original native force, not model prediction");
            near(diagnostic(control,"native_brake"),0,"probe records original brake argument");
            e.set(e.vehicle,"offroad",true); e.set(e.controller,"tireFactor",.5f); e.tick();
            near(diagnostic(control,"native_force"),11*.5*.25,"probe preserves original tire and dirt factors");
            double calls=e.staticNumber("zombie.core.physics.Bullet","calls").doubleValue();
            e.set(e.vehicle,"running",false); e.tick();
            near(e.staticNumber("zombie.core.physics.Bullet","calls"),calls+2,"engine-off retains both original native calls");
            near(diagnostic(control,"native_force"),0,"native observation captures second engine-off zero-force call");
            check(control.diagnostics().contains("native_args_observed=true"),"engine-off final native observation remains explicit");
        }
        groups++;
    }
    private static void invalidation() throws Throwable {
        try(var e=new Env()) {
            VehicleControl control=e.adapter(Map.of()); e.set(e.controller,"request",1); e.tick(); double first=e.nativeForce();
            for(int i=0;i<8;i++) e.tick();
            Thread other=new Thread(()->check(controlCall(control,e.controller)==VehicleHooks.VANILLA,"wrong-thread fallback")); other.start(); other.join();
            e.tick(); check(e.nativeForce()<=first*1.15,"wrong-thread invalidates state");
            e.context.worldValid().set(false); e.tick(); near(e.nativeForce(),11,"ended world remains original");
            e.unregister(); e.register((c,m,s)->{throw new IllegalStateException("synthetic failure before commit");}); e.tick();
            near(e.nativeForce(),11,"fault fallback"); check(VehicleHooks.failure(e.owner)!=null,"fault visible");
        }
        groups++;
    }
    private static void originalIntervalsResetHighGear() throws Throwable {
        double freshForce, freshRpm;
        try(var e=new Env()) {
            e.adapter(Map.of()); e.set(e.controller,"request",1); e.tick();
            freshForce=e.nativeForce(); freshRpm=((Number)e.invoke(e.vehicle,"getEngineSpeed")).doubleValue();
        }
        for(int originalMode:new int[]{0,3}) try(var e=new Env()) {
            e.adapter(Map.of()); e.set(e.controller,"request",1); e.set(e.vehicle,"speed",90f);
            for(int i=0;i<180;i++) e.tick();
            check(((Number)e.invoke(e.vehicle,"getTransmissionNumber")).intValue()>1,"fixture reached a higher gear");
            check(((Number)e.invoke(e.vehicle,"getEngineSpeed")).doubleValue()>3000,"fixture reached elevated RPM");
            e.set(e.controller,"request",originalMode); e.set(e.vehicle,"speed",0f); e.tick();
            near((Number)e.invoke(e.vehicle,"getTransmissionNumber"),0,"original coast/brake preserves its neutral gear");
            near((Number)e.invoke(e.vehicle,"getEngineSpeed"),800,"original coast/brake preserves its RPM");
            e.set(e.controller,"request",1); e.tick();
            near(e.nativeForce(),freshForce,"resume cannot leak old high-gear force or pedal state");
            near((Number)e.invoke(e.vehicle,"getEngineSpeed"),freshRpm,"resume uses original current RPM");
            near((Number)e.invoke(e.vehicle,"getTransmissionNumber"),1,"resume reacquires first from original neutral");
        }
        groups++;
    }
    private static void enginePowerAndMass() throws Throwable {
        double reference=Double.NaN;
        for(int variant=0;variant<3;variant++) try(var e=new Env()) {
            e.set(e.vehicle,"mass",variant==1?6000f:1000f);
            e.set(e.vehicle,"enginePower",variant==2?2000:1000);
            VehicleControl control=e.adapter(Map.of("diagnostics_enabled","true")); e.set(e.controller,"request",1);
            for(int i=0;i<90;i++) e.tick();
            if(variant==0) reference=e.nativeForce();
            else near(e.nativeForce(),reference*(variant==2?2:1),"cargo mass never scales force; engine power scales exactly once");
            near(e.number(e.vehicle,"mass"),variant==1?6000:1000,"adapter never mutates loaded vehicle mass");
            near(diagnostic(control,"mass"),variant==1?6000:1000,"loaded mass is observation only");
        }
        groups++;
    }
    private static void noDriverAndPausedRetirement() throws Throwable {
        try(var e=new Env()) {
            VehicleControl control=e.adapter(Map.of("diagnostics_enabled","true")); e.set(e.controller,"request",1); e.tick();
            Object player=e.get(e.vehicle,"driver"); e.set(e.vehicle,"driver",null); e.tick();
            near(e.nativeForce(),11,"driver exit restores original control");
            check(control.diagnostics().contains("not-local-driver"),"driver exit reason");
            e.set(player,"vehicle",null);
            check(new VehicleAccess(e.loader).ready(e.context),"no-car state does not await an absent vehicle callback");
            e.set(e.time,"dt",0f);
            e.unregister(); // Must drain without waiting for another physics callback.
            int[] callbacks={0}; e.register((c,m,s)->{callbacks[0]++; return VehicleHooks.VANILLA;});
            e.tick(); near(callbacks[0],1,"new generation can register after paused retirement");
            near(e.nativeForce(),11,"paused retirement never writes stored model force");
        }
        groups++;
    }
    private static void repeatedCallbackGenerations() throws Throwable {
        try(var e=new Env()) {
            int[] callbacks=new int[3]; e.set(e.controller,"request",1);
            for(int generation=0;generation<3;generation++) {
                final int index=generation;
                e.register((c,m,s)->{callbacks[index]++; e.set(c,"engineForce",100f*(index+1)); return VehicleHooks.APPLIED;});
                e.tick(); near(e.nativeForce(),100*(index+1),"replacement callback alone controls native force");
                e.unregister(); e.tick(); near(e.nativeForce(),11,"retired callback returns to original between generations");
                for(int retired=0;retired<=generation;retired++) near(callbacks[retired],1,"retired generation receives no late dispatch");
            }
        }
        groups++;
    }
    private static void resolvedInputSentinels() throws Throwable {
        String[] inputs={"drunkDelay","unsafeChunk","cruiseInput","parkingInput"};
        int[] modes={VehicleHooks.NO_CONTROL,VehicleHooks.BRAKING,VehicleHooks.FORWARD,VehicleHooks.BRAKING};
        for(int i=0;i<inputs.length;i++) {
            String original;
            try(var e=new Env(false)) {
                e.set(e.controller,"request",i==2?0:1); e.set(e.controller,inputs[i],true); e.tick(); original=sentinels(e);
            }
            try(var e=new Env()) {
                e.set(e.controller,"request",i==2?0:1); e.set(e.controller,inputs[i],true); e.tick();
                check(original.equals(sentinels(e)),"inert transformation preserves pre-resolution sentinel " + inputs[i]);
            }
            try(var e=new Env()) {
                VehicleControl control=e.adapter(Map.of("diagnostics_enabled","true"));
                e.set(e.controller,"request",i==2?0:1); e.set(e.controller,inputs[i],true); e.tick();
                near(diagnostic(control,"mode"),modes[i],"adapter receives resolved mode, not raw input: " + inputs[i]);
                if(i!=2) check(original.equals(sentinels(e)),"coast/braking safety branch remains original: " + inputs[i]);
                else {
                    check(e.nativeForce()>0,"cruise input drives model without a raw acceleration key");
                    near(e.number(e.controller,"cruiseSelections"),1,"cruise input selection occurs once");
                    near(e.number(e.controller,"forwardCalls"),0,"cruise skips only owned original propulsion");
                    check(!e.bool(e.controller,"backSignal") && !e.bool(e.controller,"brakeLights"),"cruise signals preserved");
                    near(e.staticNumber("zombie.core.physics.Bullet","calls"),1,"cruise retains one native call");
                }
            }
        }
        groups++;
    }
    private static String sentinels(Env e) throws Exception {
        StringBuilder result=new StringBuilder();
        for(String name:new String[]{"forwardCalls","reverseCalls","coastCalls","brakeCalls","startRequests","speedRequests",
                "delaySelections","chunkSelections","cruiseSelections","parkingSelections","engineForce","brakingForce","backSignal","brakeLights"})
            result.append(name).append('=').append(e.get(e.controller,name)).append(';');
        return result.append("native=").append(e.nativeForce()).append(';')
            .append(e.staticNumber("zombie.core.physics.Bullet","calls")).append(';')
            .append(e.staticNumber("zombie.core.physics.Bullet","brake")).toString();
    }
    private static void nativeObservationIsolation() throws Throwable {
        try(var e=new Env()) {
            e.set(e.controller,"request",1); e.set(e.controller,"vehicleId",47);
            e.set(e.controller,"tireFactor",-0.0f); e.set(e.controller,"steering",.375f);
            int[] observations={0}; float[] observed=new float[3];
            e.register(new VehicleHooks.Controller() {
                public int tryControl(Object c,int mode,float speed) { return VehicleHooks.VANILLA; }
                public void observeNative(Object c,float force,float brake,float steering) {
                    check(c==e.controller,"native observation controller identity");
                    observations[0]++; observed[0]=force; observed[1]=brake; observed[2]=steering;
                }
            });
            e.tick();
            near(observations[0],1,"one observer for one original native call");
            near(e.staticNumber("zombie.core.physics.Bullet","calls"),1,"observer does not add a native call");
            near(e.staticNumber("zombie.core.physics.Bullet","vehicleId"),47,"spill/reload preserves native vehicle id");
            check(Float.floatToRawIntBits(observed[0])==Float.floatToRawIntBits(e.staticNumber("zombie.core.physics.Bullet","force").floatValue())
                && Float.floatToRawIntBits(observed[1])==Float.floatToRawIntBits(e.staticNumber("zombie.core.physics.Bullet","brake").floatValue())
                && Float.floatToRawIntBits(observed[2])==Float.floatToRawIntBits(e.staticNumber("zombie.core.physics.Bullet","steer").floatValue()),
                "spill/reload changed a native argument's exact bits");
        }
        try(var e=new Env()) {
            e.set(e.controller,"request",1); e.set(e.vehicle,"offroad",true); e.set(e.controller,"tireFactor",.5f);
            e.register(new VehicleHooks.Controller() {
                public int tryControl(Object c,int mode,float speed) throws Exception {
                    e.set(c,"engineForce",100f); return VehicleHooks.APPLIED|VehicleHooks.OWN_OFFROAD;
                }
                public void observeNative(Object c,float force,float brake,float steering) { throw new AssertionError("fixture-observation-failure"); }
            });
            e.tick(); near(e.nativeForce(),50,"observer failure cannot change committed force/offroad outcome");
            near(e.number(e.controller,"forwardCalls"),0,"observer failure cannot run original propulsion again");
            near(e.staticNumber("zombie.core.physics.Bullet","calls"),1,"observer failure cannot repeat native invocation");
            check(VehicleHooks.failure(e.owner)!=null,"observation fault is visible to host");
            e.tick(); near(e.nativeForce(),11*.5*.25,"later step fails open after observation fault");
        }
        groups++;
    }
    private static Map<String,String> toggles(boolean torque,boolean reverse,boolean steering) {
        return Map.of("torque_enabled",Boolean.toString(torque),"reverse_enabled",Boolean.toString(reverse),
            "steering_enabled",Boolean.toString(steering),"diagnostics_enabled","true");
    }
    private static void independentToggleMatrix() throws Throwable {
        for(int bits=0;bits<8;bits++) for(int mode=0;mode<=3;mode++) {
            boolean torque=(bits&1)!=0,reverse=(bits&2)!=0,steering=(bits&4)!=0;
            String original; double originalAngle;
            try(var e=new Env(false)) {
                e.set(e.controller,"request",mode); e.set(e.vehicle,"offroad",true); e.set(e.controller,"tireFactor",.5f);
                e.set(e.get(e.controller,"clientControls"),"steering",1f); e.tick(); original=sentinels(e);
                originalAngle=e.staticNumber("zombie.core.physics.Bullet","steer").doubleValue();
            }
            try(var e=new Env()) {
                VehicleControl control=e.adapter(toggles(torque,reverse,steering));
                e.set(e.controller,"request",mode); e.set(e.vehicle,"offroad",true); e.set(e.controller,"tireFactor",.5f);
                e.set(e.get(e.controller,"clientControls"),"steering",1f); e.tick();
                boolean propApplied=mode==1&&torque || mode==2&&reverse;
                if(!propApplied) check(original.equals(sentinels(e)),"disabled propulsion is exact original, combination="+bits+", mode="+mode);
                else near(e.number(e.controller,mode==1?"forwardCalls":"reverseCalls"),0,"only enabled propulsion skips original");
                near(e.number(e.controller,"originalSteeringCalls"),steering?0:1,"steering independent across all toggle/mode combinations");
                if(!steering) near(e.staticNumber("zombie.core.physics.Bullet","steer"),originalAngle,"disabled steering is exact original");
                else check(Math.abs(e.staticNumber("zombie.core.physics.Bullet","steer").doubleValue())<Math.abs(originalAngle),"small immediate steering response");
                near(e.number(e.vehicle,"currentSteering"),e.staticNumber("zombie.core.physics.Bullet","steer").doubleValue(),"front wheel/native steering share final value");
                near(diagnostic(control,"mode"),mode==0?4:mode==3?3:mode,"steering phase does not overwrite propulsion mode diagnostics");
            }
        }
        groups++;
    }
    private static void steeringBehavior() throws Throwable {
        try(var e=new Env()) {
            VehicleControl control=e.adapter(toggles(false,false,true)); Object input=e.get(e.controller,"clientControls");
            e.set(input,"steering",1f); e.set(e.controller,"steeringTireFactor",.5f); e.tick();
            double first=e.staticNumber("zombie.core.physics.Bullet","steer").doubleValue();
            check(first<0 && first>-.02,"keyboard reacts immediately without snapping");
            near(first,diagnostic(control,"steering_requested")*.5,"original tire steering correction runs once");
            near(e.number(e.vehicle,"currentSteering"),first,"wheel animation consumes tire-adjusted steering");
            e.set(e.controller,"steeringTireFactor",1f);
            for(int i=0;i<45;i++) e.tick();
            near(e.staticNumber("zombie.core.physics.Bullet","steer"),-.9,"held keyboard reaches script maximum");
            e.set(input,"steering",0f); e.tick(); double release=e.staticNumber("zombie.core.physics.Bullet","steer").doubleValue();
            check(release>-.9,"released keyboard returns promptly");
            e.set(input,"steering",-1f); e.tick();
            check(e.staticNumber("zombie.core.physics.Bullet","steer").doubleValue()>release,"opposite key counters promptly");
            near(e.number(e.controller,"originalSteeringCalls"),0,"replacement never double-interpolates");
        }
        double forward=Double.NaN;
        for(int sign:new int[]{1,-1}) try(var e=new Env()) {
            e.adapter(toggles(false,false,true)); e.set(e.vehicle,"speed",80f*sign);
            e.set(e.get(e.controller,"clientControls"),"steering",1f);
            for(int i=0;i<60;i++) e.tick();
            double angle=e.staticNumber("zombie.core.physics.Bullet","steer").doubleValue();
            if(sign==1) forward=angle; else near(angle,forward,"forward/reverse steering use absolute speed");
            near(angle,-.5,"existing speed-sensitive script maximum preserved");
        }
        for(int mode=0;mode<=3;mode++) try(var e=new Env()) {
            e.adapter(toggles(false,false,true)); e.set(e.controller,"request",mode); e.set(e.vehicle,"running",false);
            e.set(e.get(e.controller,"clientControls"),"steering",1f); e.tick();
            near(e.number(e.controller,"originalSteeringCalls"),0,"steering does not depend on propulsion or engine running");
            near(e.staticNumber("zombie.core.physics.Bullet","calls"),2,"engine-off original native calls preserved");
            near(e.number(e.vehicle,"currentSteering"),e.staticNumber("zombie.core.physics.Bullet","steer").doubleValue(),"engine-off wheel/native alignment");
        }
        groups++;
    }
    private static void steeringGuardsAndResets() throws Throwable {
        try(var e=new Env()) {
            VehicleControl control=e.adapter(toggles(false,false,true)); Object input=e.get(e.controller,"clientControls");
            e.set(input,"steering",1f); e.set(e.vehicle,"joypad",0); e.tick();
            near(e.staticNumber("zombie.core.physics.Bullet","steer"),-.06,"gamepad uses original interpolation");
            check(control.diagnostics().contains("steering_reason=gamepad-original"),"gamepad decline diagnosed separately");
            e.set(e.vehicle,"joypad",-1); e.set(e.controller,"vehicleSteering",0f); e.tick();
            double first=e.staticNumber("zombie.core.physics.Bullet","steer").doubleValue();
            for(int i=0;i<20;i++) e.tick();
            e.set(e.controller,"vehicleSteering",0f); e.set(e.world,"frame",e.number(e.world,"frame").intValue()+5); e.tick();
            near(e.staticNumber("zombie.core.physics.Bullet","steer"),first,"physics gap resets held-key ramp");
            for(int i=0;i<20;i++) e.tick();
            e.set(e.controller,"vehicleSteering",0f);
            Object nextDriver=e.type("zombie.characters.IsoPlayer").getConstructor().newInstance();
            e.set(nextDriver,"vehicle",e.vehicle); e.set(e.vehicle,"driver",nextDriver); e.tick();
            near(e.staticNumber("zombie.core.physics.Bullet","steer"),first,"driver change resets held-key ramp");
            for(int i=0;i<20;i++) e.tick();
            control.reconfigure(new VehicleControl.Settings(toggles(false,false,true))); e.set(e.controller,"vehicleSteering",0f); e.tick();
            near(e.staticNumber("zombie.core.physics.Bullet","steer"),first,"configuration replacement resets held-key ramp");
            e.update(); check(control.diagnostics().contains("steering_reason=duplicate-frame"),"steering has an independent duplicate-frame guard");
            e.set(e.time,"dt",0f); e.tick(); check(control.diagnostics().contains("steering_reason=invalid-steering-input-or-dt"),"paused dt uses original steering");
            e.set(e.time,"dt",1f/60); e.set(e.controller,"vehicleSteering",0f); e.set(e.controller,"drunkDelay",true); e.set(input,"steering",1f); e.tick();
            near(e.staticNumber("zombie.core.physics.Bullet","steer"),0,"drunk input delay is not bypassed");
            near(e.number(e.controller,"delaySelections"),1,"original drunk delay runs once");
            e.set(e.controller,"drunkDelay",false); e.set(input,"steering",1f); e.context.worldValid().set(false); e.tick();
            check(control.diagnostics().contains("steering_reason=wrong-thread-or-world"),"ended world declines steering");
        }
        try(var e=new Env()) {
            VehicleControl control=e.adapter(Map.of("torque_enabled","false","reverse_enabled","false","steering_enabled","true","probe_only","true","diagnostics_enabled","true"));
            e.set(e.get(e.controller,"clientControls"),"steering",1f); e.tick();
            near(e.staticNumber("zombie.core.physics.Bullet","steer"),-.06,"steering probe is non-mutating");
            check(control.diagnostics().contains("steering_reason=probe-steering-prediction"),"steering prediction is separate from actual native data");
        }
        groups++;
    }
    private static void steeringPhaseFailure() throws Throwable {
        try(var e=new Env()) {
            e.set(e.controller,"request",1); e.set(e.get(e.controller,"clientControls"),"steering",1f);
            e.registerPhases((c,mode,speed)->{
                if(mode==VehicleHooks.STEERING) throw new IllegalStateException("steering-before-commit");
                e.set(c,"engineForce",100f); return VehicleHooks.APPLIED;
            });
            e.tick(); near(e.nativeForce(),100,"steering failure cannot undo/repeat already committed propulsion");
            near(e.number(e.controller,"forwardCalls"),0,"steering exception does not run original propulsion");
            near(e.number(e.controller,"originalSteeringCalls"),1,"steering exception falls back to exactly one original interpolation");
            near(e.staticNumber("zombie.core.physics.Bullet","calls"),1,"phase exception does not duplicate native call");
            check(VehicleHooks.failure(e.owner)!=null,"steering phase fault is visible to runtime");
        }
        groups++;
    }
    private static void cellReplacement() throws Throwable {
        try(var e=new Env()) {
            VehicleAccess access=new VehicleAccess(e.loader);
            VehicleControl control=e.adapter(Map.of("diagnostics_enabled","true")); e.set(e.controller,"request",1); e.tick();
            Object oldCell=e.get(e.world,"currentCell");
            e.set(e.world,"currentCell",oldCell.getClass().getConstructor().newInstance());
            check(!access.ready(e.context),"old context cannot activate after currentCell changes with same world singleton");
            e.tick(); near(e.nativeForce(),11,"old context becomes original after cell replacement");
            check(control.diagnostics().contains("world-or-controller-changed"),"cell replacement is diagnosed");
        }
        groups++;
    }
    private static int controlCall(VehicleControl control,Object c) { try {return control.tryControl(c,1,0);} catch(Exception ex) {throw new AssertionError(ex);} }
    private static double diagnostic(VehicleControl c,String key) {
        for(String field:c.diagnostics().split(";")) if(field.startsWith(key+"=")) return Double.parseDouble(field.substring(key.length()+1));
        throw new AssertionError("missing diagnostic "+key);
    }
    private static void check(boolean condition,String message) { if(!condition) throw new AssertionError(message); }
    private static void near(Number actual,double expected,String message) { near(actual.doubleValue(),expected,message); }
    private static void near(double actual,double expected,String message) {
        if(!Double.isFinite(actual) || Math.abs(actual-expected)>1e-4*Math.max(1,Math.abs(expected))) throw new AssertionError(message+": "+actual+" != "+expected);
    }
    private static final class Env implements AutoCloseable {
        final URLClassLoader loader; final Object vehicle,controller,world,time; final ContinuousProvider.Context context;
        final Object owner=new Object(); boolean registered;
        Env() throws Throwable { this(true); }
        Env(boolean hooked) throws Throwable {
            URL url=fixture.toUri().toURL(); byte[] source=Files.readAllBytes(fixture.resolve("zombie/core/physics/CarController.class"));
            byte[] transformed;
            try(var resolver=new URLClassLoader(new URL[]{url},getClass().getClassLoader())) { transformed=VehicleBytecode.transform(source,resolver); }
            check(ClassFile.of().verify(transformed).isEmpty(),"transformed fixture class verifies");
            try(var resolver=new URLClassLoader(new URL[]{url},getClass().getClassLoader())) {
                boolean rejected=false; try { VehicleBytecode.transform(transformed,resolver); } catch(IllegalArgumentException expected) { rejected=true; }
                check(rejected,"duplicate transformation rejected");
            }
            loader=new URLClassLoader(new URL[]{url},getClass().getClassLoader()) {
                @Override protected Class<?> findClass(String name) throws ClassNotFoundException {
                    if(hooked && name.equals("zombie.core.physics.CarController")) return defineClass(name,transformed,0,transformed.length);
                    return super.findClass(name);
                }
            };
            vehicle=type("zombie.vehicles.BaseVehicle").getConstructor().newInstance();
            Object player=type("zombie.characters.IsoPlayer").getConstructor().newInstance(); set(vehicle,"driver",player); set(player,"vehicle",vehicle);
            Object[] players=(Object[])type("zombie.characters.IsoPlayer").getField("players").get(null); players[0]=player;
            controller=type("zombie.core.physics.CarController").getConstructor(vehicle.getClass()).newInstance(vehicle);
            world=type("zombie.iso.IsoWorld").getField("instance").get(null); time=type("zombie.GameTime").getField("instance").get(null);
            Object cell=get(world,"currentCell");
            context=new ContinuousProvider.Context(RuntimeIdentity.processId(),RuntimeIdentity.worldId(cell),cell,Thread.currentThread(),loader,new AtomicBoolean(true));
        }
        Class<?> type(String name) throws ClassNotFoundException { return Class.forName(name,true,loader); }
        void register(VehicleHooks.Controller c) {
            if(c instanceof VehicleControl) registerPhases(c);
            else registerPhases(new VehicleHooks.Controller() {
                public int tryControl(Object object,int mode,float speed) throws Exception {
                    return mode==VehicleHooks.STEERING?VehicleHooks.VANILLA:c.tryControl(object,mode,speed);
                }
                public void observeNative(Object object,float force,float brake,float steer) { c.observeNative(object,force,brake,steer); }
            });
        }
        void registerPhases(VehicleHooks.Controller c) { VehicleHooks.register(owner,c); registered=true; }
        VehicleControl adapter(Map<String,String> settings) throws Exception { var result=new VehicleControl(new VehicleAccess(loader),context,new VehicleControl.Settings(settings)); register(result); return result; }
        void unregister() throws Exception { if(registered) { VehicleHooks.unregister(owner).await(1000); registered=false; } }
        void tick() throws Exception { set(world,"frame",number(world,"frame").intValue()+1); update(); }
        void update() throws Exception { invoke(controller,"update"); }
        Object invoke(Object o,String method) throws Exception { try { return o.getClass().getMethod(method).invoke(o); } catch(InvocationTargetException ex) { throw new AssertionError(ex.getCause()); } }
        Object get(Object o,String field) throws ReflectiveOperationException { return o.getClass().getField(field).get(o); }
        Number number(Object o,String field) throws ReflectiveOperationException { return (Number)get(o,field); }
        boolean bool(Object o,String field) throws ReflectiveOperationException { return (boolean)get(o,field); }
        void set(Object o,String field,Object value) throws ReflectiveOperationException { o.getClass().getField(field).set(o,value); }
        void setStatic(String type,String field,Object value) throws ReflectiveOperationException { type(type).getField(field).set(null,value); }
        Number staticNumber(String type,String field) throws ReflectiveOperationException { return (Number)type(type).getField(field).get(null); }
        double nativeForce() throws ReflectiveOperationException { return staticNumber("zombie.core.physics.Bullet","force").doubleValue(); }
        @Override public void close() throws Exception { unregister(); loader.close(); }
    }
}
