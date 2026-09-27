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
        scriptReverseLimitAndOverrides(); invalidReverseLimitIsolation(); reverseNativeEnvelope(); forwardTraitNativeLimits();
        resolvedInputSentinels(); cellReplacement(); nativeObservationIsolation();
        independentToggleMatrix(); steeringBehavior(); steeringCurrentKeyboardRelease(); steeringDuplicateFrames(); steeringDuplicateInvalidation();
        steeringGuardsAndResets(); steeringPhaseFailure();
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
    private static void scriptReverseLimitAndOverrides() throws Throwable {
        for(float raw:new float[]{15f,40f,52.5f}) for(int override:new int[]{0,20,35}) try(var e=new Env()) {
            Object script=e.get(e.vehicle,"script"); e.set(script,"maxSpeedReverse",raw);
            VehicleAccess access=new VehicleAccess(e.loader); VehicleAccess.Frame frame=new VehicleAccess.Frame();
            check(access.read(e.controller,e.context,frame)==null,"script reverse limit is readable");
            near(frame.reverseMaxSpeed,raw/1.5,"adapter converts raw script reverse limit to actual km/h exactly once");
            frame.clear(); near(frame.reverseMaxSpeed,0,"reusable frame clears prior reverse limit");
            e.adapter(Map.of("reverse_max_speed_kph",Integer.toString(override)));
            e.set(e.controller,"request",2);
            double limit=override==0?raw/1.5:override;
            e.set(e.vehicle,"speed",(float)-(limit-.02)); settle(e);
            check(e.nativeForce()<0,"default/override reverse retains propulsion just below its cutoff");
            near(e.number(e.controller,"reverseCalls"),0,"valid reverse limit owns the original callsite");
            e.set(e.vehicle,"speed",(float)-(limit+.02)); e.tick();
            near(e.nativeForce(),0,"crossing reverse cutoff cuts force immediately, without reverse-sign braking");
            near(e.number(script,"maxSpeedReverse"),raw,"adapter never rewrites the vehicle script limit");
            near(e.staticNumber("zombie.core.physics.Bullet","brake"),0,"reverse governor does not add braking");
        }
        groups++;
    }
    private static void invalidReverseLimitIsolation() throws Throwable {
        for(float invalid:new float[]{0f,-1f,Float.NaN,Float.POSITIVE_INFINITY}) try(var e=new Env()) {
            Object script=e.get(e.vehicle,"script"); e.set(script,"maxSpeedReverse",invalid);
            VehicleControl control=e.adapter(Map.of("diagnostics_enabled","true"));
            e.set(e.controller,"request",1); e.tick(); check(e.nativeForce()>0,"invalid reverse script cannot disable forward");
            near(e.number(e.controller,"forwardCalls"),0,"forward remains model-owned despite invalid reverse limit");
            e.set(e.controller,"request",2); e.tick(); near(e.nativeForce(),-13,"invalid derived reverse limit returns to original");
            near(e.number(e.controller,"reverseCalls"),1,"invalid derived limit invokes original reverse once");
            // The sentinel original body does not model transmission writes; supply the actual
            // reverse branch's resulting R state before checking recovery, not a direction change.
            e.set(e.vehicle,"transmissionNumber",e.type("zombie.vehicles.TransmissionNumber").getField("R").get(null));
            e.set(script,"maxSpeedReverse",40f); e.tick();
            check(e.nativeForce()<0 && Math.abs(e.nativeForce())<50,"repaired reverse limit restarts a bounded fresh launch");
            control.reconfigure(new VehicleControl.Settings(Map.of("reverse_max_speed_kph","20")));
            e.set(script,"maxSpeedReverse",invalid); e.set(e.vehicle,"speed",-19f); settle(e);
            check(e.nativeForce()<0,"explicit valid override takes precedence over invalid script reverse value");
            near(e.number(e.controller,"reverseCalls"),1,"explicit override does not repeatedly fall through");
            e.set(e.vehicle,"speed",-20f); e.tick(); near(e.nativeForce(),0,"explicit override retains its own exact cutoff");
        }
        groups++;
    }
    private static void reverseNativeEnvelope() throws Throwable {
        for(int traits=0;traits<4;traits++) try(var e=new Env()) {
            Object player=e.get(e.vehicle,"driver"); e.set(player,"sunday",(traits&1)!=0); e.set(player,"fast",(traits&2)!=0);
            e.set(e.vehicle,"offroad",true); e.set(e.get(e.vehicle,"script"),"efficiency",.8f);
            e.set(e.controller,"tireFactor",.5f);
            e.adapter(Map.of()); e.set(e.controller,"request",2);
            for(float speed:new float[]{0,3.32f,3.35f,5,9.99f,10,10.01f,22,26.6f,26.7f}) {
                e.set(e.vehicle,"speed",-speed); settle(e);
                double rpm=((Number)e.invoke(e.vehicle,"getEngineSpeed")).doubleValue();
                double magnitude=e.number(e.vehicle,"enginePower").doubleValue()*(.75+rpm/24000);
                if(rpm>6000) magnitude*=Math.max(0,(7000-rpm)/1000);
                if((traits&1)!=0) {
                    magnitude*=.7;
                    if(speed*1.5>5) magnitude*=Math.max(0,(15-speed*1.5)/10);
                }
                if(speed>=40.0/1.5) magnitude=0;
                // Existing tire attenuation remains downstream; the model alone owns offroad.
                magnitude*=.8f*.6*.5;
                near(e.nativeForce(),-magnitude,"final native reverse force retains baseline envelope and each penalty once");
                near(e.number(e.controller,"reverseCalls"),0,"reverse trait/governor never reruns original propulsion");
                check(e.nativeForce()<=0,"native reverse force cannot change sign above trait/script cutoff");
            }
        }
        groups++;
    }
    private static void forwardTraitNativeLimits() throws Throwable {
        // Bound the base formula and trait/speed limiters, not vanilla's separate high-RPM fade.
        for(float maximum:new float[]{40,65,120}) for(int traits=0;traits<4;traits++) try(var e=new Env()) {
            e.set(e.vehicle,"maxSpeed",maximum); Object player=e.get(e.vehicle,"driver");
            e.set(player,"sunday",(traits&1)!=0); e.set(player,"fast",(traits&2)!=0);
            e.adapter(Map.of()); e.set(e.controller,"request",1);
            for(float speed:new float[]{maximum*.6f-.02f,maximum*.6f+.02f,maximum-.02f,maximum+.02f,
                    maximum*.75f+20.02f,maximum*1.15f+20.02f}) {
                e.set(e.vehicle,"speed",speed); settle(e);
                double rpm=((Number)e.invoke(e.vehicle,"getEngineSpeed")).doubleValue();
                int gear=((Number)e.invoke(e.vehicle,"getTransmissionNumber")).intValue();
                double expected=e.number(e.vehicle,"enginePower").doubleValue()*(gear==1||speed<maximum/4.0?1.5:1)
                    *(.3+rpm/30000)*Math.max(0,1-speed/200.0);
                if((traits&1)!=0) {
                    expected*=.75;
                    if(speed>maximum*.6) expected*=Math.max(0,(maximum*.75+20-speed)/20);
                }
                double reference=maximum*((traits&2)!=0?1.15:1);
                if(speed>reference) expected*=Math.max(0,(reference+20-speed)/20);
                double tolerance=1e-4*Math.max(1,expected);
                check(e.nativeForce()>=expected-tolerance && e.nativeForce()<=expected*1.10+tolerance,
                    "native forward trait limits compose and preserve nonnegative baseline: "+maximum+"/"+traits+"/"+speed);
                near(e.number(e.controller,"forwardCalls"),0,"forward trait handling owns the original callsite once");
            }
        }
        groups++;
    }
    private static void settle(Env e) throws Exception { for(int i=0;i<180;i++) e.tick(); }
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
            e.update(); check(control.diagnostics().contains("steering_reason=duplicate-frame-applied;"),"steering has an independent duplicate-frame guard");
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
            e.update();
            near(e.staticNumber("zombie.core.physics.Bullet","steer"),-.1164,"duplicate probe still uses original interpolation");
            near(e.number(e.controller,"originalSteeringCalls"),2,"uncommitted prediction is never reused as applied steering");
            check(control.diagnostics().contains("steering_applied=false"),"duplicate probe cannot report an applied prediction");
        }
        groups++;
    }
    private static void steeringCurrentKeyboardRelease() throws Throwable {
        for(float cached:new float[]{-1f,1f}) for(float tireFactor:new float[]{1f,.5f}) for(int changed:new int[]{0,-1,2}) try(var e=new Env()) {
            VehicleControl control=e.adapter(toggles(false,false,true)); Object input=e.get(e.controller,"clientControls");
            e.set(e.controller,"steeringTireFactor",tireFactor); e.set(input,"steering",cached);
            for(int i=0;i<12;i++) e.tick();
            double held=e.staticNumber("zombie.core.physics.Bullet","steer").doubleValue();
            e.setStatic("zombie.input.GameKeyboard","steering",changed==-1?-cached:0f);
            e.setStatic("zombie.input.GameKeyboard","both",changed==2);
            e.update();
            near(e.staticNumber("zombie.core.physics.Bullet","steer"),held,"current key release cannot advance an already applied frame");
            e.tick();
            double released=e.staticNumber("zombie.core.physics.Bullet","steer").doubleValue();
            check(Math.abs(released)<Math.abs(held),"first new physics frame returns toward center despite stale held controls");
            check(released*held>=0,"opposite current key only releases stale input without synthesizing reversal");
            near(diagnostic(control,"steering_input"),0,"released, opposite, or conflicting current keys veto the stale direction");
            near(e.number(input,"steering"),cached,"release sampling leaves cached game controls untouched");
            near(e.number(e.controller,"originalSteeringCalls"),0,"stale-key release stays within the steering model");
        }
        try(var e=new Env()) {
            VehicleControl control=e.adapter(toggles(false,false,true)); Object input=e.get(e.controller,"clientControls");
            e.setStatic("zombie.input.GameKeyboard","steering",1f); e.tick();
            near(e.staticNumber("zombie.core.physics.Bullet","steer"),0,"current press cannot create input before game controls accept it");
            near(e.number(input,"steering"),0,"current press leaves neutral cached input untouched");
            near(e.staticNumber("zombie.input.GameKeyboard","reads"),0,"neutral cached input does not sample new keys");
            e.set(input,"steering",1f); e.set(e.controller,"drunkDelay",true); e.tick();
            near(e.staticNumber("zombie.core.physics.Bullet","steer"),0,"current held key cannot restore drunk-gated input");
            near(diagnostic(control,"steering_input"),0,"drunk-gated neutral remains authoritative");
            near(e.number(e.controller,"delaySelections"),1,"original drunk gate still runs once");
            near(e.staticNumber("zombie.input.GameKeyboard","reads"),0,"drunk-gated neutral cannot sample a new press");
        }
        try(var e=new Env()) {
            VehicleControl control=e.adapter(toggles(false,false,true)); e.set(e.get(e.controller,"clientControls"),"steering",1f);
            e.setStatic("zombie.input.GameKeyboard","steering",0f); e.set(e.vehicle,"joypad",0); e.tick();
            near(e.staticNumber("zombie.core.physics.Bullet","steer"),-.06,"gamepad retains original steering despite keyboard state");
            near(e.staticNumber("zombie.input.GameKeyboard","reads"),0,"gamepad never reads keyboard steering keys");
            e.set(e.vehicle,"joypad",-1); e.set(e.vehicle,"keyboardControlled",false); e.set(e.controller,"vehicleSteering",0f); e.tick();
            near(diagnostic(control,"steering_input"),1,"non-keyboard controls cannot be vetoed by released keyboard keys");
            near(e.staticNumber("zombie.input.GameKeyboard","reads"),0,"non-keyboard controls never sample keyboard steering keys");
        }
        groups++;
    }
    private static void steeringDuplicateFrames() throws Throwable {
        for(float tireFactor:new float[]{1f,.5f}) {
            double[] singlePass=new double[30];
            for(int duplicates:new int[]{0,3}) try(var e=new Env()) {
                VehicleControl control=e.adapter(toggles(false,false,true)); Object input=e.get(e.controller,"clientControls");
                e.set(e.controller,"steeringTireFactor",tireFactor);
                for(int i=0;i<singlePass.length;i++) {
                    e.set(input,"steering",i<12?1f:i<20?0f:-1f); e.tick();
                    double angle=e.staticNumber("zombie.core.physics.Bullet","steer").doubleValue();
                    if(duplicates==0) singlePass[i]=angle;
                    else near(angle,singlePass[i],"extra callbacks cannot change subsequent physics frames");
                    for(int repeat=0;repeat<duplicates;repeat++) {
                        e.update();
                        check(e.staticNumber("zombie.core.physics.Bullet","steer").doubleValue()==angle,
                            "duplicate frame preserves exact steering with tire factor "+tireFactor);
                        near(e.number(e.vehicle,"currentSteering"),angle,"duplicate wheel and native steering stay aligned");
                        near(diagnostic(control,"steering_requested")*tireFactor,angle,"duplicate restores the pre-tire angle");
                        check(control.diagnostics().contains("steering_reason=duplicate-frame-applied"),"applied duplicate is diagnosed");
                    }
                }
                near(e.number(e.controller,"originalSteeringCalls"),0,"duplicate callbacks never add original interpolation");
            }
        }
        for(float changedInput:new float[]{0f,-1f}) try(var e=new Env()) {
            e.adapter(toggles(false,false,true)); Object input=e.get(e.controller,"clientControls");
            e.set(e.controller,"steeringTireFactor",.5f); e.set(input,"steering",1f);
            for(int i=0;i<12;i++) e.tick();
            double held=e.staticNumber("zombie.core.physics.Bullet","steer").doubleValue();
            e.set(input,"steering",changedInput);
            for(int repeat=0;repeat<3;repeat++) {
                e.update();
                near(e.staticNumber("zombie.core.physics.Bullet","steer"),held,"same-frame release or reversal adds no outward travel");
            }
            e.tick();
            check(e.staticNumber("zombie.core.physics.Bullet","steer").doubleValue()>held,
                "next physics frame consumes the latest release or reversal");
            near(e.number(e.controller,"originalSteeringCalls"),0,"same-frame input change cannot insert original interpolation");
        }
        groups++;
    }
    private static void steeringDuplicateInvalidation() throws Throwable {
        for(float invalidDt:new float[]{0f,-1f,Float.NaN,Float.POSITIVE_INFINITY,1f}) try(var e=new Env()) {
            VehicleControl control=e.adapter(toggles(false,false,true)); e.set(e.get(e.controller,"clientControls"),"steering",1f); e.tick();
            e.set(e.time,"dt",invalidDt); e.update();
            near(e.number(e.controller,"originalSteeringCalls"),1,"invalid duplicate dt falls back to original steering");
            check(control.diagnostics().contains("steering_reason=invalid-steering-input-or-dt"),"duplicate validates dt before replay");
            e.set(e.time,"dt",1f/60); e.update();
            near(e.number(e.controller,"originalSteeringCalls"),2,"original interval invalidates the previously applied cache");
            check(control.diagnostics().contains("steering_applied=false"),"invalidated duplicate cannot report applied steering");
            e.tick(); near(e.number(e.controller,"originalSteeringCalls"),2,"valid next frame resumes the model");
        }
        for(boolean gamepad:new boolean[]{false,true}) try(var e=new Env()) {
            e.adapter(toggles(false,false,true)); e.set(e.get(e.controller,"clientControls"),"steering",1f); e.tick();
            if(gamepad) e.set(e.vehicle,"joypad",0); else e.context.worldValid().set(false);
            e.update(); near(e.number(e.controller,"originalSteeringCalls"),1,"duplicate still validates steering context");
            if(gamepad) e.set(e.vehicle,"joypad",-1); else e.context.worldValid().set(true);
            e.update(); near(e.number(e.controller,"originalSteeringCalls"),2,"context fallback prevents cached reapplication");
        }
        for(float invalidInput:new float[]{Float.NaN,Float.POSITIVE_INFINITY,2f}) try(var e=new Env()) {
            VehicleControl control=e.adapter(toggles(false,false,true)); Object input=e.get(e.controller,"clientControls");
            e.set(input,"steering",1f); e.tick(); e.set(input,"steering",invalidInput); e.update();
            near(e.number(e.controller,"originalSteeringCalls"),1,"invalid duplicate input cannot reuse applied steering");
            check(control.diagnostics().contains("steering_reason=invalid-steering-input-or-dt"),"duplicate validates input before replay");
        }
        try(var e=new Env()) {
            VehicleControl control=e.adapter(toggles(false,false,true)); e.set(e.get(e.controller,"clientControls"),"steering",1f); e.tick();
            double first=e.staticNumber("zombie.core.physics.Bullet","steer").doubleValue();
            for(int i=0;i<20;i++) e.tick();
            Object nextDriver=e.type("zombie.characters.IsoPlayer").getConstructor().newInstance();
            e.set(nextDriver,"vehicle",e.vehicle); e.set(e.vehicle,"driver",nextDriver); e.set(e.controller,"vehicleSteering",0f);
            e.update(); near(e.staticNumber("zombie.core.physics.Bullet","steer"),first,"same-frame new driver cannot reuse old driver's angle");
            for(int i=0;i<20;i++) e.tick();
            control.reconfigure(new VehicleControl.Settings(toggles(false,false,true))); e.set(e.controller,"vehicleSteering",0f);
            e.update(); near(e.staticNumber("zombie.core.physics.Bullet","steer"),first,"same-frame reconfiguration discards applied cache");
            control.reconfigure(new VehicleControl.Settings(toggles(false,false,false))); e.update();
            near(e.number(e.controller,"originalSteeringCalls"),1,"same-frame disabling restores original steering");
            control.reconfigure(new VehicleControl.Settings(Map.of("torque_enabled","false","reverse_enabled","false",
                "steering_enabled","true","probe_only","true","diagnostics_enabled","true"))); e.update(); e.update();
            near(e.number(e.controller,"originalSteeringCalls"),3,"same-frame switch to probe cannot reuse a committed angle");
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
